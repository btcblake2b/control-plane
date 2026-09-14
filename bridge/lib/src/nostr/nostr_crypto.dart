import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:bip340/bip340.dart' as bip340;
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pointycastle/ecc/curves/secp256k1.dart';
import 'package:pointycastle/padded_block_cipher/padded_block_cipher_impl.dart';
import 'package:pointycastle/paddings/pkcs7.dart';

/// Crypto per il protocollo Nostr (NIP-01/NIP-04).
///
/// // PERCHÉ: copia del client Flutter (mobile/lib/core/services/nostr/
/// nostr_crypto.dart) — il bridge DEVE usare esattamente gli stessi algoritmi
/// del client, ed è puro Dart (bip340 + pointycastle): gira su VM.
/// Nota di sicurezza: questa classe NON deve mai loggare chiavi, plaintext o
/// payload decifrati.
class NostrCrypto {
  NostrCrypto._();

  // ── BIP340 (Schnorr) ────────────────────────────────────────────────────────

  /// Firma BIP340 su un messaggio di 32 byte (per Nostr: l'event id).
  ///
  /// [privkeyHex]: 64 char hex (secret di sessione NWC).
  /// [messageHex]: 64 char hex (id evento).
  /// [auxHex]: 32 byte random — generato se non fornito.
  static String schnorrSign({
    required String privkeyHex,
    required String messageHex,
    String? auxHex,
  }) {
    // PERCHÉ: il package richiede hex lowercase — normalizziamo all'ingresso.
    final aux = (auxHex ?? randomHex32()).toLowerCase();
    return bip340.sign(
      privkeyHex.toLowerCase(),
      messageHex.toLowerCase(),
      aux,
    );
  }

  /// Verifica una firma BIP340. [pubkeyHex] è x-only (64 char hex).
  static bool schnorrVerify({
    required String pubkeyHex,
    required String messageHex,
    required String signatureHex,
  }) {
    try {
      return bip340.verify(
        pubkeyHex.toLowerCase(),
        messageHex.toLowerCase(),
        signatureHex.toLowerCase(),
      );
    } catch (_) {
      // PERCHÉ: input malformati = firma non valida, mai eccezioni al chiamante.
      return false;
    }
  }

  /// Pubkey x-only (32 byte hex) dalla privkey — identità Nostr del bridge.
  static String derivePublicKey(String privkeyHex) =>
      bip340.getPublicKey(privkeyHex.toLowerCase());

  /// 32 byte casuali in hex: aux Schnorr / materiale per il secret della URI.
  static String randomHex32() {
    final bytes = _randomBytes(32);
    return _bytesToHex(bytes);
  }

  // ── NIP-04 ──────────────────────────────────────────────────────────────────

  /// Cifra [plaintext] per [pubkeyHex] secondo NIP-04.
  ///
  /// Formato: `base64(aes-256-cbc(sharedX)) + "?iv=" + base64(iv)`.
  static String nip04Encrypt({
    required String privkeyHex,
    required String pubkeyHex,
    required String plaintext,
  }) {
    final key = _sharedSecretX(privkeyHex: privkeyHex, pubkeyHex: pubkeyHex);
    final iv = _randomBytes(16);
    final ct = _aesCbc(
      encrypt: true,
      key: key,
      iv: iv,
      data: Uint8List.fromList(utf8.encode(plaintext)),
    );
    return '${base64.encode(ct)}?iv=${base64.encode(iv)}';
  }

  /// Decifra un payload NIP-04 (`…?iv=…`). Lancia [FormatException] se il
  /// formato è invalido.
  static String nip04Decrypt({
    required String privkeyHex,
    required String pubkeyHex,
    required String payload,
  }) {
    final sep = payload.lastIndexOf('?iv=');
    if (sep < 0) {
      throw const FormatException('Payload NIP-04 senza ?iv=');
    }
    final ct = base64.decode(payload.substring(0, sep));
    final iv = base64.decode(payload.substring(sep + 4));
    if (iv.length != 16) {
      throw const FormatException('IV NIP-04 non di 16 byte');
    }
    final key = _sharedSecretX(privkeyHex: privkeyHex, pubkeyHex: pubkeyHex);
    final pt = _aesCbc(
      encrypt: false,
      key: key,
      iv: iv,
      data: ct,
    );
    return utf8.decode(pt);
  }

  // ── Internals ───────────────────────────────────────────────────────────────

  /// ECDH secp256k1 → coordinata X del punto condiviso (32 byte), CHE È la
  /// chiave AES di NIP-04 (non hashata — convenzione Nostr, NON libsecp256k1).
  ///
  /// // PERCHÉ x-only: le pubkey Nostr sono a 32 byte; il punto si ricostruisce
  /// col prefisso 0x02 (Y pari). Le differenze di parità non cambiano la X del
  /// punto condiviso, quindi il valore coincide con quello calcolato dall'app.
  static Uint8List _sharedSecretX({
    required String privkeyHex,
    required String pubkeyHex,
  }) {
    final curve = ECCurve_secp256k1();
    var pubBytes = _hexToBytes(pubkeyHex);
    if (pubBytes.length == 32) {
      pubBytes = Uint8List.fromList([0x02, ...pubBytes]);
    }
    final point = curve.curve.decodePoint(pubBytes);
    if (point == null) {
      throw const FormatException('Pubkey non valida per ECDH');
    }
    final d = BigInt.parse(privkeyHex, radix: 16);
    // Nota: in pointycastle i punti sono già in coordinate affini (non esiste
    // normalize()): x/y sono utilizzabili direttamente dopo la moltiplicazione.
    final shared = point * d;
    if (shared == null || shared.isInfinity) {
      throw StateError('ECDH fallito (punto all\'infinito)');
    }
    return _bigIntToBytes32(shared.x!.toBigInteger()!);
  }

  static Uint8List _aesCbc({
    required bool encrypt,
    required Uint8List key,
    required Uint8List iv,
    required Uint8List data,
  }) {
    final cipher =
        PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()));
    cipher.init(
      encrypt,
      PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
        ParametersWithIV<KeyParameter>(KeyParameter(key), iv),
        null,
      ),
    );
    return cipher.process(data);
  }

  static Uint8List _randomBytes(int n) {
    final rnd = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(n, (_) => rnd.nextInt(256)),
    );
  }

  static Uint8List _hexToBytes(String hex) {
    if (hex.length.isOdd) {
      throw const FormatException('Hex di lunghezza dispari');
    }
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  static String _bytesToHex(Uint8List bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// Converte un BigInt in 32 byte big-endian.
  ///
  /// // PERCHÉ: conversione manuale — BigInt di dart:core non espone un
  /// metodo "toBytes" (esiste solo in pacchetti terzi).
  static Uint8List _bigIntToBytes32(BigInt v) {
    final out = Uint8List(32);
    var value = v;
    for (var i = 31; i >= 0; i--) {
      out[i] = (value & BigInt.from(0xff)).toInt();
      value = value >> 8;
    }
    return out;
  }
}
