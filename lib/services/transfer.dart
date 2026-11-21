import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app_state.dart';
import 'crypto.dart';
import 'discovery.dart';
import 'framing.dart';

class PinRejected implements Exception {
  @override
  String toString() => 'Wrong PIN or connection refused';
}

class _Declined implements Exception {
  const _Declined();
  @override
  String toString() => 'Declined by receiver';
}

class _Out {
  final String origPath;
  final String name;
  String path;
  int size = 0;
  final bool temp;
  final TransferItem item;
  _Out(this.origPath, this.name, this.path, this.item, {required this.temp});
}

/// TCP server (receiving) and client (sending) with PIN-derived AES-GCM.
///
/// Wire protocol:
///   client -> server : 16 random salt bytes (plain)
///   then encrypted frames:
///     {"t":"hello","name":...,"id":...}              -> {"ok":true}
///     {"t":"text","text":...}                        -> {"ok":true}
///     {"t":"offer","names":[...],"size":N}           -> {"ok":true|false}
///     {"t":"file","name":...,"size":N} + data frames -> {"ok":true}
///     {"t":"bye"}
class TransferService {
  static const int preferredPort = 45455;
  static const int _chunk = 64 * 1024;

  final AppState app;
  ServerSocket? _server;
  final Map<String, List<DateTime>> _fails = {};

  TransferService(this.app);

