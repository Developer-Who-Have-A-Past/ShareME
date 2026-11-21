import 'dart:async';
import 'dart:convert';
import 'dart:io';

class Peer {
  final String id;
  String name;
  String ip;
  int port;
  String os;
  DateTime lastSeen;
  final bool manual;

  Peer({
    required this.id,
    required this.name,
    required this.ip,
    required this.port,
    required this.os,
    this.manual = false,
  }) : lastSeen = DateTime.now();
}

/// Finds other ShareLAN devices on the same WiFi by UDP broadcast beacons.
class Discovery {
  static const int udpPort = 45454;
  static const String appTag = 'sharelan1';

  final String id;
  final String name;
  final int tcpPort;
  final void Function(Peer) onPeer;

  RawDatagramSocket? _sock;
  Timer? _timer;

  Discovery({
    required this.id,
    required this.name,
    required this.tcpPort,
    required this.onPeer,
  });

  Future<void> start() async {
    final sock = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      udpPort,
      reuseAddress: true,
    );
    sock.broadcastEnabled = true;
    sock.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? d;
      while ((d = sock.receive()) != null) {
        _onDatagram(d!);
      }
    });
    _sock = sock;
    _beacon();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _beacon());
  }

  void _onDatagram(Datagram d) {
    try {
      final m = jsonDecode(utf8.decode(d.data)) as Map<String, dynamic>;
      if (m['app'] != appTag || m['id'] == id) return;
      onPeer(Peer(
        id: m['id'] as String,
        name: m['name'] as String,
        ip: d.address.address,
        port: m['port'] as int,
        os: (m['os'] as String?) ?? '',
      ));
    } catch (_) {
      // not ours / malformed – ignore
    }
  }

  Future<void> _beacon() async {
    final sock = _sock;
    if (sock == null) return;
    final payload = utf8.encode(jsonEncode({
      'app': appTag,
      'id': id,
      'name': name,
      'port': tcpPort,
      'os': Platform.operatingSystem,
    }));
    final targets = <String>{'255.255.255.255'};
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final i in ifaces) {
        for (final a in i.addresses) {
          final p = a.address.split('.');
          if (p.length == 4) targets.add('${p[0]}.${p[1]}.${p[2]}.255');
        }
      }
    } catch (_) {}
    for (final t in targets) {
      try {
        sock.send(payload, InternetAddress(t), udpPort);
      } catch (_) {}
    }
  }

  void stop() {
    _timer?.cancel();
    _sock?.close();
  }
}
