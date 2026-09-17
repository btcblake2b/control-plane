import 'dart:convert';
import 'dart:io';

import 'package:nwc_cln_bridge/src/cln/reloadable_cln.dart';
import 'package:nwc_cln_bridge/src/config.dart';
import 'package:nwc_cln_bridge/src/protocol.dart';
import 'package:test/test.dart';

void main() {
  BridgeConfig configWith(String clnUrl) => BridgeConfig(
        relay: 'wss://relay.test',
        privkeyHex: '11' * 32,
        clnUrl: clnUrl,
        runeHex: 'test-rune',
      );

  test('senza nodo configurato lancia un errore esplicito', () async {
    final cln = ReloadableCln(config: configWith(''));

    await expectLater(
      cln.call('getinfo'),
      throwsA(
        isA<RpcError>().having(
          (e) => e.message,
          'message',
          contains('Nodo non configurato'),
        ),
      ),
    );
  });

  test('con un nodo configurato invia rune e percorso corretti', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final requests = <String>[];
    server.listen((req) async {
      requests.add('${req.headers.value('rune')} ${req.uri.path}');
      req.response.headers.contentType = ContentType.json;
      // // PERCHÉ: clnrest risponde 201 sui comandi riusciti.
      req.response.statusCode = 201;
      req.response.write(jsonEncode({'network': 'blake2b'}));
      await req.response.close();
    });

    final cln = ReloadableCln(
      config: configWith('http://127.0.0.1:${server.port}'),
    );

    final res = await cln.call('getinfo');

    expect(res['network'], 'blake2b');
    expect(requests.single, 'test-rune /v1/getinfo');
  });

  test('rune non leggibile → errore esplicito, il bridge resta vivo', () async {
    final cln = ReloadableCln(
      config: BridgeConfig(
        relay: 'wss://relay.test',
        privkeyHex: '11' * 32,
        clnUrl: 'http://127.0.0.1:9',
        // // PERCHÉ: è il caso reale di StartOS (Revoke Runes cancella
        // `.commando-env` prima di rigenerarla): la costruzione del client
        // fallisce e non deve propagarsi oltre i confini del bridge.
        runeFile: '/nonexistent/bridge-rune',
      ),
    );

    await expectLater(
      cln.call('getinfo'),
      throwsA(
        isA<RpcError>().having(
          (e) => e.message,
          'message',
          contains('Nodo non disponibile'),
        ),
      ),
    );
  });

  test('reload cambia il nodo di destinazione a caldo', () async {
    final first = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final second = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(first.close);
    addTearDown(second.close);
    var hits = 0;
    Future<void> respond(HttpRequest req) async {
      hits++;
      req.response.headers.contentType = ContentType.json;
      req.response.statusCode = 201;
      req.response.write(jsonEncode({'alias': 'n${req.connectionInfo?.localPort}'}));
      await req.response.close();
    }

    first.listen(respond);
    second.listen(respond);

    final cln = ReloadableCln(
      config: configWith('http://127.0.0.1:${first.port}'),
    );
    await cln.call('getinfo');

    // // PERCHÉ: è il percorso usato dal form della pagina di stato: senza
    // reload il client resterebbe puntato al vecchio nodo fino al riavvio.
    cln.reload(configWith('http://127.0.0.1:${second.port}'));
    await cln.call('getinfo');

    expect(hits, 2);
  });
}
