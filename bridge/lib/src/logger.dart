import 'dart:io';

/// Livelli di log del bridge (ordine crescente di severità).
enum LogLevel { debug, info, warn, error }

/// Logger minimale con timestamp ISO e prefisso `[Bridge]`.
///
/// // PERCHÉ: il bridge gira headless sul server — stdout catturato da
/// nohup/systemd. Nota di sicurezza: NON loggare MAI content di eventi,
/// plaintext decifrati, rune o chiavi private.
class Logger {
  Logger({this.minLevel = LogLevel.info});

  final LogLevel minLevel;

  void debug(String msg) => _log(LogLevel.debug, msg);
  void info(String msg) => _log(LogLevel.info, msg);
  void warn(String msg) => _log(LogLevel.warn, msg);
  void error(String msg) => _log(LogLevel.error, msg);

  void _log(LogLevel level, String msg) {
    if (level.index < minLevel.index) {
      return;
    }
    final ts = DateTime.now().toUtc().toIso8601String();
    stdout.writeln('$ts [${level.name.toUpperCase()}] [Bridge] $msg');
  }
}
