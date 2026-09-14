import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'auth.dart';
import 'config.dart';
import 'db.dart';
import 'logging.dart';
import 'models.dart';
import 'rate_limit.dart';

/// Errore applicativo: risposto come {"error":{"code","message"}}.
class ApiException implements Exception {
  const ApiException(this.status, this.code, this.message,
      {this.retryAfterSeconds});

  final int status;
  final String code;
  final String message;

  /// Se valorizzato, aggiunge l'header Retry-After (429).
  final int? retryAfterSeconds;
}

/// Costruisce il handler HTTP del control plane.
///
/// [registerLimiter] e [generalLimiter] sono iniettabili per i test.
Handler buildHandler({
  required Db db,
  required ServerConfig config,
  required Log log,
  RateLimiter? registerLimiter,
  RateLimiter? generalLimiter,
}) {
  final api = _Api(
    db: db,
    config: config,
    log: log,
    registerLimiter: registerLimiter ?? RateLimiter.registerLimiter(),
    generalLimiter: generalLimiter ?? RateLimiter.generalLimiter(),
  );
  final router = Router()
    ..post('/v1/register', api.register)
    ..get('/v1/nodes/<id>', api.getNode)
    ..delete('/v1/nodes/<id>', api.deleteNode)
    ..post('/v1/nodes/<id>/rotate-secret', api.rotateSecret)
    ..all('/<ignored|.*>', api.notFound);
  return const Pipeline()
      .addMiddleware(_errorMiddleware(log))
      .addHandler(router.call);
}

class _Api {
  _Api({
    required this.db,
    required this.config,
    required this.log,
    required this.registerLimiter,
    required this.generalLimiter,
  });

  final Db db;
  final ServerConfig config;
  final Log log;
  final RateLimiter registerLimiter;
  final RateLimiter generalLimiter;

  // FLOW: Registrazione nodo (installer → control plane)
  // STEP: 1
  Future<Response> register(Request req) async {
    _enforceRate(registerLimiter, req);
    final body = await _readJsonBody(req);

    // STEP: 2 — validazione token (monouso, scadenza, già usato)
    final tokenHex = _requireString(body, 'token', maxLength: 64).toLowerCase();
    if (!AuthService.isHex64(tokenHex)) {
      throw const ApiException(401, 'INVALID_TOKEN', 'token non valido');
    }
    final token = db.findTokenByHash(AuthService.sha256Hex(tokenHex));
    if (token == null) {
      // PERCHÉ messaggio identico al formato invalido: nessuna enumerazione.
      throw const ApiException(401, 'INVALID_TOKEN', 'token non valido');
    }
    if (token.isUsed) {
      throw const ApiException(410, 'TOKEN_USED', 'token già utilizzato');
    }
    final now = DateTime.now().toUtc();
    if (token.isExpired(now)) {
      throw const ApiException(410, 'TOKEN_EXPIRED', 'token scaduto');
    }

    // STEP: 3 — validazione payload (dati pseudonimi)
    final pubkey =
        _requireString(body, 'bridgePubkey', maxLength: 64).toLowerCase();
    if (!AuthService.isHex64(pubkey)) {
      throw const ApiException(
          400, 'INVALID_REQUEST', 'bridgePubkey non valida (attesa hex 64)');
    }
    final relay = _requireString(body, 'relay', maxLength: 256);
    if (!relay.startsWith('wss://') && !relay.startsWith('ws://')) {
      throw const ApiException(
          400, 'INVALID_REQUEST', 'relay non valido (atteso wss://)');
    }
    final version = _requireString(body, 'version', maxLength: 32);
    String? alias;
    final rawAlias = body['alias'];
    if (rawAlias != null) {
      if (rawAlias is! String || rawAlias.length > 64) {
        throw const ApiException(
            400, 'INVALID_REQUEST', 'alias non valido (max 64 caratteri)');
      }
      alias = rawAlias.isEmpty ? null : rawAlias;
    }

    // PERCHÉ: la pubkey è l'identità del nodo — niente doppie registrazioni.
    // In caso di conflitto il token NON viene consumato: l'utente può
    // riprovare dopo il recovery (admin node delete).
    if (db.pubkeyExists(pubkey)) {
      throw const ApiException(409, 'ALREADY_REGISTERED',
          "nodo già registrato: contatta l'operatore per il recovery");
    }

    // STEP: 4 — registrazione atomica + emissione node_secret (una sola volta)
    final nodeId = AuthService.randomHex16();
    final nodeSecret = AuthService.randomHex32();
    final node = NodeRecord(
      id: nodeId,
      bridgePubkey: pubkey,
      relay: relay,
      alias: alias,
      version: version,
      createdAt: now,
    );
    db.registerNode(
      node: node,
      secretSha256: AuthService.sha256Hex(nodeSecret),
      tokenId: token.id,
    );
    log.info('node registered', {'nodeId': nodeId});
    return _json(201, {
      'nodeId': nodeId,
      'nodeSecret': nodeSecret,
      'createdAt': now.toIso8601String(),
    });
  }

  Future<Response> getNode(Request req, String id) async {
    _enforceRate(generalLimiter, req);
    final node = _requireNode(id);
    _verifyNodeSecret(req, node);
    return _json(200, node.toApiJson());
  }

