import 'dart:async';
import 'dart:convert';

import 'package:nwc_cln_bridge/src/bridge_service.dart';
import 'package:nwc_cln_bridge/src/cln/cln_api.dart';
import 'package:nwc_cln_bridge/src/config.dart';
import 'package:nwc_cln_bridge/src/handlers.dart';
import 'package:nwc_cln_bridge/src/nostr/nostr_crypto.dart';
import 'package:nwc_cln_bridge/src/nostr/nostr_event.dart';
import 'package:nwc_cln_bridge/src/nostr/nostr_transport.dart';
import 'package:nwc_cln_bridge/src/protocol.dart';
import 'package:test/test.dart';

/// Transport Nostr finto: gli eventi si iniettano e si legge cosa è stato
/// pubblicato — il test copre il giro completo richiesta→risposta.
class FakeTransport implements NostrTransport {
  final StreamController<NostrEvent> _incoming =
      StreamController<NostrEvent>.broadcast();
  final List<NostrEvent> published = [];

  @override
  bool isConnected = false;

  @override
  DateTime? connectedSince;

  /// Contatore riconnessioni: verifica il riciclo preventivo.
  int connectCalls = 0;

  @override
  Future<void> connect(String relayUrl) async {
    connectCalls++;
    isConnected = true;
    connectedSince = DateTime.now();
  }

  @override
  Future<void> publish(NostrEvent event) async {
    published.add(event);
  }

  @override
  Stream<NostrEvent> subscribe(List<Map<String, dynamic>> filters) =>
      _incoming.stream;

  @override
  Future<void> close() async {
    isConnected = false;
    connectedSince = null;
  }

  void inject(NostrEvent event) => _incoming.add(event);
}

/// Nodo CLN finto minimale per il giro end-to-end.
class FakeCln implements ClnApi {
  Map<String, dynamic> invoices = const {'invoices': []};
  Map<String, dynamic> pays = const {'pays': []};
  Map<String, dynamic> channels = const {'channels': []};

  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    switch (method) {
      case 'getinfo':
        return {'id': '02aa', 'alias': 'test', 'blockheight': 100};
      case 'listfunds':
        return {
          'outputs': [
            {'amount_msat': 5000000, 'status': 'confirmed', 'reserved': false},
          ],
        };
      case 'listpeerchannels':
        return channels;
      case 'listinvoices':
        return invoices;
      case 'listpays':
        return pays;
      default:
        throw RpcError('OTHER', 'non simulato: $method');
    }
  }
}

