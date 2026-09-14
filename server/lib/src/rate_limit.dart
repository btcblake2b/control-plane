import 'dart:math';

/// Token bucket in-memory per chiave (IP client).
///
/// // PERCHÉ: i token/secret del CP sono da 256 bit — il brute-force non è un
/// rischio realistico. Il rate-limit protegge da abusi grossolani (flood,
/// spam di registrazioni), non è un controllo di sicurezza critico: per
/// questo è accettabile che sia in-memory e si azzeri al riavvio.
class RateLimiter {
  RateLimiter({required this.capacity, required this.refillPerSecond})
      : assert(capacity > 0),
        assert(refillPerSecond >= 0);

  /// Massimo numero di richieste "a secchio pieno".
  final double capacity;

  /// Token rigenerati al secondo.
  final double refillPerSecond;

  final Map<String, _Bucket> _buckets = {};

  /// True se la richiesta è consentita; false → rispondere 429.
  bool allow(String key, {DateTime? now}) {
    final t = now ?? DateTime.now();
    final bucket =
        _buckets.putIfAbsent(key, () => _Bucket(tokens: capacity, last: t));
    final elapsedSeconds = t.difference(bucket.last).inMilliseconds / 1000.0;
    bucket.tokens = min(capacity, bucket.tokens + elapsedSeconds * refillPerSecond);
    bucket.last = t;
    if (bucket.tokens >= 1) {
      bucket.tokens -= 1;
      return true;
    }
    return false;
  }

  /// Secondi da attendere prima che torni disponibile un token (Retry-After).
  int retryAfterSeconds(String key, {DateTime? now}) {
    final bucket = _buckets[key];
    if (bucket == null || bucket.tokens >= 1) return 0;
    if (refillPerSecond <= 0) return 3600;
    return ((1 - bucket.tokens) / refillPerSecond).ceil();
  }

  /// Rimuove i bucket inattivi (evita crescita illimitata della mappa).
  void cleanup({DateTime? now}) {
    final t = now ?? DateTime.now();
    _buckets.removeWhere((_, b) => t.difference(b.last).inMinutes > 10);
  }

  /// Registrazione: 20 di burst, 10/ora di refill (protegge i token da scan massivi).
  static RateLimiter registerLimiter() =>
      RateLimiter(capacity: 20, refillPerSecond: 10 / 3600);

  /// Endpoint generali (GET/DELETE/rotate): 120 di burst, 60/min.
  static RateLimiter generalLimiter() =>
      RateLimiter(capacity: 120, refillPerSecond: 1);
}

class _Bucket {
  _Bucket({required this.tokens, required this.last});

  double tokens;
  DateTime last;
}
