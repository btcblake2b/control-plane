import 'dart:convert';
import 'dart:io';

enum LogLevel { debug, info, warn, error }

/// Logger strutturato: una riga JSON per evento su stdout.
///
/// // PERCHÉ (sicurezza): i log del control plane non devono MAI contenere
/// token, node_secret, body delle richieste o header Authorization.
/// Chi logga passa solo identificatori (nodeId, ip, esito).
class Log {
  Log({this.minLevel = LogLevel.info, IOSink? sink}) : _sink = sink ?? stdout;

  /// Logger muto, per i test.
  Log.silent()
      : minLevel = LogLevel.error,
        _sink = null;

  final LogLevel minLevel;
  final IOSink? _sink;

  void debug(String msg, [Map<String, Object?> fields = const {}]) =>
      _write(LogLevel.debug, msg, fields);

  void info(String msg, [Map<String, Object?> fields = const {}]) =>
      _write(LogLevel.info, msg, fields);

  void warn(String msg, [Map<String, Object?> fields = const {}]) =>
      _write(LogLevel.warn, msg, fields);

  void error(String msg, [Map<String, Object?> fields = const {}]) =>
      _write(LogLevel.error, msg, fields);

  void _write(LogLevel level, String msg, Map<String, Object?> fields) {
    final sink = _sink;
    if (sink == null || level.index < minLevel.index) return;
    final line = jsonEncode({
      'ts': DateTime.now().toUtc().toIso8601String(),
      'level': level.name,
      'msg': msg,
      ...fields,
    });
    sink.writeln(line);
  }
}
