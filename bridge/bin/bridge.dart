import 'dart:async';
import 'dart:io';

import 'package:nwc_cln_bridge/src/bridge_service.dart';
import 'package:nwc_cln_bridge/src/cln/cln_api.dart';
import 'package:nwc_cln_bridge/src/config.dart';
import 'package:nwc_cln_bridge/src/handlers.dart';
import 'package:nwc_cln_bridge/src/logger.dart';
import 'package:nwc_cln_bridge/src/nostr/nostr_crypto.dart';
import 'package:nwc_cln_bridge/src/nostr/websocket_transport.dart';

/// Entrypoint del bridge NWC/NCC ↔ CLN.
///
/// Uso:
///   dart run bin/bridge.dart --genkey
///       → stampa una nuova privkey Nostr (da mettere in config.json)
///   dart run bin/bridge.dart --genuri [--config=config.json]
///       → genera secret client + URI da incollare nell'app e salva
///         la pubkey del client nell'allowlist della config
///   dart run bin/bridge.dart [--config=config.json]
///       → avvia il servizio (ascolta il relay)
Future<void> main(List<String> args) async {
  final opts = _parseArgs(args);
  final configPath = opts['config'] ?? 'config.json';

  if (opts.containsKey('genkey')) {
    stdout.writeln(NostrCrypto.randomHex32());
    return;
  }

  final config = BridgeConfig.fromJsonFile(configPath);

  if (opts.containsKey('genuri')) {
    // PERCHÉ: la secret è la chiave privata di sessione DEL CLIENT (NIP-47);
    // il bridge ne registra la pubkey per autorizzare solo quell'app.
    final secret = NostrCrypto.randomHex32();
    final clientPub = NostrCrypto.derivePublicKey(secret);
    if (!config.allowedClientPubkeys.contains(clientPub)) {
      config.allowedClientPubkeys.add(clientPub);
      config.saveToFile(configPath);
    }
    final bridgePub = NostrCrypto.derivePublicKey(config.privkeyHex);
    final relay = Uri.encodeComponent(config.relay);
    final uri = 'nostr+walletconnect://$bridgePub?relay=$relay&secret=$secret';
    stdout.writeln('URI NWC/NCC da incollare nell\'app:');
    stdout.writeln(uri);
    stdout.writeln('');
    stdout.writeln('Client pubkey autorizzata: $clientPub');
    stdout.writeln('(salvata in $configPath)');
    return;
  }

  final logger = Logger(
    minLevel: LogLevel.values.firstWhere(
      (l) => l.name == config.logLevel,
      orElse: () => LogLevel.info,
    ),
  );

  final rune = config.loadRune();
  final cln = ClnRestClient(
    baseUrl: config.clnUrl,
    rune: rune,
    logger: logger,
  );
  final transport = WebSocketTransport(logger: logger);
  final service = BridgeService(
    transport: transport,
    handlers: NwcHandlers(cln: cln, logger: logger),
    config: config,
    logger: logger,
  );

  await service.start();

  ProcessSignal.sigint.watch().listen((_) async {
    logger.info('arresto richiesto (SIGINT)');
    await service.stop();
    exit(0);
  });
  ProcessSignal.sigterm.watch().listen((_) async {
    logger.info('arresto richiesto (SIGTERM)');
    await service.stop();
    exit(0);
  });

  // Resta viva: il servizio lavora tramite gli stream del transport.
  await Completer<void>().future;
}

Map<String, String> _parseArgs(List<String> args) {
  final out = <String, String>{};
  for (final a in args) {
    if (!a.startsWith('--')) {
      continue;
    }
    final eq = a.indexOf('=');
    if (eq < 0) {
      out[a.substring(2)] = '';
    } else {
      out[a.substring(2, eq)] = a.substring(eq + 1);
    }
  }
  return out;
}
