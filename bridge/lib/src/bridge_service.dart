import 'dart:async';
import 'dart:convert';

import 'config.dart';
import 'handlers.dart';
import 'logger.dart';
import 'nostr/nostr_crypto.dart';
import 'nostr/nostr_event.dart';
import 'nostr/nostr_transport.dart';
import 'protocol.dart';

/// Servizio principale del bridge: ascolta le richieste NWC/NCC dal relay,
/// le esegue sul nodo CLN e risponde cifrato (NIP-04).
///
/// // FLOW: Lightning via nodo remoto (NWC/NCC)
/// App → relay Nostr → Bridge → CLNRest → nodo CLN (blake2b)
/// La risposta ripercorre il cammino inverso, cifrata e firmata dal bridge.
class BridgeService {
  BridgeService({
    required this.transport,
    required this.handlers,
    required this.config,
    Logger? logger,
    this.maxSocketAge = const Duration(minutes: 10),
  }) : _logger = logger ?? Logger();

  final NostrTransport transport;
  final NwcHandlers handlers;
  final BridgeConfig config;
  final Logger _logger;

  /// Età massima della connessione al relay prima del riciclo preventivo.
  ///
  /// // PERCHÉ: un socket "zombie" (la NAT/router chiude il TCP inattivo
  /// senza che arrivi un FIN) resta `isConnected=true` ma non riceve più
  /// nulla: riciclare la connessione a intervalli garantiti evita che il
  /// bridge resti "sordo" a lungo senza accorgersene.
  final Duration maxSocketAge;

  late final String _pubHex = NostrCrypto.derivePublicKey(config.privkeyHex);

  /// Id evento già processati (i relay possono ripetere gli eventi).
  final Set<String> _processed = <String>{};

  StreamSubscription<NostrEvent>? _sub;
  bool _warnedNoAllowlist = false;
  bool _stopped = false;
  Timer? _healthTimer;

  /// Pubkey Nostr del bridge (= "wallet pubkey" nella URI per l'app).
  String get publicKey => _pubHex;