  Future<int> start() async {
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, preferredPort);
    } catch (_) {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    }
    _server!.listen(_handle);
    return _server!.port;
  }

  void stop() => _server?.close();

  // ───────────────────────── receiving ─────────────────────────

  bool _blocked(String ip) {
    final list = _fails[ip];
    if (list == null) return false;
    final cutoff = DateTime.now().subtract(const Duration(minutes: 1));
    list.removeWhere((t) => t.isBefore(cutoff));
    return list.length >= 5;
  }

  void _recordFail(String ip) => (_fails[ip] ??= []).add(DateTime.now());

  Future<void> _handle(Socket s) async {
    final ip = s.remoteAddress.address;
    if (_blocked(ip)) {
      s.destroy();
      return;
    }
    s.setOption(SocketOption.tcpNoDelay, true);
    final reader = ByteReader(s);
    try {
      final salt = await reader.read(16).timeout(const Duration(seconds: 10));
      final crypto = await SessionCrypto.fromPin(app.pin, salt);
      final ch = SecureChannel(s, reader, crypto, isClient: false);
      final hello = await ch.receiveJson().timeout(const Duration(seconds: 10));
      if (hello == null || hello['t'] != 'hello') {
        _recordFail(ip);
        return;
      }
      final from = (hello['name'] as String?) ?? ip;
      final fromId = hello['id'] as String?;
      await ch.sendJson({'ok': true});

      var accepted = fromId != null && app.trusted.contains(fromId);

      while (true) {
        final m = await ch.receiveJson();
        if (m == null) return;
        switch (m['t']) {
          case 'text':
            final text = m['text'] as String;
            app.addInbox(InboxItem(from: from, text: text));
            if (app.autoCopyText) {
              await Clipboard.setData(ClipboardData(text: text));
            }
            await ch.sendJson({'ok': true});
          case 'offer':
            if (!accepted) {
              final names = (m['names'] as List).cast<String>();
              final total = m['size'] as int;
              var d = const IncomingDecision(accept: false);
              final cb = app.confirmIncoming;
              if (cb != null) {
                try {
                  d = await cb(from, names, total)
                      .timeout(const Duration(seconds: 60));
                } catch (_) {}
              }
              if (d.accept && d.trust && fromId != null) app.trust(fromId);
              accepted = d.accept;
            }
            await ch.sendJson({'ok': accepted});
          case 'file':
            if (!accepted) return; // must be offered and accepted first
            await _receiveFile(ch, m, from);
            await ch.sendJson({'ok': true});
          default:
            return; // "bye" or unknown
        }
      }
    } catch (_) {
      // connection dropped or timed out
    } finally {
      s.destroy();
    }
  }

  File _uniqueFile(String rawName) {
    var base = p.basename(rawName.replaceAll('\\', '/'));
    if (base.isEmpty || base == '.' || base == '..') base = 'file';
    var f = File(p.join(app.saveDir.path, base));
    var n = 1;
    final stem = p.basenameWithoutExtension(base);
    final ext = p.extension(base);
    while (f.existsSync()) {
      f = File(p.join(app.saveDir.path, '$stem ($n)$ext'));
      n++;
    }
    return f;
  }

  Future<void> _receiveFile(
      SecureChannel ch, Map<String, dynamic> m, String from) async {
    final size = m['size'] as int;
    final file = _uniqueFile(m['name'] as String);
    final item =
        app.addTransfer('${p.basename(file.path)}  ←  $from', incoming: true);
    final sink = file.openWrite();
    var got = 0;
    try {
      while (got < size) {
        if (item.cancelRequested) throw 'Cancelled';
        final chunk = await ch.receive();
        if (chunk == null) throw const FormatException('Corrupt data');
        got += chunk.length;
        if (got > size) throw const FormatException('Too much data');
        sink.add(chunk);
        item.update(got, size);
        app.touch();
      }
      await sink.flush();
      await sink.close();
      item
        ..progress = 1
        ..done = true
        ..status = 'Saved (${fmtBytes(size)}) to ${app.saveDir.path}';
      app.addInbox(InboxItem(from: from, path: file.path));
      app.touch(force: true);
    } catch (e) {
      await sink.close();
      if (file.existsSync()) file.deleteSync();
      item
        ..failed = true
        ..status = item.cancelRequested ? 'Cancelled' : 'Failed: $e';
      app.touch(force: true);
      rethrow;
    }
  }

  // ───────────────────────── sending ─────────────────────────

  Future<SecureChannel> _open(Peer peer, String pin) async {
    final s = await Socket.connect(peer.ip, peer.port,
        timeout: const Duration(seconds: 6));
    s.setOption(SocketOption.tcpNoDelay, true);
    final reader = ByteReader(s);
    final salt = randomBytes(16);
    s.add(salt);
    final crypto = await SessionCrypto.fromPin(pin, salt);
    final ch = SecureChannel(s, reader, crypto, isClient: true);
    await ch.sendJson({'t': 'hello', 'name': app.name, 'id': app.id});
    Map<String, dynamic>? reply;
    try {
      reply = await ch.receiveJson().timeout(const Duration(seconds: 15));
    } catch (_) {}
    if (reply == null || reply['ok'] != true) {
      s.destroy();
      throw PinRejected();
    }
    return ch;
  }

  void _fail(TransferItem item, Peer peer, Object e,
      {Future<void> Function()? retry}) {
    item.failed = true;
    if (item.cancelRequested) {
      item.status = 'Cancelled';
    } else if (e is PinRejected) {
      item.status = 'Wrong PIN. Send again and enter the new PIN.';
      app.forgetPin(peer.id);
    } else if (e is _Declined) {
      item.status = 'Declined by receiver';
    } else {
      item.status = 'Failed: $e';
      item.retry = retry;
    }
    app.touch(force: true);
  }

  Future<void> sendText(Peer peer, String pin, String text) async {
    final item = app.addTransfer('Text  →  ${peer.name}', incoming: false);
    SecureChannel? ch;
    try {
      ch = await _open(peer, pin);
      await ch.sendJson({'t': 'text', 'text': text});
      final r = await ch.receiveJson();
      await ch.sendJson({'t': 'bye'});
      if (r?['ok'] != true) throw 'Receiver did not confirm';
      item
        ..progress = 1
        ..done = true
        ..status = 'Sent';
      app.touch(force: true);
    } catch (e) {
      _fail(item, peer, e,
          retry: () => sendText(peer, app.pins[peer.id] ?? pin, text));
    } finally {
      ch?.socket.destroy();
    }
  }

  /// Sends files and/or folders (folders are zipped first).
  Future<void> sendPaths(Peer peer, String pin, List<String> paths) async {
    final outs = <_Out>[];
    for (final path in paths) {
      final isDir = FileSystemEntity.isDirectorySync(path);
      final base = p.basename(path);
      final name = isDir ? '$base.zip' : base;
      final item = app.addTransfer('$name  →  ${peer.name}', incoming: false)
        ..status = 'Preparing…';
      outs.add(_Out(path, name, path, item, temp: isDir));
    }

    SecureChannel? ch;
    try {
      // 1. zip folders, measure sizes
      for (final o in outs) {
        if (o.temp) {
          o.item.status = 'Zipping folder…';
          app.touch(force: true);
          final tmp = await getTemporaryDirectory();
          final zipPath = p.join(tmp.path, o.name);
          final src = o.origPath;
          await Isolate.run(() {
            ZipFileEncoder().zipDirectory(Directory(src), filename: zipPath);
          });
          o.path = zipPath;
        }
        o.size = await File(o.path).length();
        o.item.status = 'Waiting for receiver…';
      }
      app.touch(force: true);

      // 2. connect and ask the receiver to accept
      ch = await _open(peer, pin);
      await ch.sendJson({
        't': 'offer',
        'names': outs.map((o) => o.name).toList(),
        'size': outs.fold<int>(0, (a, o) => a + o.size),
      });
      final r = await ch.receiveJson().timeout(const Duration(seconds: 75));
      if (r?['ok'] != true) throw const _Declined();

      // 3. send each file
      for (final o in outs) {
        await _sendOne(ch, o);
      }
      await ch.sendJson({'t': 'bye'});
    } catch (e) {
      for (final o in outs) {
        if (!o.item.done) {
          _fail(o.item, peer, e,
              retry: () =>
                  sendPaths(peer, app.pins[peer.id] ?? pin, [o.origPath]));
        }
      }
    } finally {
      ch?.socket.destroy();
      for (final o in outs) {
        if (o.temp) {
          try {
            File(o.path).deleteSync();
          } catch (_) {}
        }
      }
    }
  }

  Future<void> _sendOne(SecureChannel ch, _Out o) async {
    final item = o.item;
    await ch.sendJson({'t': 'file', 'name': o.name, 'size': o.size});
    var sent = 0;
    await for (final data in File(o.path).openRead()) {
      for (var i = 0; i < data.length; i += _chunk) {
        if (item.cancelRequested) throw 'Cancelled';
        final end = (i + _chunk < data.length) ? i + _chunk : data.length;
        await ch.send(data.sublist(i, end));
      }
      sent += data.length;
      item.update(sent, o.size);
      app.touch();
    }
    final r = await ch.receiveJson();
    if (r?['ok'] != true) throw 'Receiver did not confirm';
    item
      ..progress = 1
      ..done = true
      ..status = 'Sent (${fmtBytes(o.size)})';
    app.touch(force: true);
  }
}
