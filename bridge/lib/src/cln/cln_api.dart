import 'dart:convert';

import 'package:http/http.dart' as http;

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
    http.Client? httpClient,
    Logger? logger,
  })  : _rune = rune,
        _http = httpClient ?? http.Client(),
        _logger = logger ?? Logger();

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
    // // PERCHÉ: clnrest risponde 201 (Created) sui comandi riusciti —
    // accettiamo tutta la famiglia 2xx.
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw RpcError('OTHER', 'CLN HTTP ${res.statusCode} su $method');
    }
    return body;
  }
}
