import 'dart:convert';
import 'dart:io';

import 'package:qr/qr.dart';

import '../bootstrap.dart';
import '../bridge_service.dart';
import '../cln/reloadable_cln.dart';
import '../config.dart';
import '../logger.dart';

/// Pagina web minima del bridge: stato del collegamento + stringa di
/// connessione (URI con QR) da incollare nell'app.
///
/// // PERCHÉ: su Umbrel non esiste accesso SSH/CLI (App Store Standard: "tutto
/// dal browser"): la pagina è l'unico modo per l'utente di ottenere la URI.
///
/// La URI corrente è riusata finché l'utente non ne chiede una nuova: senza
/// questo, ogni ricarica della pagina autorizzerebbe un client in più.
class StatusServer {
  StatusServer({
    required this.config,
    required this.configPath,
    required this.service,
    required this.cln,
    required this.port,
    this.token,
    Logger? logger,
  }) : _logger = logger ?? Logger();

  BridgeConfig config;
  final String configPath;
  final BridgeService service;

  /// Client del nodo: ricaricato a caldo quando il form salva nuovi dati.
  final ReloadableCln cln;

  final int port;

  /// Token atteso (header `x-bridge-token` o `?token=`). Null = accesso libero
  /// (le app Umbrel stanno già dietro l'autenticazione del dashboard).
  final String? token;

  final Logger _logger;

  HttpServer? _server;
  String? _cachedUri;

  /// File della URI corrente, accanto alla config (come sul server).
  late final String _uriPath =
      '${File(configPath).parent.path}${Platform.pathSeparator}uri.txt';

  /// Porta effettiva (utile nei test con porta 0 = effimera).
  int get boundPort => _server?.port ?? 0;

  Future<void> start() async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server = server;
    // // PERCHÉ: il bind è su 0.0.0.0 (anyIPv4): loggare il loopback farebbe
    // credere che la pagina non sia raggiungibile dall'esterno del container.
    _logger.info('pagina di stato in ascolto sulla porta ${server.port}');
    // // PERCHÉ: listen senza await — il server resta vivo in background.
    server.listen(_handle);
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  bool _authorized(HttpRequest req) {
    final expected = token;
    if (expected == null || expected.isEmpty) {
      return true;
    }
    final header = req.headers.value('x-bridge-token');
    final query = req.uri.queryParameters['token'];
    return header == expected || query == expected;
  }

  Future<void> _handle(HttpRequest req) async {
    if (!_authorized(req)) {
      req.response.statusCode = HttpStatus.unauthorized;
      await req.response.close();
      return;
    }
    try {
      switch ('${req.method} ${req.uri.path}') {
        case 'GET /':
          await _html(req);
        case 'GET /api/status':
          await _json(req, await _status());
        case 'POST /api/uri':
          await _json(req, {'uri': await _uri(regenerate: true)});
        case 'POST /api/config':
          await _saveConfig(req);
        default:
          req.response.statusCode = HttpStatus.notFound;
          await req.response.close();
      }
    } catch (e) {
      _logger.warn('pagina di stato: errore su ${req.uri.path}: $e');
      req.response.statusCode = HttpStatus.internalServerError;
      await req.response.close();
    }
  }

  /// URI corrente: legge `uri.txt` (o la genera al primo accesso) per non
  /// autorizzare un nuovo client a ogni ricarica della pagina.
  Future<String> _uri({required bool regenerate}) async {
    if (!regenerate) {
      final cached = _cachedUri;
      if (cached != null) {
        return cached;
      }
      final file = File(_uriPath);
      if (file.existsSync()) {
        final existing = file.readAsStringSync().trim();
        if (existing.isNotEmpty) {
          _cachedUri = existing;
          return existing;
        }
      }
    }
    final uri = await generateClientUri(
      config: config,
      configPath: configPath,
      logger: _logger,
    );
    _cachedUri = uri;
    _writeUriFile(uri);
    return uri;
  }