Future<void> _waitFor(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late String bridgePriv;
  late String clientPriv;
  late String clientPub;
  late FakeTransport transport;
  late BridgeService service;
  late BridgeConfig config;

  setUp(() async {
    bridgePriv = NostrCrypto.randomHex32();
    clientPriv = NostrCrypto.randomHex32();
    clientPub = NostrCrypto.derivePublicKey(clientPriv);
    transport = FakeTransport();
    config = BridgeConfig(
      relay: 'wss://relay.test',
      privkeyHex: bridgePriv,
      clnUrl: 'http://127.0.0.1:3001',
      allowedClientPubkeys: [clientPub],
    );
    service = BridgeService(
      transport: transport,
      handlers: NwcHandlers(cln: FakeCln()),
      config: config,
    );
    await service.start();
  });

  tearDown(() async {
    await service.stop();
  });

  NostrEvent buildRequest({
    required String method,
    Map<String, dynamic> params = const {},
    String? signWith,
    String? contentOverride,
  }) {
    final priv = signWith ?? clientPriv;
    final pub = NostrCrypto.derivePublicKey(priv);
    final payload = jsonEncode({
      'method': method,
      if (params.isNotEmpty) 'params': params,
    });
    final encrypted = NostrCrypto.nip04Encrypt(
      privkeyHex: priv,
      pubkeyHex: service.publicKey,
      plaintext: payload,
    );
    return NostrEvent.unsigned(
      pubkey: pub,
      kind: Protocol.nwcRequestKind,
      tags: [
        ['p', service.publicKey],
      ],
      content: contentOverride ?? encrypted,
    ).sign(priv);
  }

  test('risponde a get_balance cifrato e correlato (e/p tag)', () async {
    final request = buildRequest(method: 'get_balance');
    transport.inject(request);

    await _waitFor(
      () => transport.published.any(
        (e) => e.kind == Protocol.nwcResponseKind,
      ),
    );
    final reply = transport.published.firstWhere(
      (e) => e.kind == Protocol.nwcResponseKind,
    );

    expect(reply.pubkey, service.publicKey);
    expect(reply.firstTagValue('e'), request.id);
    expect(reply.firstTagValue('p'), clientPub);
    expect(reply.verify(), isTrue);

    final decrypted = NostrCrypto.nip04Decrypt(
      privkeyHex: clientPriv,
      pubkeyHex: reply.pubkey,
      payload: reply.content,
    );
    final body = (jsonDecode(decrypted) as Map).cast<String, dynamic>();
    expect(body['error'], isNull);
    expect((body['result'] as Map)['balance'], 5000000);
  });

  test('risponde con errore per metodo non supportato', () async {
    final request = buildRequest(method: 'frobnicate');
    transport.inject(request);
    await _waitFor(
      () => transport.published.any(
        (e) => e.kind == Protocol.nwcResponseKind,
      ),
    );
    final reply = transport.published.firstWhere(
      (e) => e.kind == Protocol.nwcResponseKind,
    );
    final decrypted = NostrCrypto.nip04Decrypt(
      privkeyHex: clientPriv,
      pubkeyHex: reply.pubkey,
      payload: reply.content,
    );
    final body = (jsonDecode(decrypted) as Map).cast<String, dynamic>();
    expect((body['error'] as Map)['code'], 'NOT_IMPLEMENTED');
  });

  test('ignora richieste da client non autorizzato', () async {
    final otherPriv = NostrCrypto.randomHex32();
    final request = buildRequest(method: 'get_balance', signWith: otherPriv);
    transport.inject(request);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(
      transport.published.any((e) => e.kind == Protocol.nwcResponseKind),
      isFalse,
    );
  });

  test('ignora richieste con firma non valida', () async {
    final request = buildRequest(method: 'get_balance');
    // Firma sostituita con quella di un'altra chiave: verify() fallisce.
    final forged = NostrEvent(
      id: request.id,
      pubkey: request.pubkey,
      createdAt: request.createdAt,
      kind: request.kind,
      tags: request.tags,
      content: request.content,
      sig: NostrEvent.unsigned(
        pubkey: clientPub,
        kind: 1,
        content: 'x',
      ).sign(NostrCrypto.randomHex32()).sig,
    );
    transport.inject(forged);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(
      transport.published.any((e) => e.kind == Protocol.nwcResponseKind),
      isFalse,
    );
  });

  test('pubblica gli eventi info NWC/NCC all\'avvio', () {
    expect(
      transport.published.any((e) => e.kind == Protocol.infoKindNwc),
      isTrue,
    );
    expect(
      transport.published.any((e) => e.kind == Protocol.infoKindNcc),
      isTrue,
    );
  });

  test('ensureConnected riconnette dopo una caduta del relay', () async {
    transport.isConnected = false;
    await service.ensureConnected();
    expect(transport.isConnected, isTrue);

    // Dopo la riconnessione (con nuova subscribe) le richieste funzionano.
    final request = buildRequest(method: 'get_balance');
    transport.inject(request);
    await _waitFor(
      () => transport.published.any(
        (e) => e.kind == Protocol.nwcResponseKind,
      ),
    );
    final reply = transport.published.firstWhere(
      (e) => e.kind == Protocol.nwcResponseKind,
    );
    expect(reply.firstTagValue('e'), request.id);
  });

  test('socket troppo vecchio → riciclo preventivo ("zombie" NAT)', () async {
    // Il service del setUp ha già fatto la sua connessione su transport.
    final before = transport.connectCalls;
    final fresh = BridgeService(
      transport: transport,
      handlers: NwcHandlers(cln: FakeCln()),
      config: config,
      maxSocketAge: const Duration(milliseconds: 20),
    );
    await fresh.start();
    expect(transport.connectCalls, before + 1);

    // Il transport risultà isConnected=true ma il socket ha superato l'età
    // massima: ensureConnected deve sostituirlo PRIMA che si riveli sordo.
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await fresh.ensureConnected();
    expect(transport.connectCalls, before + 2);

    await fresh.stop();
  });

  test('notifiche disattivate con notifyPollSeconds=0', () async {
    final cfg = BridgeConfig(
      relay: 'wss://relay.test',
      privkeyHex: bridgePriv,
      clnUrl: 'http://127.0.0.1:3001',
      allowedClientPubkeys: [clientPub],
      notifyPollSeconds: 0,
    );
    final svc = BridgeService(
      transport: transport,
      handlers: NwcHandlers(cln: FakeCln()),
      config: cfg,
    );
    await svc.start();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(
      transport.published.any((e) => e.kind == Protocol.nwcNotificationKind),
      isFalse,
    );
    await svc.stop();
  });

  test('poll notifiche: payment_received pubblicato e decifrabile', () async {
    final cln = FakeCln();
    // Il primo giro "innesca" con uno storico già pagato: nessuna notifica.
    cln.invoices = {
      'invoices': [
        {
          'payment_hash': 'h1',
          'status': 'paid',
          'amount_received_msat': 1000000,
        },
      ],
    };
    final cfg = BridgeConfig(
      relay: 'wss://relay.test',
      privkeyHex: bridgePriv,
      clnUrl: 'http://127.0.0.1:3001',
      allowedClientPubkeys: [clientPub],
      notifyPollSeconds: 1,
    );
    final svc = BridgeService(
      transport: transport,
      handlers: NwcHandlers(cln: cln),
      config: cfg,
    );
    await svc.start();
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(
      transport.published.any((e) => e.kind == Protocol.nwcNotificationKind),
      isFalse,
    );

    // Nuovo pagamento → notifica cifrata al client autorizzato.
    cln.invoices = {
      'invoices': [
        {'payment_hash': 'h1', 'status': 'paid'},
        {
          'payment_hash': 'h2',
          'status': 'paid',
          'amount_received_msat': 2000000,
        },
      ],
    };
    await _waitFor(
      () => transport.published.any(
        (e) => e.kind == Protocol.nwcNotificationKind,
      ),
      timeout: const Duration(seconds: 4),
    );
    final event = transport.published.firstWhere(
      (e) => e.kind == Protocol.nwcNotificationKind,
    );
    expect(event.firstTagValue('p'), clientPub);
    expect(event.verify(), isTrue);

    final decrypted = NostrCrypto.nip04Decrypt(
      privkeyHex: clientPriv,
      pubkeyHex: event.pubkey,
      payload: event.content,
    );
    final body = (jsonDecode(decrypted) as Map).cast<String, dynamic>();
    expect(body['notification_type'], 'payment_received');
    expect((body['notification'] as Map)['payment_hash'], 'h2');
    await svc.stop();
  });
}
