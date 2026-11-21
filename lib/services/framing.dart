import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'crypto.dart';

/// Reads exact byte counts from a socket stream.
class ByteReader {
  final List<Uint8List> _chunks = [];
  int _avail = 0;
  Completer<void>? _wait;
  bool _done = false;

  ByteReader(Socket socket) {
    socket.listen(
      (d) {
        _chunks.add(d);
        _avail += d.length;
        _wake();
      },
      onDone: () {
        _done = true;
        _wake();
      },
      onError: (_) {
        _done = true;
        _wake();
      },
      cancelOnError: true,
    );
  }

  void _wake() {
    final w = _wait;
    _wait = null;
    w?.complete();
  }

  Future<Uint8List> read(int n) async {
    while (_avail < n) {
      if (_done) throw const SocketException('Connection closed');
      _wait = Completer<void>();
      await _wait!.future;
    }
    final out = Uint8List(n);
    var off = 0;
    while (off < n) {
      final c = _chunks.first;
      final take = min(c.length, n - off);
      out.setRange(off, off + take, c);
      if (take == c.length) {
        _chunks.removeAt(0);
      } else {
        _chunks[0] = Uint8List.sublistView(c, take);
      }
      off += take;
    }
    _avail -= n;
    return out;
  }
}

/// Length-prefixed, encrypted frames over a TCP socket.
class SecureChannel {
  static const int maxFrame = 1024 * 1024;
  static const int _clientToServer = 1;
  static const int _serverToClient = 2;

  final Socket socket;
  final ByteReader _reader;
  final SessionCrypto _crypto;
  final int _sendDir;
  final int _recvDir;
  int _sendSeq = 0;
  int _recvSeq = 0;

  SecureChannel(this.socket, this._reader, this._crypto,
      {required bool isClient})
      : _sendDir = isClient ? _clientToServer : _serverToClient,
        _recvDir = isClient ? _serverToClient : _clientToServer;

  Future<void> send(List<int> plain) async {
    final sealed = await _crypto.seal(plain, SessionCrypto.aad(_sendDir, _sendSeq++));
    final header = ByteData(4)..setUint32(0, sealed.length);
    socket.add(header.buffer.asUint8List());
    socket.add(sealed);
    await socket.flush(); // gives us back-pressure for large files
  }

  Future<void> sendJson(Map<String, dynamic> m) => send(utf8.encode(jsonEncode(m)));

  /// Returns null when the frame fails authentication.
  Future<Uint8List?> receive() async {
    final header = await _reader.read(4);
    final len = ByteData.sublistView(header).getUint32(0);
    if (len < 28 || len > maxFrame) {
      throw const FormatException('Bad frame length');
    }
    final body = await _reader.read(len);
    return _crypto.open(body, SessionCrypto.aad(_recvDir, _recvSeq++));
  }

  Future<Map<String, dynamic>?> receiveJson() async {
    final raw = await receive();
    if (raw == null) return null;
    return jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
  }
}

Uint8List randomBytes(int n) {
  final r = Random.secure();
  return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
}
