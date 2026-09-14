import 'dart:io';

/// Configurazione del control plane, letta dalle variabili d'ambiente.
class ServerConfig {
  const ServerConfig({
    required this.bind,
    required this.port,
    required this.dbPath,
    required this.trustProxy,
    required this.tokenTtl,
  });

  /// Indirizzo di ascolto (default: solo loopback, dietro reverse proxy).
  final String bind;

  final int port;

  /// Percorso del file SQLite.
  final String dbPath;

  /// // PERCHÉ: X-Forwarded-For è falsificabile; default false (si usa l'IP
  /// del socket). Va messo a true SOLO dietro un reverse proxy che sovrascrive
  /// l'header (Caddy/nginx) — vedi docs/CONTROL_PLANE.md.
  final bool trustProxy;

  /// Scadenza dei token di registrazione.
  final Duration tokenTtl;

  static const String defaultBind = '127.0.0.1';
  static const int defaultPort = 8787;
  static const String defaultDbPath = 'data/control.db';
  static const int defaultTokenTtlHours = 24;

  factory ServerConfig.fromEnv(Map<String, String> env) {
    final port = int.tryParse(env['TLW_CP_PORT'] ?? '') ?? defaultPort;
    final ttlHours =
        int.tryParse(env['TLW_CP_TOKEN_TTL_HOURS'] ?? '') ?? defaultTokenTtlHours;
    return ServerConfig(
      bind: env['TLW_CP_BIND'] ?? defaultBind,
      port: port,
      dbPath: env['TLW_CP_DB'] ?? defaultDbPath,
      trustProxy: _isTrue(env['TLW_CP_TRUST_PROXY']),
      tokenTtl: Duration(hours: ttlHours),
    );
  }

  factory ServerConfig.current() => ServerConfig.fromEnv(Platform.environment);

  static bool _isTrue(String? value) {
    final v = (value ?? '').toLowerCase();
    return v == '1' || v == 'true' || v == 'yes';
  }
}
