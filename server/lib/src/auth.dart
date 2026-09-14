import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Primitive di autenticazione del control plane.
///
/// // PERCHÉ (sicurezza): il CP conserva SOLO hash sha256 di token e
/// node_secret; il valore in chiaro esiste una sola volta (risposta HTTP)
/// e poi solo sul server dell'utente (~/.tlw-node/node.json, permessi 600).
class AuthService {
  AuthService._();

  static final Random _random = Random.secure();

  /// 32 byte casuali in hex (64 char) — token di registrazione e node_secret.
  static String randomHex32() => _bytesToHex(_randomBytes(32));

  /// 16 byte casuali in hex (32 char) — identificatori pubblici (tokenId, nodeId).
  static String randomHex16() => _bytesToHex(_randomBytes(16));

  static Uint8List _randomBytes(int length) {
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return bytes;
  }

  static String _bytesToHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// sha256 in hex lowercase.
  static String sha256Hex(String input) =>
      sha256.convert(utf8.encode(input)).toString();

  /// Confronto a tempo costante su stringhe esadecimali.
  ///
  /// // PERCHÉ: un confronto con early-exit leakerebbe, via timing,
  /// quanti caratteri dell'hash del secret sono corretti.
  static bool constantTimeEquals(String a, String b) {
    final aa = a.toLowerCase();
    final bb = b.toLowerCase();
    if (aa.length != bb.length) return false;
    var diff = 0;
    for (var i = 0; i < aa.length; i++) {
      diff |= aa.codeUnitAt(i) ^ bb.codeUnitAt(i);
    }
    return diff == 0;
  }

  static final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$');
  static final RegExp _hex32 = RegExp(r'^[0-9a-f]{32}$');

  /// True se [value] è esattamente 64 char esadecimali lowercase.
  static bool isHex64(String value) => _hex64.hasMatch(value.toLowerCase());

  /// True se [value] è esattamente 32 char esadecimali lowercase.
  static bool isHex32(String value) => _hex32.hasMatch(value.toLowerCase());
}