  Future<Response> deleteNode(Request req, String id) async {
    _enforceRate(generalLimiter, req);
    final node = _requireNode(id);
    _verifyNodeSecret(req, node);
    db.deleteNode(node.id);
    log.info('node deleted', {'nodeId': node.id});
    return Response(204);
  }

  Future<Response> rotateSecret(Request req, String id) async {
    _enforceRate(generalLimiter, req);
    final node = _requireNode(id);
    _verifyNodeSecret(req, node);
    final fresh = AuthService.randomHex32();
    db.rotateSecret(
      node.id,
      secretSha256: AuthService.sha256Hex(fresh),
      rotatedAt: DateTime.now().toUtc(),
    );
    log.info('node secret rotated', {'nodeId': node.id});
    return _json(200, {'nodeSecret': fresh});
  }

  Future<Response> notFound(Request req) async => _json(404, {
        'error': {'code': 'NOT_FOUND', 'message': 'risorsa non trovata'},
      });

  // ── Internals ──────────────────────────────────────────────────────────────

  void _enforceRate(RateLimiter limiter, Request req) {
    final ip = _clientIp(req, config.trustProxy);
    if (!limiter.allow(ip)) {
      final retry = limiter.retryAfterSeconds(ip);
      throw ApiException(
        429,
        'RATE_LIMITED',
        'troppi tentativi, riprova più tardi',
        retryAfterSeconds: retry > 0 ? retry : 60,
      );
    }
  }

  NodeRecord _requireNode(String id) {
    final node = AuthService.isHex32(id) ? db.findNode(id.toLowerCase()) : null;
    if (node == null) {
      throw const ApiException(404, 'NOT_FOUND', 'nodo non trovato');
    }
    return node;
  }

  void _verifyNodeSecret(Request req, NodeRecord node) {
    final bearer = _requireBearer(req);
    if (!AuthService.isHex64(bearer)) {
      throw const ApiException(401, 'UNAUTHORIZED', 'credenziale non valida');
    }
    final sha = AuthService.sha256Hex(bearer.toLowerCase());
    if (!AuthService.constantTimeEquals(sha, node.secretSha256)) {
      throw const ApiException(401, 'UNAUTHORIZED', 'credenziale non valida');
    }
  }

  String _requireBearer(Request req) {
    final header = req.headers['authorization'];
    if (header == null || !header.startsWith('Bearer ')) {
      throw const ApiException(401, 'UNAUTHORIZED', 'credenziale mancante');
    }
    return header.substring('Bearer '.length).trim();
  }

  Future<Map<String, dynamic>> _readJsonBody(Request req) async {
    const maxBytes = 8 * 1024;
    final declared = req.contentLength;
    if (declared != null && declared > maxBytes) {
      throw const ApiException(
          400, 'INVALID_REQUEST', 'body troppo grande (max 8KB)');
    }
    final body = await req.readAsString();
    if (body.length > maxBytes) {
      throw const ApiException(
          400, 'INVALID_REQUEST', 'body troppo grande (max 8KB)');
    }
    if (body.trim().isEmpty) {
      throw const ApiException(400, 'INVALID_REQUEST', 'body mancante');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const ApiException(
          400, 'INVALID_REQUEST', 'body non è JSON valido');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const ApiException(
          400, 'INVALID_REQUEST', 'body deve essere un oggetto JSON');
    }
    return decoded;
  }

  static String _requireString(Map<String, dynamic> body, String key,
      {required int maxLength}) {
    final value = body[key];
    if (value is! String || value.isEmpty || value.length > maxLength) {
      throw ApiException(
          400, 'INVALID_REQUEST', 'campo "$key" mancante o non valido');
    }
    return value;
  }
}

String _clientIp(Request req, bool trustProxy) {
  // PERCHÉ: X-Forwarded-For è spoofabile — si usa SOLO se trustProxy=1
  // (dietro un reverse proxy che riscrive l'header). Vedi docs/CONTROL_PLANE.md.
  if (trustProxy) {
    final xff = req.headers['x-forwarded-for'];
    if (xff != null && xff.trim().isNotEmpty) {
      final first = xff.split(',').first.trim();
      if (first.isNotEmpty) return first;
    }
  }
  final connection = req.context['shelf.io.connection_info'];
  if (connection is HttpConnectionInfo) {
    return connection.remoteAddress.address;
  }
  return 'unknown';
}

Middleware _errorMiddleware(Log log) => (Handler inner) => (Request req) async {
      try {
        return await inner(req);
      } on ApiException catch (e) {
        return _json(
          e.status,
          {
            'error': {'code': e.code, 'message': e.message}
          },
          headers: e.retryAfterSeconds != null
              ? {'retry-after': '${e.retryAfterSeconds}'}
              : const {},
        );
      } catch (e, stack) {
        // PERCHÉ: log completo lato server, risposta generica lato client
        // (nessuna informazione interna trapela).
        log.error('errore interno', {
          'error': e.toString(),
          'where': stack.toString().split('\n').first,
        });
        return _json(500, {
          'error': {'code': 'INTERNAL', 'message': 'errore interno'}
        });
      }
    };

Response _json(int status, Map<String, Object?> body,
        {Map<String, String> headers = const {}}) =>
    Response(
      status,
      body: jsonEncode(body),
      headers: {'content-type': 'application/json; charset=utf-8', ...headers},
    );
