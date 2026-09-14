import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:tlw_control_plane/src/api.dart';
import 'package:tlw_control_plane/src/config.dart';
import 'package:tlw_control_plane/src/db.dart';
import 'package:tlw_control_plane/src/logging.dart';
import 'package:tlw_control_plane/src/rate_limit.dart';

/// Entry point del control plane.
///
/// Config via variabili d'ambiente: TLW_CP_BIND, TLW_CP_PORT, TLW_CP_DB,
/// TLW_CP_TRUST_PROXY, TLW_CP_TOKEN_TTL_HOURS (vedi docs/CONTROL_PLANE.md).
Future<void> main(List<String> args) async {
  final config = ServerConfig.current();
  final log = Log();
  final db = Db.open(config.dbPath);

  final registerLimiter = RateLimiter.registerLimiter();
  final generalLimiter = RateLimiter.generalLimiter();
  final handler = buildHandler(
    db: db,
    config: config,
    log: log,
    registerLimiter: registerLimiter,
    generalLimiter: generalLimiter,
  );

  final server = await shelf_io.serve(handler, config.bind, config.port);
  log.info('control plane in ascolto', {
    'bind': config.bind,
    'port': server.port,
    'db': config.dbPath,
    'trustProxy': config.trustProxy,
  });

  // PERCHÉ: cleanup periodico dei bucket — la mappa delle IP non deve
  // crescere senza limite su un servizio long-running.
  final cleanupTimer = Timer.periodic(const Duration(minutes: 10), (_) {
    registerLimiter.cleanup();
    generalLimiter.cleanup();
  });

  Future<void> shutdown(ProcessSignal signal) async {
    log.info('shutdown', {'signal': signal.toString()});
    cleanupTimer.cancel();
    await server.close(force: false);
    db.close();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen((signal) {
    unawaited(shutdown(signal));
  });
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((signal) {
      unawaited(shutdown(signal));
    });
  }
}
