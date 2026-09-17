import 'dart:io';

import 'config.dart';
import 'logger.dart';
import 'nostr/nostr_crypto.dart';

/// Relay di default quando la configurazione non lo specifica.
///
/// // PERCHÉ: è il relay usato in produzione dal bridge (damus.io rifiuta il
/// server del progetto — vedi docs/ai-memory/domain/lightning-network.md).
const String kDefaultRelay = 'wss://relay.primal.net';

/// Crea la configurazione al primo avvio (container) leggendo gli env, senza
/// MAI sovrascrivere una configurazione esistente.
///
/// // PERCHÉ: in un container non c'è un operatore che lancia `--genkey` e
/// copia `config.example.json`: la config deve nascere da sola al primo avvio
/// e poi restare stabile nel volume persistente.
///
/// Variabili lette (tutte opzionali tranne `BRIDGE_CLN_URL`):
/// `BRIDGE_RELAY`, `BRIDGE_CLN_URL`, `BRIDGE_RUNE_FILE`, `BRIDGE_RUNE_HEX`,
/// `BRIDGE_ALIAS`, `BRIDGE_CLN_CA`, `BRIDGE_CLN_CLIENT_CERT`,
/// `BRIDGE_CLN_CLIENT_KEY`, `BRIDGE_CLN_TLS_INSECURE`, `BRIDGE_UI_PORT`,
/// `BRIDGE_UI_TOKEN`, `BRIDGE_LOG_LEVEL`.
Future<BridgeConfig> ensureConfig({
  required String configPath,
  Map<String, String>? env,
  Logger? logger,
}) async {
  final log = logger ?? Logger();
  if (File(configPath).existsSync()) {
    log.info('config esistente: $configPath');
    return BridgeConfig.fromJsonFile(configPath);
  }

  final e = env ?? Platform.environment;
  final clnUrl = (e['BRIDGE_CLN_URL'] ?? '').trim();
  if (clnUrl.isEmpty) {
    // // PERCHÉ: in un package senza nodo collegato (es. Start9 con dependency
    // opzionale non installata) il bridge deve comunque partire: la pagina di
    // stato resta disponibile e l'utente configura URL+rune dal form.
    log.warn(
      'BRIDGE_CLN_URL assente: nodo non configurato '
      '(si configura dalla pagina di stato)',
    );
  }

  // // PERCHÉ (fail-fast, dal test in container del 16/09): senza rune il bridge
  // non può parlare col nodo e moriva al primo uso con uno stacktrace.
  // La richiesta è però CONDIZIONATA: senza nodo configurato (clnUrl vuoto) il
  // bridge deve partire lo stesso e farsi configurare dalla pagina di stato.
  final runeFileEnv = _nonEmpty(e['BRIDGE_RUNE_FILE']);
  final runeHexEnv = _nonEmpty(e['BRIDGE_RUNE_HEX']);
  if (clnUrl.isNotEmpty && runeFileEnv == null && runeHexEnv == null) {
    throw const FormatException(
      'serve BRIDGE_RUNE_HEX o BRIDGE_RUNE_FILE: la rune del nodo va fornita '
      'al container (es. BRIDGE_RUNE_FILE=/rune/bridge-rune)',
    );
  }

  final config = BridgeConfig(
    relay: (e['BRIDGE_RELAY'] ?? kDefaultRelay).trim(),
    // // PERCHÉ: la privkey è generata qui, così nessun segreto viaggia
    // nell'immagine o negli env del container.
    privkeyHex: NostrCrypto.randomHex32(),
    clnUrl: clnUrl,
    runeFile: runeFileEnv,
    runeHex: runeHexEnv,
    alias: _nonEmpty(e['BRIDGE_ALIAS']),
    clnCaFile: _nonEmpty(e['BRIDGE_CLN_CA']),
    clnClientCertFile: _nonEmpty(e['BRIDGE_CLN_CLIENT_CERT']),
    clnClientKeyFile: _nonEmpty(e['BRIDGE_CLN_CLIENT_KEY']),
    clnTlsInsecure: (e['BRIDGE_CLN_TLS_INSECURE'] ?? '') == 'true',
    uiPort: int.tryParse(e['BRIDGE_UI_PORT'] ?? '') ?? 0,
    // // PERCHÉ: la pagina mostra la stringa di connessione (una secret): se
    // la UI è attiva e nessun token è fornito, il bridge ne genera uno e lo
    // scrive nel log — così la pagina non resta aperta su LAN/Tor.
    uiToken: _uiToken(e, log),
    logLevel: (e['BRIDGE_LOG_LEVEL'] ?? 'info').trim(),
  );
  config.saveToFile(configPath);
  log.info(
    'config creata: $configPath '
    '(pubkey bridge: ${NostrCrypto.derivePublicKey(config.privkeyHex)})',
  );
  return config;
}

/// Genera la secret di sessione di un nuovo client, la registra nell'allowlist
/// (persistita) e ritorna la URI da incollare nell'app.
///
/// // PERCHÉ: stessa logica di `--genuri` usata da CLI e dalla pagina di stato:
/// una sola implementazione evita divergenze fra i due percorsi.
Future<String> generateClientUri({
  required BridgeConfig config,
  required String configPath,
  Logger? logger,
}) async {
  final secret = NostrCrypto.randomHex32();
  final clientPub = NostrCrypto.derivePublicKey(secret);
  // // PERCHÉ (sicurezza): la pubkey del client entra nell'allowlist: senza
  // questo passaggio l'app non verrebbe autorizzata dal bridge.
  if (!config.allowedClientPubkeys.contains(clientPub)) {
    config.allowedClientPubkeys.add(clientPub);
    config.saveToFile(configPath);
    logger?.info('client autorizzato: $clientPub');
  }
  final bridgePub = NostrCrypto.derivePublicKey(config.privkeyHex);
  final relay = Uri.encodeComponent(config.relay);
  return 'nostr+walletconnect://$bridgePub?relay=$relay&secret=$secret';
}

String? _nonEmpty(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  return trimmed;
}

/// Token della pagina di stato.
///
/// // PERCHÉ: `BRIDGE_UI_TOKEN=none` disattiva la richiesta del token quando la
/// pagina sta dietro un proxy autenticato (app_proxy di Umbrel fa login Umbrel
/// + 2FA); con la UI attiva e nessun valore il token viene generato e loggato.
String? _uiToken(Map<String, String> env, Logger log) {
  final provided = _nonEmpty(env['BRIDGE_UI_TOKEN']);
  if (provided != null) {
    if (provided == 'none') {
      log.warn(
        'token della pagina disattivato (BRIDGE_UI_TOKEN=none): esponi la '
        'pagina solo dietro un proxy autenticato',
      );
      return null;
    }
    return provided;
  }
  final port = int.tryParse(env['BRIDGE_UI_PORT'] ?? '') ?? 0;
  if (port <= 0) {
    return null;
  }
  final generated = NostrCrypto.randomHex32();
  log.warn(
    'token della pagina generato: apri la pagina come '
    'http://<host>:$port/?token=$generated',
  );
  return generated;
}
