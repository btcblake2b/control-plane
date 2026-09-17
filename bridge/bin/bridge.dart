import 'dart:async';
import 'dart:io';

import 'package:nwc_cln_bridge/src/bootstrap.dart';
import 'package:nwc_cln_bridge/src/bridge_service.dart';
import 'package:nwc_cln_bridge/src/cln/cln_api.dart';
import 'package:nwc_cln_bridge/src/cln/reloadable_cln.dart';
import 'package:nwc_cln_bridge/src/config.dart';
import 'package:nwc_cln_bridge/src/handlers.dart';
import 'package:nwc_cln_bridge/src/logger.dart';
import 'package:nwc_cln_bridge/src/nostr/nostr_crypto.dart';
import 'package:nwc_cln_bridge/src/nostr/websocket_transport.dart';
import 'package:nwc_cln_bridge/src/web/status_server.dart';

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

  // // PERCHÉ: nei container la config nasce da sola al primo avvio (dagli env)
  // e poi resta nel volume: senza il flag il comportamento è invariato.
  // // PERCHÉ (dal test in container del 16/09): nei package (Umbrel/Start9)
  // non c'è un operatore davanti alla console — un errore di configurazione
  // esce come messaggio chiaro + EX_CONFIG, non come stacktrace.
  BridgeConfig config;
  try {
    config = opts.containsKey('ensure-config')
        ? await ensureConfig(configPath: configPath)
        : BridgeConfig.fromJsonFile(configPath);
  } on FormatException catch (e) {
    _configError(e);
  }

  if (opts.containsKey('health')) {
    // // PERCHÉ: usato come health check del container/package: esce 0 solo se
    // il nodo risponde davvero (rune valida + clnrest raggiungibile).
    exit(await _health(config));
  }

  if (opts.containsKey('genuri')) {
    // PERCHÉ: la secret è la chiave privata di sessione DEL CLIENT (NIP-47);
    // il bridge ne registra la pubkey per autorizzare solo quell'app.
    final uri = await generateClientUri(
      config: config,
      configPath: configPath,
    );
    stdout.writeln('URI NWC/NCC da incollare nell\'app:');
    stdout.writeln(uri);
    return;
  }

  final logger = Logger(
    minLevel: LogLevel.values.firstWhere(
      (l) => l.name == config.logLevel,
      orElse: () => LogLevel.info,
    ),
  );

  // // PERCHÉ: se il nodo è configurato si prova SUBITO a costruire il client e
  // a leggere la rune; se però rune/PEM sono temporaneamente assenti (su StartOS
  // `Revoke Runes` cancella `.commando-env` prima di rigenerarla, e il file può
  // non esistere per qualche secondo) il bridge NON deve morire in crash loop:
  // continua, la pagina di stato segnala lo stato e il client viene ricostruito
  // alla prima richiesta successiva.
  ClnApi? initialCln;
  if (config.clnUrl.isNotEmpty) {
    try {
      initialCln = ClnRestClient.fromConfig(config, logger: logger);
    } catch (e) {
      logger.warn('nodo configurato ma non utilizzabile ora: $e');
      logger.warn('configura il nodo dalla pagina di stato');
    }
  }
  final cln = ReloadableCln(
    config: config,
    initial: initialCln,
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

  // Pagina web di stato/configurazione (richiesta dalle app Umbrel: senza
  // shell l'utente non avrebbe modo di leggere la stringa di connessione).
  final uiPort = int.tryParse(opts['ui-port'] ?? '') ?? config.uiPort;
  final uiToken = opts['ui-token'] ?? config.uiToken;
  StatusServer? ui;
  if (uiPort > 0) {
    ui = StatusServer(
      config: config,
      configPath: configPath,
      service: service,
      cln: cln,
      port: uiPort,
      token: uiToken,
      logger: logger,
    );
    await ui.start();
  }

  ProcessSignal.sigint.watch().listen((_) async {
    logger.info('arresto richiesto (SIGINT)');
    await ui?.stop();
    await service.stop();
    exit(0);
  });
  ProcessSignal.sigterm.watch().listen((_) async {
    logger.info('arresto richiesto (SIGTERM)');
    await ui?.stop();
    await service.stop();
    exit(0);
  });

  // Resta viva: il servizio lavora tramite gli stream del transport.
  await Completer<void>().future;
}

/// Health check per container/package: 0 = nodo raggiungibile.
Future<int> _health(BridgeConfig config) async {
  if (config.clnUrl.isEmpty) {
    stderr.writeln('health FAIL: nodo non configurato');
    return 1;
  }
  try {
    final cln = ClnRestClient.fromConfig(config);
    final info = await cln.call('getinfo');
    stdout.writeln('health OK: network=${info['network'] ?? '?'}');
    return 0;
  } catch (e) {
    stderr.writeln('health FAIL: $e');
    return 1;
  }
}

/// Config assente o invalida (JSON rotto, relay/privkey mancanti): messaggio
/// chiaro nei log + EX_CONFIG (78).
///
/// // PERCHÉ: senza config non c'è servizio da avviare (relay e identità
/// mancano) → un errore esplicito vale più di uno stacktrace. Attenzione: una
/// rune temporaneamente assente NON è fatale (vedi il blocco del client nel
/// main) — su StartOS `Revoke Runes` cancella e rigenera `.commando-env`.
Never _configError(FormatException e) {
  stderr.writeln('CONFIG NON VALIDA: ${e.message}');
  exit(78); // sysexits.h EX_CONFIG
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
