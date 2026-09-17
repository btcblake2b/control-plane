import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../config.dart';
import '../logger.dart';
import '../protocol.dart';

/// Astrazione minima del nodo CLN — iniettabile nei test.
abstract class ClnApi {
  /// Esegue il comando [method] con [params] e ritorna il JSON del risultato.
  /// Lancia [RpcError] su errore del nodo o di trasporto.
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]);
}

/// Client per CLNRest (plugin clnrest di Core Lightning).
///
/// // PERCHÉ: clnrest è già attivo sul nodo blake2b (porta 3001, rune dedicata
/// — vedi setup RTL): POST su `/v1/<method>` con header `rune` e body dei
/// parametri. Zero dipendenze dal socket RPC locale: il bridge può girare
/// ovunque.
class ClnRestClient implements ClnApi {
  ClnRestClient({
    required this.baseUrl,
    required String rune,
    SecurityContext? securityContext,
    bool tlsInsecure = false,
    http.Client? httpClient,
    Logger? logger,
  })  : _rune = rune,
        _http = httpClient ??
            _buildClient(
              securityContext: securityContext,
              insecure: tlsInsecure,
            ),
        _logger = logger ?? Logger();

  /// Costruisce il client HTTP applicando TLS solo quando serve.
  /// // PERCHÉ: clnrest è http in locale (server di sviluppo, Start9) e https
  /// con certificati self-signed altrove (app Umbrel): il trasporto va scelto
  /// dalla configurazione, non hardcoded.
  static http.Client _buildClient({
    SecurityContext? securityContext,
    required bool insecure,
  }) {
    if (securityContext == null && !insecure) {
      return http.Client();
    }
    final ctx = securityContext ?? SecurityContext();
    final client = HttpClient(context: ctx);
    if (insecure) {
      // // PERCHÉ: il certificato di clnrest è generato per l'IP/host interno
      // e può non avere un SAN valido per il nome usato dal client.
      client.badCertificateCallback = (cert, host, port) => true;
    }
    return IOClient(client);
  }

  /// Client costruito dalla config (url + rune + PEM opzionali).
  ///
  /// // PERCHÉ: un unico punto di costruzione evita che CLI, pagina di stato e
  /// health check usino trasporti diversi.
  static ClnRestClient fromConfig(
    BridgeConfig config, {
    http.Client? httpClient,
    Logger? logger,
  }) {
    SecurityContext? ctx;
    final ca = config.clnCaFile;
    if (ca != null && ca.isNotEmpty && File(ca).existsSync()) {
      ctx = SecurityContext()..setTrustedCertificates(ca);
      final cert = config.clnClientCertFile;
      final key = config.clnClientKeyFile;
      // // PERCHÉ: se il nodo richiede mTLS i due PEM sono obbligatori
      // insieme: uno solo dei due indica una configurazione incompleta.
      if (cert != null && key != null) {
        ctx.useCertificateChain(cert);
        ctx.usePrivateKey(key);
      }
    } else if (config.usesTls) {
      logger?.warn(
        'clnUrl in https senza clnCaFile: il certificato del nodo deve essere '
        'firmato da una CA di sistema',
      );
    }
    return ClnRestClient(
      baseUrl: config.clnUrl,
      rune: config.loadRune(),
      securityContext: ctx,
      tlsInsecure: config.clnTlsInsecure,
      httpClient: httpClient,
      logger: logger,
    );
  }

  final String baseUrl;
  final String _rune;
  final http.Client _http;
  final Logger _logger;

  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    final uri = Uri.parse('$baseUrl/v1/$method');
    http.Response res;
    try {
      res = await _http.post(
        uri,
        headers: {
          'rune': _rune,
          'Content-Type': 'application/json',
        },
        body: jsonEncode(params),
      );
    } catch (e) {
      throw RpcError('OTHER', 'CLN non raggiungibile: $e');
    }

    // 401/403: rune mancante o non autorizzata → permesso negato per il client.
    // // PERCHÉ prima del parse: con 401 il body può essere vuoto/non JSON.
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw const RpcError('RESTRICTED', 'Rune non autorizzata o assente');
    }

    Map<String, dynamic> body;
    try {
      body = (jsonDecode(res.body) as Map).cast<String, dynamic>();
    } catch (_) {
      throw RpcError(
        'OTHER',
        'Risposta CLN non valida (HTTP ${res.statusCode})',
      );
    }

    // clnrest incapsula gli errori RPC in {"error": {...}}.
    final err = body['error'];
    if (err is Map) {
      final msg = '${err['message'] ?? 'errore dal nodo'}';
      _logger.warn('CLN $method → errore: $msg');
      throw RpcError('OTHER', msg);
    }
    // PERCHÉ (I3e): su alcuni errori (es. getroute → code 205 "Could not find a
    // route") clnrest risponde HTTP 500 con l'errore CLN in chiaro — `code` e
    // `message` al livello superiore, senza wrapper `error`. Senza questo ramo
    // l'app vedrebbe solo "CLN HTTP 500" e non il motivo reale.
    final rawCode = body['code'];
    final rawMessage = body['message'];
    if (res.statusCode >= 400 && rawCode is num && rawMessage != null) {
      _logger.warn('CLN $method → errore nodo $rawCode: $rawMessage');
      throw RpcError('OTHER', '$rawMessage');
    }
    // // PERCHÉ: clnrest risponde 201 (Created) sui comandi riusciti —
    // accettiamo tutta la famiglia 2xx.
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw RpcError('OTHER', 'CLN HTTP ${res.statusCode} su $method');
    }
    return body;
  }
}
