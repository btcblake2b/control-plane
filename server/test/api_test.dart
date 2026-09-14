import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';
import 'package:tlw_control_plane/src/api.dart';
import 'package:tlw_control_plane/src/auth.dart';
import 'package:tlw_control_plane/src/config.dart';
import 'package:tlw_control_plane/src/db.dart';
import 'package:tlw_control_plane/src/logging.dart';
import 'package:tlw_control_plane/src/rate_limit.dart';

void main() {
  late Db db;
  late HttpServer server;
  late String base;

  const config = ServerConfig(
    bind: '127.0.0.1',
    port: 0,
    dbPath: ':memory:',
    trustProxy: false,
    tokenTtl: Duration(hours: 24),
  );

  setUp(() async {
    db = Db.openInMemory();
    final handler = buildHandler(db: db, config: config, log: Log.silent());
    server = await shelf_io.serve(handler, '127.0.0.1', 0);
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() async {
    await server.close(force: true);
    db.close();
  });

  String newToken({Duration ttl = const Duration(hours: 24)}) {
    final token = AuthService.randomHex32();
    final now = DateTime.now().toUtc();
    db.insertToken(
      id: AuthService.randomHex16(),
      tokenSha256: AuthService.sha256Hex(token),
      note: 'test',
      createdAt: now,
      expiresAt: now.add(ttl),
    );
    return token;
  }

  Future<http.Response> register(String token,
      {String? pubkey, String relay = 'wss://relay.example'}) {
    final body = jsonEncode({
      'token': token,
      'bridgePubkey': pubkey ?? AuthService.randomHex32(),
      'relay': relay,
      'alias': 'test-node',
      'version': '0.1.0-test',
    });
    return http.post(
      Uri.parse('$base/v1/register'),
      body: body,
      headers: {'content-type': 'application/json'},
    );
  }

  Map<String, dynamic> errorCode(http.Response res) =>
      (jsonDecode(res.body) as Map<String, dynamic>)['error']
          as Map<String, dynamic>;

  group('POST /v1/register', () {
    test('201: nodeId + nodeSecret; secondo uso → 410 TOKEN_USED', () async {
      final token = newToken();
      final res = await register(token);
      expect(res.statusCode, 201);
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      expect(AuthService.isHex32(body['nodeId'] as String), isTrue);
      expect(AuthService.isHex64(body['nodeSecret'] as String), isTrue);

      final again = await register(token);
      expect(again.statusCode, 410);
      expect(errorCode(again)['code'], 'TOKEN_USED');
    });

    test('401 INVALID_TOKEN per token inesistente', () async {
      final res = await register(AuthService.randomHex32());
      expect(res.statusCode, 401);
      expect(errorCode(res)['code'], 'INVALID_TOKEN');
    });

    test('410 TOKEN_EXPIRED per token scaduto', () async {
      final res = await register(newToken(ttl: const Duration(minutes: -5)));
      expect(res.statusCode, 410);
      expect(errorCode(res)['code'], 'TOKEN_EXPIRED');
    });

    test('400 per body non JSON', () async {
      final res = await http.post(
        Uri.parse('$base/v1/register'),
        body: 'not-json',
        headers: {'content-type': 'application/json'},
      );
      expect(res.statusCode, 400);
      expect(errorCode(res)['code'], 'INVALID_REQUEST');
    });

    test('400 per relay/pubkey invalidi', () async {
      final relayBad =
          await register(newToken(), relay: 'http://non-valido');
      expect(relayBad.statusCode, 400);

      final pubkeyBad = await register(newToken(), pubkey: 'zz');
      expect(pubkeyBad.statusCode, 400);
    });

    test('409 su pubkey duplicata: token NON consumato, poi 201', () async {
      final pubkey = AuthService.randomHex32();
      expect((await register(newToken(), pubkey: pubkey)).statusCode, 201);

      final t2 = newToken();
      final conflict = await register(t2, pubkey: pubkey);
      expect(conflict.statusCode, 409);
      expect(errorCode(conflict)['code'], 'ALREADY_REGISTERED');

      // lo stesso token funziona con una pubkey nuova
      final retry = await register(t2);
      expect(retry.statusCode, 201);
    });
  });

  group('GET/DELETE /v1/nodes/<id>', () {
    test('get: 200 con secret; 401 senza/errato; 404 inesistente', () async {
      final res = await register(newToken());
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final id = body['nodeId'] as String;
      final secret = body['nodeSecret'] as String;

      final ok = await http.get(
        Uri.parse('$base/v1/nodes/$id'),
        headers: {'authorization': 'Bearer $secret'},
      );
      expect(ok.statusCode, 200);
      final node = jsonDecode(ok.body) as Map<String, dynamic>;
      expect(node['id'], id);
      // il materiale segreto non è MAI esposto
      expect(node.containsKey('secretSha256'), isFalse);
      expect(ok.body.contains(secret), isFalse);

      final noAuth = await http.get(Uri.parse('$base/v1/nodes/$id'));
      expect(noAuth.statusCode, 401);

      final wrong = await http.get(
        Uri.parse('$base/v1/nodes/$id'),
        headers: {'authorization': 'Bearer ${AuthService.randomHex32()}'},
      );
      expect(wrong.statusCode, 401);

      final missing = await http.get(
        Uri.parse('$base/v1/nodes/${AuthService.randomHex16()}'),
        headers: {'authorization': 'Bearer $secret'},
      );
      expect(missing.statusCode, 404);
    });

    test('delete: 204, poi get → 404', () async {
      final res = await register(newToken());
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final id = body['nodeId'] as String;
      final secret = body['nodeSecret'] as String;

      final del = await http.delete(
        Uri.parse('$base/v1/nodes/$id'),
        headers: {'authorization': 'Bearer $secret'},
      );
      expect(del.statusCode, 204);

      final after = await http.get(
        Uri.parse('$base/v1/nodes/$id'),
        headers: {'authorization': 'Bearer $secret'},
      );
      expect(after.statusCode, 404);
    });
  });

  group('POST /v1/nodes/<id>/rotate-secret', () {
    test('nuovo secret valido, vecchio invalidato', () async {
      final res = await register(newToken());
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final id = body['nodeId'] as String;
      final oldSecret = body['nodeSecret'] as String;

      final rotate = await http.post(
        Uri.parse('$base/v1/nodes/$id/rotate-secret'),
        headers: {'authorization': 'Bearer $oldSecret'},
      );
      expect(rotate.statusCode, 200);
      final fresh =
          (jsonDecode(rotate.body) as Map<String, dynamic>)['nodeSecret']
              as String;
      expect(fresh == oldSecret, isFalse);

      final withOld = await http.get(
        Uri.parse('$base/v1/nodes/$id'),
        headers: {'authorization': 'Bearer $oldSecret'},
      );
      expect(withOld.statusCode, 401);

      final withNew = await http.get(
        Uri.parse('$base/v1/nodes/$id'),
        headers: {'authorization': 'Bearer $fresh'},
      );
      expect(withNew.statusCode, 200);
    });
  });

  test('rate limit: 429 con Retry-After su register', () async {
    final db2 = Db.openInMemory();
    final handler = buildHandler(
      db: db2,
      config: config,
      log: Log.silent(),
      registerLimiter: RateLimiter(capacity: 2, refillPerSecond: 0.0),
      generalLimiter: RateLimiter(capacity: 100, refillPerSecond: 1.0),
    );
    final srv = await shelf_io.serve(handler, '127.0.0.1', 0);
    addTearDown(() async {
      await srv.close(force: true);
      db2.close();
    });
    final b = 'http://127.0.0.1:${srv.port}';

    Future<http.Response> post() => http.post(
          Uri.parse('$b/v1/register'),
          body: jsonEncode({
            'token': AuthService.randomHex32(),
            'bridgePubkey': AuthService.randomHex32(),
            'relay': 'wss://relay.example',
            'version': '0.1.0-test',
          }),
          headers: {'content-type': 'application/json'},
        );

    expect((await post()).statusCode, 401); // consuma 1
    expect((await post()).statusCode, 401); // consuma 2
    final third = await post();
    expect(third.statusCode, 429);
    expect(third.headers['retry-after'], isNotNull);
  });

  test('404 JSON su rotta sconosciuta', () async {
    final res = await http.get(Uri.parse('$base/v1/inesistente'));
    expect(res.statusCode, 404);
    expect(errorCode(res)['code'], 'NOT_FOUND');
  });
}
