import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:nwc_cln_bridge/src/bridge_service.dart';
import 'package:nwc_cln_bridge/src/cln/cln_api.dart';
import 'package:nwc_cln_bridge/src/cln/reloadable_cln.dart';
import 'package:nwc_cln_bridge/src/config.dart';
import 'package:nwc_cln_bridge/src/handlers.dart';
import 'package:nwc_cln_bridge/src/nostr/nostr_event.dart';
import 'package:nwc_cln_bridge/src/nostr/nostr_transport.dart';
import 'package:nwc_cln_bridge/src/web/status_server.dart';
import 'package:test/test.dart';

class _FakeTransport implements NostrTransport {
  bool connected = true;
  final _events = StreamController<NostrEvent>.broadcast();

  @override
  bool get isConnected => connected;

  @override
  DateTime? get connectedSince => DateTime.now();

  @override
  Future<void> connect(String relayUrl) async => connected = true;

  @override
  Future<void> publish(NostrEvent event) async {}

  @override
  Stream<NostrEvent> subscribe(List<Map<String, dynamic>> filters) =>
      _events.stream;

  @override
  Future<void> close() async {
    connected = false;
    await _events.close();
  }
}

class _FakeCln implements ClnApi {
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async =>
      switch (method) {
        'getinfo' => <String, dynamic>{
            'id': '02aa',
            'network': 'blake2b',
            'alias': 'test',
          },
        'listpeers' => <String, dynamic>{'peers': <dynamic>[]},
        _ => <String, dynamic>{},
      };
}

void main() {
  late Directory tmp;
  late String configPath;
  late BridgeConfig config;

  BridgeService buildService() => BridgeService(
        transport: _FakeTransport(),
        handlers: NwcHandlers(cln: _FakeCln()),
        config: config,
      );

  StatusServer buildServer({String? token}) => StatusServer(
        config: config,
        configPath: configPath,
        service: buildService(),
        cln: ReloadableCln(config: config),
        port: 0,
        token: token,
      );

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bridge_ui_');
    configPath = '${tmp.path}/config.json';
    config = BridgeConfig(
      relay: 'wss://relay.test',
      privkeyHex: '11' * 32,
      clnUrl: 'http://127.0.0.1:3001',
      runeHex: 'test-rune',
    );
    config.saveToFile(configPath);
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  test('GET /api/status risponde con lo stato del bridge', () async {
    final server = buildServer();
    await server.start();
    addTearDown(server.stop);

    final res = await http.get(
      Uri.parse('http://127.0.0.1:${server.boundPort}/api/status'),
    );

    expect(res.statusCode, 200);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    expect(body['relay'], 'wss://relay.test');
    expect(body['connected'], isTrue);
    expect(body['clients'], 0);
  });

  test('GET / mostra QR e URI, senza autorizzare un client a ogni ricarica',
      () async {
    final server = buildServer();
    await server.start();
    addTearDown(server.stop);
    final base = 'http://127.0.0.1:${server.boundPort}/';

    final first = await http.get(Uri.parse(base));
    expect(first.statusCode, 200);
    expect(first.body, contains('<svg'));
    expect(File('${tmp.path}/uri.txt').existsSync(), isTrue);

    final second = await http.get(Uri.parse(base));
    // // PERCHÉ: due GET devono riusare la STESSA URI: senza la cache ogni
    // ricarica autorizzerebbe un dispositivo fantasma.
    expect(second.body, contains('authorized devices: 1'));
  });

  test('POST /api/uri autorizza un nuovo client', () async {
    final server = buildServer();
    await server.start();
    addTearDown(server.stop);

    final res = await http.post(
      Uri.parse('http://127.0.0.1:${server.boundPort}/api/uri'),
    );

    expect(res.statusCode, 200);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    expect('${body['uri']}', startsWith('nostr+walletconnect://'));
    expect(
      BridgeConfig.fromJsonFile(configPath).allowedClientPubkeys,
      hasLength(1),
    );
  });

  test('con token configurato, le richieste senza token sono rifiutate',
      () async {
    final server = buildServer(token: 'secret');
    await server.start();
    addTearDown(server.stop);
    final base = 'http://127.0.0.1:${server.boundPort}/api/status';

    expect((await http.get(Uri.parse(base))).statusCode, 401);
    expect((await http.get(Uri.parse('$base?token=secret'))).statusCode, 200);
  });

  test('POST /api/config salva URL e rune e le applica al bridge', () async {
    final server = buildServer();
    await server.start();
    addTearDown(server.stop);

    final res = await http.post(
      Uri.parse('http://127.0.0.1:${server.boundPort}/api/config'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'clnUrl': 'http://127.0.0.1:3010',
        'rune': 'TEST_RUNE_VALUE',
      }),
    );

    expect(res.statusCode, 200);
    expect((jsonDecode(res.body) as Map)['ok'], isTrue);

    final saved = BridgeConfig.fromJsonFile(configPath);
    expect(saved.clnUrl, 'http://127.0.0.1:3010');
    expect(saved.runeFile, isNotNull);
    // // PERCHÉ: la rune deve essere leggibile dal bridge nel formato di RTL
    // (LIGHTNING_RUNE="…"), altrimenti il nodo resterebbe inaccessibile.
    expect(saved.loadRune(), 'TEST_RUNE_VALUE');
  });

  test('POST /api/config rifiuta un URL non http(s)', () async {
    final server = buildServer();
    await server.start();
    addTearDown(server.stop);

    final res = await http.post(
      Uri.parse('http://127.0.0.1:${server.boundPort}/api/config'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'clnUrl': 'ftp://nope'}),
    );

    expect((jsonDecode(res.body) as Map)['ok'], isFalse);
    // // PERCHÉ: un salvataggio rifiutato non deve alterare la config valida.
    expect(BridgeConfig.fromJsonFile(configPath).clnUrl, 'http://127.0.0.1:3001');
  });
}
