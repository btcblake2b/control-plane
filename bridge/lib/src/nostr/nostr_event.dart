import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'nostr_crypto.dart';

/// Evento Nostr (NIP-01): id canonico, firma BIP340, serializzazione JSON.
///
/// // PERCHÉ: copia del client Flutter (mobile/lib/core/services/nostr/
/// nostr_event.dart) — bridge e client devono produrre id/firme identici.
class NostrEvent {
  const NostrEvent({
    required this.id,
    required this.pubkey,
    required this.createdAt,
    required this.kind,
    required this.tags,
    required this.content,
    required this.sig,
  });

  final String id;
  final String pubkey;
  final int createdAt;
  final int kind;
  final List<List<String>> tags;
  final String content;
  final String sig;

  /// Crea un evento NON firmato con l'id canonico già calcolato.
  factory NostrEvent.unsigned({
    required String pubkey,
    required int kind,
    List<List<String>> tags = const [],
    String content = '',
    int? createdAt,
  }) {
    final ts = createdAt ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final id = computeId(
      pubkey: pubkey,
      createdAt: ts,
      kind: kind,
      tags: tags,
      content: content,
    );
    return NostrEvent(
      id: id,
      pubkey: pubkey,
      createdAt: ts,
      kind: kind,
      tags: tags,
      content: content,
      sig: '',
    );
  }

  /// id = sha256(utf8(jsonEncode([0, pubkey, created_at, kind, tags, content]))).
  ///
  /// // PERCHÉ: jsonEncode di Dart produce la serializzazione canonica richiesta
  /// da NIP-01 (UTF-8, nessuno spazio, escaping minimale).
  static String computeId({
    required String pubkey,
    required int createdAt,
    required int kind,
    required List<List<String>> tags,
    required String content,
  }) {
    final serialized = jsonEncode([0, pubkey, createdAt, kind, tags, content]);
    return sha256.convert(utf8.encode(serialized)).toString();
  }

  /// Firma l'evento con la privkey Nostr (hex). Ritorna una nuova istanza.
  NostrEvent sign(String privkeyHex) {
    final signature = NostrCrypto.schnorrSign(
      privkeyHex: privkeyHex,
      messageHex: id,
    );
    return copyWith(sig: signature);
  }

  /// Verifica la firma rispetto all'id dell'evento.
  bool verify() =>
      sig.isNotEmpty &&
      NostrCrypto.schnorrVerify(
        pubkeyHex: pubkey,
        messageHex: id,
        signatureHex: sig,
      );

  bool get isSigned => sig.isNotEmpty;

  /// Primo valore di un tag a lettera singola (es. `firstTagValue('e')`).
  String? firstTagValue(String name) {
    for (final tag in tags) {
      if (tag.isNotEmpty && tag.first == name && tag.length > 1) {
        return tag[1];
      }
    }
    return null;
  }

  NostrEvent copyWith({String? sig}) => NostrEvent(
        id: id,
        pubkey: pubkey,
        createdAt: createdAt,
        kind: kind,
        tags: tags,
        content: content,
        sig: sig ?? this.sig,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'pubkey': pubkey,
        'created_at': createdAt,
        'kind': kind,
        'tags': tags,
        'content': content,
        'sig': sig,
      };

  factory NostrEvent.fromJson(Map<String, dynamic> json) => NostrEvent(
        id: json['id'] as String? ?? '',
        pubkey: json['pubkey'] as String? ?? '',
        createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
        kind: (json['kind'] as num?)?.toInt() ?? 0,
        tags: ((json['tags'] as List?) ?? const [])
            .map<List<String>>(
              (t) => ((t as List?) ?? const []).map((v) => '$v').toList(),
            )
            .toList(),
        content: json['content'] as String? ?? '',
        sig: json['sig'] as String? ?? '',
      );
}
