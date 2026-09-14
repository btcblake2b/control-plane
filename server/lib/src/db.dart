import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'models.dart';

/// Accesso a SQLite: schema, query e transazioni del control plane.
///
/// // PERCHÉ (sicurezza): qui vivono SOLO hash (token, node_secret) e dati
/// pseudonimi (pubkey, relay, alias, versione, timestamp); mai seed, rune o
/// credenziali di accesso ai server degli utenti.
class Db {
  Db._(this._db);

  final Database _db;

  static const String _ddlTokens = '''
CREATE TABLE IF NOT EXISTS tokens (
  id            TEXT PRIMARY KEY,
  token_sha256  TEXT NOT NULL UNIQUE,
  note          TEXT NOT NULL DEFAULT '',
  created_at    TEXT NOT NULL,
  expires_at    TEXT NOT NULL,
  used_at       TEXT,
  used_node_id  TEXT
)''';

  static const String _ddlNodes = '''
CREATE TABLE IF NOT EXISTS nodes (
  id            TEXT PRIMARY KEY,
  bridge_pubkey TEXT NOT NULL UNIQUE,
  relay         TEXT NOT NULL,
  alias         TEXT,
  version       TEXT NOT NULL,
  secret_sha256 TEXT NOT NULL,
  created_at    TEXT NOT NULL,
  rotated_at    TEXT
)''';

  static const String _ddlIndex =
      'CREATE INDEX IF NOT EXISTS idx_tokens_expires ON tokens(expires_at)';

  /// Apre (o crea) il DB al [path] e applica lo schema (idempotente).
  static Db open(String path) {
    if (path != ':memory:') {
      final parent = File(path).parent;
      if (!parent.existsSync()) {
        parent.createSync(recursive: true);
      }
    }
    final database = sqlite3.open(path);
    // PERCHÉ WAL: letture concorrenti durante le scritture — con un registro
    // di provisioning a bassa frequenza garantisce commit più robusti.
    database.execute('PRAGMA journal_mode = WAL;');
    database.execute(_ddlTokens);
    database.execute(_ddlNodes);
    database.execute(_ddlIndex);
    return Db._(database);
  }

  static Db openInMemory() => open(':memory:');

  // ── Token ──────────────────────────────────────────────────────────────────

  void insertToken({
    required String id,
    required String tokenSha256,
    required String note,
    required DateTime createdAt,
    required DateTime expiresAt,
  }) {
    _db.execute(
      'INSERT INTO tokens (id, token_sha256, note, created_at, expires_at) '
      'VALUES (?, ?, ?, ?, ?)',
      [id, tokenSha256, note, _iso(createdAt), _iso(expiresAt)],
    );
  }

  TokenRecord? findTokenByHash(String tokenSha256) {
    final rows =
        _db.select('SELECT * FROM tokens WHERE token_sha256 = ?', [tokenSha256]);
    return rows.isEmpty ? null : TokenRecord.fromRow(rows.first);
  }

  /// Lista token: [onlyActive] = non usati e non scaduti.
  List<TokenRecord> listTokens({bool onlyActive = false}) {
    final rows = onlyActive
        ? _db.select(
            'SELECT * FROM tokens WHERE used_at IS NULL AND expires_at > ? '
            'ORDER BY created_at DESC',
            [_iso(DateTime.now().toUtc())],
          )
        : _db.select('SELECT * FROM tokens ORDER BY created_at DESC');
    return rows.map(TokenRecord.fromRow).toList();
  }

  /// Elimina token scaduti o usati prima di [threshold]. Ritorna il conteggio.
  int purgeTokens({required DateTime threshold}) {
    _db.execute(
      'DELETE FROM tokens WHERE (expires_at < ?) OR '
      '(used_at IS NOT NULL AND used_at < ?)',
      [_iso(threshold), _iso(threshold)],
    );
    return _db.updatedRows;
  }

  // ── Nodi ───────────────────────────────────────────────────────────────────

  bool pubkeyExists(String bridgePubkey) =>
      _db.select('SELECT 1 FROM nodes WHERE bridge_pubkey = ?', [bridgePubkey]).isNotEmpty;

  NodeRecord? findNode(String id) {
    final rows = _db.select('SELECT * FROM nodes WHERE id = ?', [id]);
    return rows.isEmpty ? null : NodeRecord.fromRow(rows.first);
  }

  List<NodeRecord> listNodes() =>
      _db.select('SELECT * FROM nodes ORDER BY created_at DESC').map(NodeRecord.fromRow).toList();

  /// Registra un nodo e consuma il token in un'unica transazione.
  ///
  /// // PERCHÉ: senza transazione, un crash tra insert e update lascerebbe il
  /// token riutilizzabile (doppia registrazione) o un nodo non tracciato.
  void registerNode({
    required NodeRecord node,
    required String secretSha256,
    required String tokenId,
  }) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      _db.execute(
        'INSERT INTO nodes (id, bridge_pubkey, relay, alias, version, '
        'secret_sha256, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
        [
          node.id,
          node.bridgePubkey,
          node.relay,
          node.alias,
          node.version,
          secretSha256,
          _iso(node.createdAt),
        ],
      );
      _db.execute(
        'UPDATE tokens SET used_at = ?, used_node_id = ? WHERE id = ?',
        [_iso(DateTime.now().toUtc()), node.id, tokenId],
      );
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Hard delete del record (il nodo sul server dell'utente NON è toccato).
  bool deleteNode(String id) {
    _db.execute('DELETE FROM nodes WHERE id = ?', [id]);
    return _db.updatedRows > 0;
  }

  void rotateSecret(String id, {required String secretSha256, required DateTime rotatedAt}) {
    _db.execute(
      'UPDATE nodes SET secret_sha256 = ?, rotated_at = ? WHERE id = ?',
      [secretSha256, _iso(rotatedAt), id],
    );
  }

  void close() => _db.dispose();

  static String _iso(DateTime dt) => dt.toUtc().toIso8601String();
}
