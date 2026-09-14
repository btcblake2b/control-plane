import 'dart:io';

import 'package:test/test.dart';
import 'package:tlw_control_plane/src/admin_cli.dart';
import 'package:tlw_control_plane/src/auth.dart';
import 'package:tlw_control_plane/src/db.dart';
import 'package:tlw_control_plane/src/models.dart';

void main() {
  late Directory tmp;
  late String dbPath;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tlw_cp_admin_');
    dbPath = '${tmp.path}/control.db';
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  test('token create: stampa il token una volta e lo salva hashato', () async {
    final lines = <String>[];
    final runner = buildAdminRunner(print: lines.add);
    final code = await runner.run(
        ['token', 'create', '--note', 'test', '--ttl', '1h', '--db', dbPath]);
    expect(code, 0);

    final tokenLine = lines.firstWhere((l) => l.contains('token:'));
    final token =
        RegExp(r'[0-9a-f]{64}').firstMatch(tokenLine)!.group(0)!;

    final db = Db.open(dbPath);
    final record = db.findTokenByHash(AuthService.sha256Hex(token));
    expect(record, isNotNull);
    expect(record!.note, 'test');
    expect(record.usedAt, isNull);
    db.close();
  });

  test('token purge: rimuove i token scaduti oltre la soglia', () async {
    final db = Db.open(dbPath);
    final past = DateTime.now().toUtc().subtract(const Duration(days: 10));
    db.insertToken(
      id: AuthService.randomHex16(),
      tokenSha256: AuthService.sha256Hex('x' * 64),
      note: 'vecchio',
      createdAt: past,
      expiresAt: past.add(const Duration(hours: 1)),
    );
    db.close();

    final lines = <String>[];
    final runner = buildAdminRunner(print: lines.add);
    expect(await runner.run(['token', 'purge', '--db', dbPath]), 0);
    expect(lines.join('\n'), contains(': 1'));

    final db2 = Db.open(dbPath);
    expect(db2.listTokens().isEmpty, isTrue);
    db2.close();
  });

  test('node delete: senza --yes non rimuove, con --yes sì', () async {
    final db = Db.open(dbPath);
    final node = NodeRecord(
      id: AuthService.randomHex16(),
      bridgePubkey: AuthService.randomHex32(),
      relay: 'wss://relay.example',
      version: '0.1.0-test',
      createdAt: DateTime.now().toUtc(),
    );
    db.registerNode(
      node: node,
      secretSha256: AuthService.sha256Hex('secret'),
      tokenId: 'token-non-necessario-per-il-test',
    );
    db.close();

    final lines = <String>[];
    final runner = buildAdminRunner(print: lines.add);

    expect(await runner.run(['node', 'delete', node.id, '--db', dbPath]), 1);
    var check = Db.open(dbPath);
    expect(check.findNode(node.id), isNotNull);
    check.close();

    expect(
      await runner.run(['node', 'delete', node.id, '--yes', '--db', dbPath]),
      0,
    );
    check = Db.open(dbPath);
    expect(check.findNode(node.id), isNull);
    check.close();
  });

  test('node list: stampa i nodi registrati', () async {
    final db = Db.open(dbPath);
    final node = NodeRecord(
      id: AuthService.randomHex16(),
      bridgePubkey: AuthService.randomHex32(),
      relay: 'wss://relay.example',
      alias: 'casa',
      version: '0.1.0-test',
      createdAt: DateTime.now().toUtc(),
    );
    db.registerNode(
      node: node,
      secretSha256: AuthService.sha256Hex('secret'),
      tokenId: 'token-non-necessario-per-il-test',
    );
    db.close();

    final lines = <String>[];
    final runner = buildAdminRunner(print: lines.add);
    expect(await runner.run(['node', 'list', '--db', dbPath]), 0);
    expect(lines.join('\n'), contains('casa'));
    expect(lines.join('\n'), contains(node.id));
  });
}
