import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nwc_cln_bridge/src/cln/cln_api.dart';
import 'package:nwc_cln_bridge/src/protocol.dart';
import 'package:test/test.dart';

void main() {
  group('ClnRestClient', () {
    test('accetta HTTP 201 — clnrest usa Created sui comandi riusciti',
        () async {
      final mock = MockClient((req) async {
        expect(req.headers['rune'], 'test-rune');
        expect(req.url.path, '/v1/getinfo');
        return http.Response(jsonEncode({'id': '02aa'}), 201);
      });
      final client = ClnRestClient(
        baseUrl: 'http://127.0.0.1:3001',
        rune: 'test-rune',
        httpClient: mock,
      );
      final res = await client.call('getinfo');
      expect(res['id'], '02aa');
    });

    test('HTTP con body error → RpcError con messaggio del nodo', () async {
      final mock = MockClient(
        (req) async => http.Response(
          jsonEncode({
            'error': {
              'code': -32602,
              'message': 'missing required parameter',
            },
          }),
          500,
        ),
      );
      final client = ClnRestClient(
        baseUrl: 'http://127.0.0.1:3001',
        rune: 'r',
        httpClient: mock,
      );
      expect(
        () => client.call('invoice'),
        throwsA(
          isA<RpcError>().having(
            (e) => e.message,
            'message',
            contains('missing required parameter'),
          ),
        ),
      );
    });

    test('401 senza body → RESTRICTED (check prima del parse)', () async {
      final mock = MockClient((req) async => http.Response('', 401));
      final client = ClnRestClient(
        baseUrl: 'http://x',
        rune: 'r',
        httpClient: mock,
      );
      expect(
        () => client.call('getinfo'),
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', 'RESTRICTED'),
        ),
      );
    });

    test('errore di rete → RpcError OTHER', () async {
      final mock = MockClient((req) async => throw Exception('refused'));
      final client = ClnRestClient(
        baseUrl: 'http://x',
        rune: 'r',
        httpClient: mock,
      );
      expect(
        () => client.call('getinfo'),
        throwsA(
          isA<RpcError>().having(
            (e) => e.message,
            'message',
            contains('CLN non raggiungibile'),
          ),
        ),
      );
    });
  });
}
