import 'dart:convert';
import 'dart:io';

/// Configurazione del bridge, caricata da file JSON.
///
/// Esempio (config.example.json):
/// ```json
/// {
///   "relay": "wss://relay.damus.io",
///   "privkeyHex": "<64 hex>",
///   "clnUrl": "http://127.0.0.1:3001",
///   "runeFile": "/home/filippo/.lightning/bridge-rune",
///   "alias": "btcblake2b-bridge",
///   "allowedClientPubkeys": [],
///   "logLevel": "info"
/// }
/// ```
class BridgeConfig {
  BridgeConfig({
    required this.relay,
    required this.privkeyHex,
    required this.clnUrl,
    this.runeFile,
    this.runeHex,
    this.alias,
    List<String>? allowedClientPubkeys,
    this.logLevel = 'info',
    this.notifyPollSeconds = 20,
  }) : allowedClientPubkeys = allowedClientPubkeys ?? [];

  /// Relay Nostr (wss://) su cui il bridge ascolta le richieste.
  final String relay;

  /// Chiave privata Nostr del bridge (hex 64) — identità del "wallet service".
  final String privkeyHex;

  /// URL base di CLNRest (es. http://127.0.0.1:3001).
  final String clnUrl;

  /// File con la rune dedicata (formato `LIGHTNING_RUNE="<rune>"` o valore raw).
  final String? runeFile;

  /// Alternativa: rune in chiaro nella config (sconsigliata).
  final String? runeHex;

  /// Alias mostrato in `get_info`.
  String? alias;

  /// Pubkey dei client autorizzati: SOLO queste possono inviare richieste.
  /// // PERCHÉ (sicurezza): senza allowlist chiunque potrebbe comandare il nodo.
  final List<String> allowedClientPubkeys;

  /// Livello di log (debug|info|warn|error).
  final String logLevel;

  /// Intervallo del poll notifiche in secondi (0 = notifiche disattivate).
  final int notifyPollSeconds;

  static final RegExp _hex64 = RegExp(r'^[0-9a-fA-F]{64}$');

  static BridgeConfig fromJsonFile(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      throw FormatException('Config non trovata: $path');
    }
    final json =
        (jsonDecode(file.readAsStringSync()) as Map).cast<String, dynamic>();
    final relay = '${json['relay'] ?? ''}';
    final privkey = '${json['privkeyHex'] ?? ''}'.toLowerCase();
    final clnUrl = '${json['clnUrl'] ?? ''}';
    if (!relay.startsWith('wss://') && !relay.startsWith('ws://')) {
      throw const FormatException('relay non valido (atteso wss://)');
    }
    if (!_hex64.hasMatch(privkey)) {
      throw const FormatException(
        'privkeyHex mancante o non valida (64 char hex) — genera con --genkey',
      );
    }
    if (clnUrl.isEmpty) {
      throw const FormatException('clnUrl mancante');
    }
    return BridgeConfig(
      relay: relay,
      privkeyHex: privkey,
      clnUrl: clnUrl,
      runeFile: json['runeFile']?.toString(),
      runeHex: json['runeHex']?.toString(),
      alias: json['alias']?.toString(),
      allowedClientPubkeys:
          ((json['allowedClientPubkeys'] as List?) ?? const [])
              .map((e) => '$e'.toLowerCase())
              .toList(),
      logLevel: '${json['logLevel'] ?? 'info'}',
      notifyPollSeconds: (json['notifyPollSeconds'] as num?)?.toInt() ?? 20,
    );
  }

  /// Riscrive il file di config (usato da --genuri per salvare l'allowlist).
  void saveToFile(String path) {
    File(path).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(toJson()),
    );
  }

  Map<String, dynamic> toJson() => {
        'relay': relay,
        'privkeyHex': privkeyHex,
        'clnUrl': clnUrl,
        if (runeFile != null) 'runeFile': runeFile,
        if (runeHex != null) 'runeHex': runeHex,
        if (alias != null) 'alias': alias,
        'allowedClientPubkeys': allowedClientPubkeys,
        'logLevel': logLevel,
        'notifyPollSeconds': notifyPollSeconds,
      };

  /// Legge la rune dal file (formato RTL `LIGHTNING_RUNE="…"` o valore raw).
  String loadRune() {
    final hex = runeHex;
    if (hex != null && hex.isNotEmpty) {
      return hex;
    }
    final path = runeFile;
    if (path == null || path.isEmpty) {
      throw const FormatException(
          'Nessuna rune configurata (runeFile/runeHex)',);
    }
    final raw = File(path).readAsStringSync().trim();
    final match = RegExp('LIGHTNING_RUNE="([^"]+)"').firstMatch(raw);
    if (match != null) {
      return match.group(1)!;
    }
    return raw;
  }
}