  Future<void> start() async {
    _stopped = false;
    await _connect();
    _logger.info('in ascolto su ${config.relay}');
    _logger.info('pubkey bridge: $_pubHex');
    await _publishInfoEvents();
    // // PERCHÉ: i relay (e le reti instabili) chiudono le connessioni: senza
    // un health check il bridge smetterebbe di ricevere senza accorgersene.
    _healthTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(ensureConnected()),
    );
  }

  /// Mantiene la connessione viva: riconnette se è caduta e la ricicla se è
  /// più vecchia di [maxSocketAge] (protezione anti-"socket zombie").
  Future<void> ensureConnected() async {
    if (_stopped) {
      return;
    }
    if (transport.isConnected) {
      final since = transport.connectedSince;
      final tooOld =
          since != null && DateTime.now().difference(since) > maxSocketAge;
      if (!tooOld) {
        return;
      }
      // // PERCHÉ: socket vecchio → possibile half-open della NAT: lo
      // sostituisco con uno fresco PRIMA che una richiesta finisca nel vuoto.
      _logger.info(
        'riciclo preventivo: socket attivo da '
        '${DateTime.now().difference(since).inMinutes} min',
      );
    } else {
      _logger.warn('relay disconnesso: riconnessione in corso…');
    }
    try {
      await _sub?.cancel();
      _sub = null;
      await _connect();
      _logger.info('relay riconnesso');
    } catch (e) {
      _logger.warn('riconnessione fallita: $e');
    }
  }

  Future<void> _connect() async {
    await transport.connect(config.relay);
    _sub = transport.subscribe([
      {
        'kinds': [Protocol.nwcRequestKind, Protocol.nccRequestKind],
        '#p': [_pubHex],
      },
    ]).listen(_onEvent);
  }

  Future<void> stop() async {
    _stopped = true;
    _healthTimer?.cancel();
    _healthTimer = null;
    await _sub?.cancel();
    _sub = null;
    await transport.close();
  }

  // ── Internals ───────────────────────────────────────────────────────────────

  Future<void> _publishInfoEvents() async {
    try {
      await _publish(
        Protocol.infoKindNwc,
        Protocol.nwcInfoContent,
        const [],
      );
      await _publish(
        Protocol.infoKindNcc,
        Protocol.nccInfoContent,
        const [],
      );
    } catch (e) {
      _logger.warn('eventi info non pubblicati: $e');
    }
  }

  void _onEvent(NostrEvent event) {
    if (event.kind != Protocol.nwcRequestKind &&
        event.kind != Protocol.nccRequestKind) {
      return;
    }
    // PERCHÉ: dedup — lo stesso evento può arrivare più volte dal relay.
    if (!_processed.add(event.id)) {
      return;
    }
    unawaited(_handle(event));
  }

  Future<void> _handle(NostrEvent event) async {
    // Sicurezza: solo richieste firmate e da client autorizzati.
    if (!event.verify()) {
      _logger.warn('richiesta con firma non valida ignorata (${event.id})');
      return;
    }
    final allowed = config.allowedClientPubkeys;
    if (allowed.isEmpty) {
      // PERCHÉ (fail-safe): senza allowlist NON si accetta nessuno — prima di
      // usare il bridge generare una URI con --genuri.
      if (!_warnedNoAllowlist) {
        _logger.warn(
          'nessun client autorizzato (allowedClientPubkeys vuota): '
          'genera una URI con --genuri',
        );
        _warnedNoAllowlist = true;
      }
      return;
    }
    if (!allowed.contains(event.pubkey)) {
      _logger.warn('client non autorizzato ignorato: ${event.pubkey}');
      return;
    }

    Map<String, dynamic> response;
    try {
      final decrypted = NostrCrypto.nip04Decrypt(
        privkeyHex: config.privkeyHex,
        pubkeyHex: event.pubkey,
        payload: event.content,
      );
      final request = (jsonDecode(decrypted) as Map).cast<String, dynamic>();
      final method = '${request['method'] ?? ''}';
      final params =
          ((request['params'] as Map?) ?? const {}).cast<String, dynamic>();
      _logger.info(
        'richiesta: $method '
        '(client=${event.pubkey.substring(0, 8)}…, id=${event.id})',
      );
      final result = await handlers.handle(method, params);
      response = {
        'result_type': method,
        'result': result,
        'error': null,
      };
    } on RpcError catch (e) {
      _logger.warn('errore: ${e.code} — ${e.message}');
      response = {
        'result_type': null,
        'result': null,
        'error': {'code': e.code, 'message': e.message},
      };
    } catch (e) {
      _logger.error('errore interno: $e');
      response = {
        'result_type': null,
        'result': null,
        'error': {'code': 'OTHER', 'message': '$e'},
      };
    }

    final responseKind = event.kind == Protocol.nwcRequestKind
        ? Protocol.nwcResponseKind
        : Protocol.nccResponseKind;
    try {
      final encrypted = NostrCrypto.nip04Encrypt(
        privkeyHex: config.privkeyHex,
        pubkeyHex: event.pubkey,
        plaintext: jsonEncode(response),
      );
      final reply = NostrEvent.unsigned(
        pubkey: _pubHex,
        kind: responseKind,
        tags: [
          ['e', event.id],
          ['p', event.pubkey],
        ],
        content: encrypted,
      ).sign(config.privkeyHex);
      await transport.publish(reply);
      _logger.info('risposta inviata (req=${event.id}, evt=${reply.id})');
    } catch (e) {
      _logger.error('invio risposta fallito: $e');
    }
  }

  Future<void> _publish(
    int kind,
    String content,
    List<List<String>> tags,
  ) async {
    final event = NostrEvent.unsigned(
      pubkey: _pubHex,
      kind: kind,
      tags: tags,
      content: content,
    ).sign(config.privkeyHex);
    await transport.publish(event);
  }
}
