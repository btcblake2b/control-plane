import 'package:sqlite3/sqlite3.dart';

/// Nodo registrato — dati pseudonimi (mai seed, rune o PII).
class NodeRecord {
  const NodeRecord({
    required this.id,
    required this.bridgePubkey,
    required this.relay,
    this.alias,
    required this.version,
    required this.createdAt,
    this.rotatedAt,
    this.secretSha256 = '',
  });

  /// Identificatore pubblico del nodo (32 hex).
  final String id;

  /// Pubkey x-only del bridge (64 hex) — identità pubblica, non segreto.
  final String bridgePubkey;

  /// Relay Nostr configurato sul bridge (wss://).
  final String relay;

  /// Etichetta scelta dall'utente (facoltativa, nessun dato personale).
  final String? alias;

  /// Versione dell'installer che ha registrato il nodo.
  final String version;

  final DateTime createdAt;

  /// Valorizzato all'ultima rotazione del node_secret.
  final DateTime? rotatedAt;

  /// Hash del node_secret: USO INTERNO (verifica Bearer), mai serializzato.
  final String secretSha256;

  /// Rappresentazione pubblica per l'API (il secret NON c'è).
  Map<String, Object?> toApiJson() => {
        'id': id,
        'bridgePubkey': bridgePubkey,
        'relay': relay,
        'alias': alias,
        'version': version,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'rotatedAt': rotatedAt?.toUtc().toIso8601String(),
      };

  factory NodeRecord.fromRow(Row row) => NodeRecord(
        id: row['id'] as String,
        bridgePubkey: row['bridge_pubkey'] as String,
        relay: row['relay'] as String,
        alias: row['alias'] as String?,
        version: row['version'] as String,
        createdAt: DateTime.parse(row['created_at'] as String),
        rotatedAt: row['rotated_at'] == null
            ? null
            : DateTime.parse(row['rotated_at'] as String),
        secretSha256: (row['secret_sha256'] as String?) ?? '',
      );
}

/// Token di registrazione monouso.
class TokenRecord {
  const TokenRecord({
    required this.id,
    required this.tokenSha256,
    required this.note,
    required this.createdAt,
    required this.expiresAt,
    this.usedAt,
    this.usedNodeId,
  });

  final String id;
  final String tokenSha256;
  final String note;
  final DateTime createdAt;
  final DateTime expiresAt;
  final DateTime? usedAt;
  final String? usedNodeId;

  bool get isUsed => usedAt != null;

  bool isExpired(DateTime now) => !expiresAt.isAfter(now);

  factory TokenRecord.fromRow(Row row) => TokenRecord(
        id: row['id'] as String,
        tokenSha256: row['token_sha256'] as String,
        note: (row['note'] as String?) ?? '',
        createdAt: DateTime.parse(row['created_at'] as String),
        expiresAt: DateTime.parse(row['expires_at'] as String),
        usedAt: row['used_at'] == null
            ? null
            : DateTime.parse(row['used_at'] as String),
        usedNodeId: row['used_node_id'] as String?,
      );
}
