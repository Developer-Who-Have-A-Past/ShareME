import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'services/discovery.dart';
import 'services/transfer.dart';

String fmtBytes(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  if (b < 1024 * 1024 * 1024) {
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String fmtDuration(int s) {
  if (s < 60) return '${s}s';
  if (s < 3600) return '${s ~/ 60}m ${s % 60}s';
  return '${s ~/ 3600}h ${(s % 3600) ~/ 60}m';
}

class TransferItem {
  final String label;
  final bool incoming;
  double progress = 0;
  String status = 'Starting…';
  bool done = false;
  bool failed = false;
  bool cancelRequested = false;
  Future<void> Function()? retry;
  final Stopwatch _sw = Stopwatch()..start();

  TransferItem(this.label, {required this.incoming});

  bool get active => !done && !failed;

  /// Updates progress plus speed and time-remaining text.
  void update(int sent, int total) {
    progress = total == 0 ? 1 : sent / total;
    final secs = _sw.elapsedMilliseconds / 1000;
    final speed = secs > 0 ? sent / secs : 0.0;
    final left = speed > 0 ? ((total - sent) / speed).round() : 0;
    status = '${fmtBytes(sent)} / ${fmtBytes(total)}'
        ' · ${fmtBytes(speed.round())}/s · ${fmtDuration(left)} left';
  }
}

class IncomingDecision {
  final bool accept;
  final bool trust;
  const IncomingDecision({required this.accept, this.trust = false});
}

class InboxItem {
  final String from;
  final String? text;
  final String? path;
  final DateTime at;

  InboxItem({required this.from, this.text, this.path, DateTime? at})
      : at = at ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'from': from,
        'text': text,
        'path': path,
        'at': at.toIso8601String(),
      };

  static InboxItem fromJson(Map<String, dynamic> m) => InboxItem(
        from: m['from'] as String? ?? '?',
        text: m['text'] as String?,
        path: m['path'] as String?,
        at: DateTime.tryParse(m['at'] as String? ?? ''),
      );
}

class AppState extends ChangeNotifier {
  late String id;
  late String name;
  late String pin;

  final Map<String, Peer> peers = {};
  Map<String, String> pins = {}; // peer id -> PIN (remembered devices)
  Set<String> trusted = {}; // sender ids that are auto-accepted
  bool autoCopyText = false;
  ThemeMode themeMode = ThemeMode.system;
  List<String> localIps = [];

  final List<TransferItem> transfers = [];
  final List<InboxItem> inbox = [];

  late Directory saveDir;
  late Directory defaultSaveDir;
  late TransferService transfer;
  late Discovery discovery;

  /// Set by the UI: asks the user whether to accept an incoming transfer.
  Future<IncomingDecision> Function(
          String from, List<String> names, int totalBytes)?
      confirmIncoming;

  Timer? _prune;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> init() async {
    defaultSaveDir = await _resolveSaveDir();
    saveDir = defaultSaveDir;

    final m = await _readSettings();
    id = (m['id'] as String?) ?? _randomHex(8);
    pin = (m['pin'] as String?) ?? _newPin();
    pins = Map<String, String>.from((m['pins'] as Map?) ?? {});
    trusted = Set<String>.from((m['trusted'] as List?) ?? []);
    autoCopyText = m['autoCopy'] == true;
    final t = m['theme'] as String?;
    themeMode = ThemeMode.values
        .firstWhere((e) => e.name == t, orElse: () => ThemeMode.system);
    final sd = m['saveDir'] as String?;
    if (sd != null && await _canWrite(Directory(sd))) saveDir = Directory(sd);

    name = Platform.isAndroid
        ? 'Android-${id.substring(0, 4)}'
        : Platform.isIOS
            ? 'iPhone-${id.substring(0, 4)}'
            : Platform.localHostname;
    await _save();
    await _loadHistory();

    await refreshIps();
    transfer = TransferService(this);
    final port = await transfer.start();
    discovery = Discovery(id: id, name: name, tcpPort: port, onPeer: _onPeer);
    await discovery.start();
    _prune = Timer.periodic(const Duration(seconds: 3), (_) {
      final now = DateTime.now();
      final before = peers.length;
      peers.removeWhere((_, peer) =>
          !peer.manual && now.difference(peer.lastSeen).inSeconds > 10);
      if (peers.length != before) notifyListeners();
      refreshIps();
    });
  }

  /// This device's WiFi/LAN addresses, shown so they can be typed on the
  /// other device ("Add device by IP") if auto-discovery is blocked.
  Future<void> refreshIps() async {
    try {
      final ifs = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final ips = <String>[
        for (final i in ifs)
          for (final a in i.addresses) a.address,
      ]..sort();
      if (ips.join(',') != localIps.join(',')) {
        localIps = ips;
        notifyListeners();
      }
    } catch (_) {}
  }

  // ── Persistence ──

  Future<File> _file(String fileName) async {
    final d = await getApplicationSupportDirectory();
    await d.create(recursive: true);
    return File(p.join(d.path, fileName));
  }

  Future<Map<String, dynamic>> _readSettings() async {
    try {
      final f = await _file('settings.json');
      if (!f.existsSync()) return {};
      return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  Future<void> _save() async {
    try {
      final f = await _file('settings.json');
      await f.writeAsString(jsonEncode({
        'id': id,
        'pin': pin,
        'pins': pins,
        'trusted': trusted.toList(),
        'autoCopy': autoCopyText,
        'theme': themeMode.name,
        'saveDir': saveDir.path == defaultSaveDir.path ? null : saveDir.path,
      }));
    } catch (_) {}
  }

  Future<void> _loadHistory() async {
    try {
      final f = await _file('history.json');
      if (!f.existsSync()) return;
      final list = jsonDecode(await f.readAsString()) as List;
      inbox.addAll(
          list.map((e) => InboxItem.fromJson(e as Map<String, dynamic>)));
    } catch (_) {}
  }

  Future<void> _saveHistory() async {
    try {
      final f = await _file('history.json');
      await f.writeAsString(jsonEncode(inbox.map((e) => e.toJson()).toList()));
    } catch (_) {}
  }

  Future<Directory> _resolveSaveDir() async {
    Directory? base;
    if (Platform.isAndroid) {
      base = await getExternalStorageDirectory();
    } else if (Platform.isIOS) {
      base = await getApplicationDocumentsDirectory(); // shown in Files app
    } else {
      base = await getDownloadsDirectory();
    }
    base ??= await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'ShareLAN'));
    await dir.create(recursive: true);
    return dir;
  }

  Future<bool> _canWrite(Directory d) async {
    try {
      await d.create(recursive: true);
      final t = File(p.join(d.path, '.sharelan_write_test'));
      await t.writeAsString('x');
      await t.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  // ── Save folder ──

  /// Returns null on success, or an error message.
  Future<String?> setSaveDir(String path) async {
    final d = Directory(path);
    if (!await _canWrite(d)) {
      return "Can't write to that folder. Pick another one"
          '${Platform.isAndroid ? ' or use "Save received files to Downloads" in Settings' : ''}.';
    }
    saveDir = d;
    await _save();
    notifyListeners();
    return null;
  }

  Future<void> resetSaveDir() async {
    saveDir = defaultSaveDir;
    await _save();
    notifyListeners();
  }

  /// Android only: asks for "all files access", then saves to Downloads.
  Future<String?> useAndroidDownloads() async {
    if (!Platform.isAndroid) return null;
    final st = await Permission.manageExternalStorage.request();
    if (!st.isGranted) {
      return 'Permission not granted. Turn on "Allow access to manage all '
          'files" for ShareLAN in Android settings, then try again.';
    }
    return setSaveDir('/storage/emulated/0/Download/ShareLAN');
  }

  // ── Settings ──

  void setTheme(ThemeMode m) {
    themeMode = m;
    _save();
    notifyListeners();
  }

  void setAutoCopy(bool v) {
    autoCopyText = v;
    _save();
    notifyListeners();
  }

  void regeneratePin() {
    pin = _newPin();
    _save();
    notifyListeners();
  }

  void setPin(String peerId, String value) {
    pins[peerId] = value;
    _save();
  }

  void forgetPin(String peerId) {
    pins.remove(peerId);
    _save();
  }

  void clearPins() {
    pins.clear();
    _save();
    notifyListeners();
  }

  void trust(String senderId) {
    trusted.add(senderId);
    _save();
    notifyListeners();
  }

  void clearTrusted() {
    trusted.clear();
    _save();
    notifyListeners();
  }

  void clearHistory() {
    inbox.clear();
    _saveHistory();
    notifyListeners();
  }

  // ── Peers / transfers ──

  void _onPeer(Peer peer) {
    final existing = peers[peer.id];
    if (existing == null) {
      peers[peer.id] = peer;
      notifyListeners();
    } else {
      existing
        ..name = peer.name
        ..ip = peer.ip
        ..port = peer.port
        ..lastSeen = DateTime.now();
    }
  }

  void addManualPeer(String ip) {
    final peer = Peer(
      id: 'manual-$ip',
      name: ip,
      ip: ip,
      port: TransferService.preferredPort,
      os: '',
      manual: true,
    );
    peers[peer.id] = peer;
    notifyListeners();
  }

  TransferItem addTransfer(String label, {required bool incoming}) {
    final t = TransferItem(label, incoming: incoming);
    transfers.insert(0, t);
    notifyListeners();
    return t;
  }

  void addInbox(InboxItem i) {
    inbox.insert(0, i);
    if (inbox.length > 100) inbox.removeRange(100, inbox.length);
    _saveHistory();
    notifyListeners();
  }

  /// Throttled notify for progress updates.
  void touch({bool force = false}) {
    final now = DateTime.now();
    if (force || now.difference(_lastNotify).inMilliseconds > 100) {
      _lastNotify = now;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _prune?.cancel();
    discovery.stop();
    transfer.stop();
    super.dispose();
  }

  static String _newPin() {
    final r = Random.secure();
    return List.generate(6, (_) => r.nextInt(10)).join();
  }

  static String _randomHex(int n) {
    final r = Random.secure();
    return List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
  }
}
