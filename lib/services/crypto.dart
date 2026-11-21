import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// AES-256-GCM session crypto. The key is derived from the 6-digit PIN shown
/// on the receiving device plus a random per-connection salt.
///
/// Every frame is authenticated with AAD = direction byte + sequence number,
/// so frames cannot be replayed, reordered, or reflected back.
class SessionCrypto {
  final SecretKey _key;
  final AesGcm _aes = AesGcm.with256bits();

  SessionCrypto._(this._key);

  static Future<SessionCrypto> fromPin(String pin, List<int> salt) async {
    final kdf = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 30000,
      bits: 256,
    );
    final key = await kdf.deriveKeyFromPassword(password: pin, nonce: salt);
    return SessionCrypto._(key);
  }

  static Uint8List aad(int direction, int seq) {
    final b = ByteData(9);
    b.setUint8(0, direction);
    b.setUint64(1, seq);
    return b.buffer.asUint8List();
  }

  /// Returns nonce(12) + ciphertext + mac(16).
  Future<Uint8List> seal(List<int> plain, Uint8List aad) async {
    final box = await _aes.encrypt(plain, secretKey: _key, aad: aad);
    return Uint8List.fromList(box.concatenation());
  }

  /// Returns null if authentication fails (wrong PIN or tampering).
  Future<Uint8List?> open(List<int> data, Uint8List aad) async {
    try {
      final box = SecretBox.fromConcatenation(
        data,
        nonceLength: 12,
        macLength: 16,
      );
      final clear = await _aes.decrypt(box, secretKey: _key, aad: aad);
      return Uint8List.fromList(clear);
    } catch (_) {
      return null;
    }
  }
}
