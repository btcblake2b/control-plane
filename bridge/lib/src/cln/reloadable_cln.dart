import 'cln_api.dart';
import '../config.dart';
import '../logger.dart';
import '../protocol.dart';

/// Client CLN "ricaricabile".
///
/// // PERCHÉ: `NwcHandlers` riceve l'astrazione [ClnApi] una volta sola
/// all'avvio. In un container/package non c'è shell per riavviare il processo,
/// quindi il cambio di nodo (URL + rune dalla pagina di stato) deve applicarsi
/// a caldo: qui il client viene ricostruito dalla config corrente alla prima
/// chiamata successiva al [reload].
///
/// Con `clnUrl` vuoto il bridge resta vivo (pagina di stato e relay attivi) e
/// ogni richiesta dell'app riceve un errore esplicito invece di un timeout.
class ReloadableCln implements ClnApi {
  ReloadableCln({
    required BridgeConfig config,
    ClnApi? initial,
    Logger? logger,
  })  : _config = config,
        _client = initial,
        _logger = logger ?? Logger();

  BridgeConfig _config;
  final Logger _logger;
  ClnApi? _client;

  /// True se un nodo è configurato (URL presente).
  bool get hasNode => _config.clnUrl.isNotEmpty;

  /// Applica una nuova configurazione e invalida il client corrente.
  void reload(BridgeConfig config) {
    _config = config;
    _client = null;
    _logger.info(
      'nodo ${config.clnUrl.isEmpty ? 'rimosso' : 'aggiornato'}: '
      '${config.clnUrl}',
    );
  }

  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    if (_config.clnUrl.isEmpty) {
      throw const RpcError(
        'OTHER',
        'Nodo non configurato: apri la pagina del bridge e inserisci '
        'URL di clnrest e rune',
      );
    }
    // // PERCHÉ: costruzione lazy — la config del nodo può cambiare a runtime.
    // La costruzione può fallire (rune cancellata e non ancora rigenerata, PEM
    // mancanti, file illeggibile): l'errore va riportato all'app come RpcError,
    // NON fatto esplodere a livello di processo.
    try {
      final client = _client ??= ClnRestClient.fromConfig(
        _config,
        logger: _logger,
      );
      return await client.call(method, params);
    } on RpcError {
      rethrow;
    } catch (e) {
      _logger.warn('nodo non utilizzabile: $e');
      throw RpcError('OTHER', 'Nodo non disponibile: $e');
    }
  }
}