  void _writeUriFile(String uri) {
    try {
      File(_uriPath).writeAsStringSync('$uri\n');
      if (!Platform.isWindows) {
        // // PERCHÉ: la URI contiene una secret per dispositivo: permessi 600
        // come sul server. Best-effort: se chmod manca non blocca l'avvio.
        Process.runSync('chmod', ['600', _uriPath]);
      }
    } catch (e) {
      _logger.warn('uri.txt non scritto: $e');
    }
  }

  Future<Map<String, dynamic>> _status() async {
    var network = 'non raggiungibile';
    try {
      final info = await service.handlers.handle('get_info', const {});
      network = '${info['network'] ?? '?'}';
    } catch (e) {
      _logger.debug('get_info per la pagina di stato fallita: $e');
    }
    return {
      'connected': service.transport.isConnected,
      'relay': config.relay,
      'pubkey': service.publicKey,
      'network': network,
      'clients': config.allowedClientPubkeys.length,
      'clnUrl': config.clnUrl,
      'runeConfigured': config.runeFile != null || config.runeHex != null,
    };
  }

  /// Salva i dati del nodo inviati dal form e applica la config a caldo.
  Future<void> _saveConfig(HttpRequest req) async {
    final raw = await utf8.decoder.bind(req).join();
    Map<String, dynamic> body;
    try {
      body = (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      await _json(req, {'ok': false, 'error': 'JSON non valido'});
      return;
    }

    final url = '${body['clnUrl'] ?? ''}'.trim();
    if (url.isNotEmpty &&
        !url.startsWith('http://') &&
        !url.startsWith('https://')) {
      await _json(req, {'ok': false, 'error': 'URL non valido (http/https)'});
      return;
    }

    final rune = '${body['rune'] ?? ''}'.trim();
    var runeFile = config.runeFile;
    if (rune.isNotEmpty) {
      // // PERCHÉ: la rune è un segreto: va in un file dedicato 600 accanto
      // alla config, NON dentro il JSON (che finisce nei backup/volumi).
      runeFile = _writeRuneFile(rune);
    }

    final updated = config.withNode(
      clnUrl: url,
      runeFile: runeFile,
      // // PERCHÉ: una rune nuova deve SOSTITUIRE l'eventuale runeHex in
      // config.json, altrimenti `loadRune()` continuerebbe a usare la vecchia.
      runeHex: rune.isNotEmpty ? '' : null,
    );
    updated.saveToFile(configPath);
    config = updated;
    cln.reload(updated);
    _logger.info('configurazione del nodo aggiornata dalla pagina di stato');

    await _json(req, {
      'ok': true,
      'clnUrl': updated.clnUrl,
      'runeConfigured':
          updated.runeFile != null || updated.runeHex != null,
    });
  }

  String _writeRuneFile(String rune) {
    final base = File(configPath).parent.path;
    final path = '$base${Platform.pathSeparator}rune.txt';
    // // PERCHÉ: stesso formato accettato da `BridgeConfig.loadRune()`
    // (compatibile con il file di RTL sul server).
    File(path).writeAsStringSync('LIGHTNING_RUNE="$rune"\n');
    if (!Platform.isWindows) {
      Process.runSync('chmod', ['600', path]);
    }
    return path;
  }

  Future<void> _json(HttpRequest req, Map<String, dynamic> body) async {
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    await req.response.close();
  }

  Future<void> _html(HttpRequest req) async {
    final status = await _status();
    final uri = await _uri(regenerate: false);
    req.response.headers.contentType = ContentType.html;
    req.response.write(_page(status, uri));
    await req.response.close();
  }

  /// QR in SVG inline.
  ///
  /// // PERCHÉ: nessun asset o CDN esterno → la pagina resta autosufficiente e
  /// compatibile con una CSP stretta.
  String _qrSvg(String data, {int size = 220}) {
    final code = QrCode.fromData(
      data: data,
      errorCorrectLevel: QrErrorCorrectLevel.M,
    );
    // // PERCHÉ: in `qr` 3.x la matrice leggibile è `QrImage` (QrCode è solo
    // l'encoder dei dati).
    final image = QrImage(code);
    final modules = image.moduleCount;
    final cell = size / modules;
    final buffer = StringBuffer(
      '<svg xmlns="http://www.w3.org/2000/svg" width="$size" height="$size" '
      'viewBox="0 0 $size $size" role="img" aria-label="QR della URI">'
      '<rect width="$size" height="$size" fill="#ffffff"/>',
    );
    for (var row = 0; row < modules; row++) {
      for (var col = 0; col < modules; col++) {
        if (image.isDark(row, col)) {
          buffer.write(
            '<rect x="${(col * cell).toStringAsFixed(2)}" '
            'y="${(row * cell).toStringAsFixed(2)}" '
            'width="${cell.toStringAsFixed(2)}" '
            'height="${cell.toStringAsFixed(2)}" fill="#000000"/>',
          );
        }
      }
    }
    buffer.write('</svg>');
    return buffer.toString();
  }

  String _page(Map<String, dynamic> status, String uri) {
    final connected = status['connected'] == true;
    final state = connected
        ? '<span class="ok">connected</span>'
        : '<span class="ko">disconnected</span>';
    final clnUrl = '${status['clnUrl']}';
    final runePlaceholder = status['runeConfigured'] == true
        ? '(runa gi\u00e0 configurata: lascia vuoto per non cambiarla)'
        : 'incolla qui la rune del nodo';
    final tokenValue = token ?? '';
    return '''
<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>NWC/NCC Bridge</title>
<style>
 body{font-family:system-ui,sans-serif;margin:2rem;max-width:44rem;line-height:1.5}
 code{word-break:break-all;background:#f2f2f2;padding:.15rem .35rem}
 .ok{color:#0a7a2f}.ko{color:#a12}.small{color:#666;font-size:.9rem}
</style></head><body>
<h1>NWC/NCC bridge</h1>
<p>Relay: <code>${status['relay']}</code> — $state</p>
<p>Node network: <code>${status['network']}</code> ·
   authorized devices: ${status['clients']}</p>
<h2>Core Lightning node</h2>
<p class="small">REST URL of clnrest (e.g. <code>http://192.168.1.10:3010</code>).
   Empty = no node connected.</p>
<form onsubmit="saveNode(event)">
  <p><input id="clnUrl" value="$clnUrl" size="46"
       placeholder="http://host:port"></p>
  <p><input id="rune" type="password" size="46"
       placeholder="$runePlaceholder"></p>
  <p><button type="submit">Save and apply</button>
     <span id="msg" class="small"></span></p>
</form>
<script>
var TK = '$tokenValue';
function saveNode(e) {
  e.preventDefault();
  fetch('api/config', {
    method: 'POST',
    headers: {'Content-Type': 'application/json', 'x-bridge-token': TK},
    body: JSON.stringify({
      clnUrl: document.getElementById('clnUrl').value,
      rune: document.getElementById('rune').value
    })
  }).then(function (r) { return r.json(); }).then(function (j) {
    document.getElementById('msg').textContent = j.ok ? 'saved' : (j.error || 'error');
  });
}
</script>
<h2>Connection string</h2>
<p>Scan the QR code or paste the string in the app
   (<em>Lightning → Connect</em>).</p>
${_qrSvg(uri)}
<p><code id="uri">$uri</code></p>
<p class="small">It contains a device secret: treat it like a password and do
   not share it.</p>
<p><button onclick="fetch('api/uri',{method:'POST'}).then(function(){location.reload();})">
   Authorize a new device</button>
   <span class="small">(the string already in use stays valid)</span></p>
</body></html>''';
  }
}
