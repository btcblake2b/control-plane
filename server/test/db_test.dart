import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tlw_control_plane/src/auth.dart';
import 'package:tlw_control_plane/src/db.dart';
import 'package:tlw_control_plane/src/models.dart';

void main() {
  late Db db;

  setUp(() {
    db = Db.openInMemory();
  });

  tearDown(() {
    db.close();
  });

  NodeRecord makeNode({String? pubkey}) => NodeRecord(
        id: AuthService.randomHex16(),
        bridgePubkey: pubkey ?? AuthService.randomHex32(),
        relay: 'wss://relay.example',
        version: '0.1.0-test',
        createdAt: DateTime.now().toUtc(),
      );

  ({String token, String id}) insertToken({Duration ttl = const Duration(hours: 24)}) {
    final token = AuthService.randomHex32();
    final id = AuthService.randomHex16();
    final now = DateTime.now().toUtc();
    db.insertToken(
      id: id,
      tokenSha256: AuthService.sha256Hex(token),
      note: 'test',
      createdAt: now,
      expiresAt: now.add(ttl),
    );
    return (token: token, id: id);
  }

  group('Db — token', () {
    test('insert + findTokenByHash', () {
      final t = insertToken();
      final record = db.findTokenByHash(AuthService.sha256Hex(t.token));
      expect(record, isNotNull);
      expect(record!.id, t.id);
      expect(record.usedAt, isNull);
    });

    test('listTokens onlyActive esclude usati e scaduti', () {
      final active = insertToken();
      final expired = insertToken(ttl: const Duration(minutes: -5));
      // consuma "active" registrando un nodo
      final node = makeNode();
      db.registerNode(
        node: node,
        secretSha256: AuthService.sha256Hex('secret-a'),
        tokenId: active.id,
      );
      final onlyActive = db.listTokens(onlyActive: true);
      expect(onlyActive.map((t) => t.id), isNot(contains(active.id)));
      expect(onlyActive.map((t) => t.id), isNot(contains(expired.id)));
      expect(db.listTokens().length, 2);
    });

    test('purgeTokens rimuove solo oltre la soglia', () {
      final old = insertToken(ttl: const Duration(minutes: -5));
      final fresh = insertToken();
      // soglia: adesso - 1 giorno → "old" (scaduto 5 min fa) NON è oltre soglia
      final removed = db
          .purgeTokens(threshold: DateTime.now().toUtc().subtract(const Duration(days: 1)));
      expect(removed, 0);
      // soglia: adesso + 1 ora → entrambi scaduti prima di allora
      final removed2 = db.purgeTokens(
          threshold: DateTime.now().toUtc().add(const Duration(hours: 1)));
      expect(removed2, 1);
      expect(db.findTokenByHash(AuthService.sha256Hex(old.token)), isNull);
      // "fresh" scade tra 24h: con soglia +1h non è oltre soglia
      expect(db.findTokenByHash(AuthService.sha256Hex(fresh.token)), isNotNull);
    });
  });

  group('Db — nodi', () {
    test('registerNode consuma il token (stessa transazione)', () {
      final t = insertToken();
      final node = makeNode();
      db.registerNode(
        node: node,
        secretSha256: AuthService.sha256Hex('secret-1'),
        tokenId: t.id,
      );
      final token = db.findTokenByHash(AuthService.sha256Hex(t.token));
      expect(token!.usedAt, isNotNull);
      expect(token.usedNodeId, node.id);
      expect(db.findNode(node.id), isNotNull);
    });

    test('pubkey duplicata → eccezione e token NON consumato', () {
      final t1 = insertToken();
      final first = makeNode();
      db.registerNode(
        node: first,
        secretSha256: AuthService.sha256Hex('secret-1'),
        tokenId: t1.id,
      );

      final t2 = insertToken();
      final dup = makeNode(pubkey: first.bridgePubkey);
      expect(
        () => db.registerNode(
          node: dup,
          secretSha256: AuthService.sha256Hex('secret-2'),
          tokenId: t2.id,
        ),
        throwsA(isA<SqliteException>()),
      );
      // il token del secondo tentativo resta utilizzabile (recovery via admin)
      final token2 = db.findTokenByHash(AuthService.sha256Hex(t2.token));
      expect(token2!.usedAt, isNull);
      expect(db.findNode(dup.id), isNull);
    });

    test('deleteNode: true se esiste, false altrimenti', () {
      final t = insertToken();
      final node = makeNode();
      db.registerNode(
        node: node,
        secretSha256: AuthService.sha256Hex('secret-1'),
        tokenId: t.id,
      );
      expect(db.deleteNode(node.id), isTrue);
      expect(db.deleteNode(node.id), isFalse);
      expect(db.findNode(node.id), isNull);
    });

    test('rotateSecret aggiorna hash e timestamp', () {
      final t = insertToken();
      final node = makeNode();
      db.registerNode(
        node: node,
        secretSha256: AuthService.sha256Hex('old'),
        tokenId: t.id,
      );
      final rotatedAt = DateTime.now().toUtc();
      db.rotateSecret(
        node.id,
        secretSha256: AuthService.sha256Hex('new'),
        rotatedAt: rotatedAt,
      );
      final after = db.findNode(node.id)!;
      expect(after.secretSha256, AuthService.sha256Hex('new'));
      expect(after.rotatedAt, isNotNull);
    });
  });
}
