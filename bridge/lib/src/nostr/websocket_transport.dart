import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../logger.dart';
import 'nostr_event.dart';
import 'nostr_transport.dart';

/// Transport Nostr su WebSocket per il bridge (double del client mobile).
///
/// // PERCHÉ: il client Flutter usa debugPrint (foundation), qui il bridge è
/// puro Dart server-side → Logger iniettabile. MVP: un relay singolo.
class WebSocketTransport implements NostrTransport {
  WebSocketTransport({Logger? logger}) : _logger = logger ?? Logger();

  final Logger _logger;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  final StreamController<NostrEvent> _events =
      StreamController<NostrEvent>.broadcast();
  int _subCounter = 0;
  bool _closing = false;
  DateTime? _connectedSince;

  @override
  bool get isConnected => _channel != null;

  @override
  DateTime? get connectedSince => _connectedSince;

  @override
  Future<void> connect(String relayUrl) async {
    await close();
    // // PERCHÉ: il ping WebSocket ogni 30s tiene viva la NAT (evita che la
    // connessione inattiva venga droppata in silenzio) e fa chiudere il
    // canale se il relay non risponde più al pong: l'health check del
    // bridge riconnette da solo.
    final channel = IOWebSocketChannel.connect(
      Uri.parse(relayUrl),
      pingInterval: const Duration(seconds: 30),
    );
    await channel.ready;
    _channel = channel;
    _connectedSince = DateTime.now();
    _sub = channel.stream.listen(
      _onMessage,
      onError: (Object e) {
        _logger.warn('relay: errore: $e');
        _channel = null;
        _connectedSince = null;
      },
      onDone: () {
        _channel = null;
        _connectedSince = null;
        if (!_closing) {
          _logger.warn('relay: connessione chiusa');
        }
      },
    );
    _logger.info('relay: connesso a $relayUrl');
  }

  void _onMessage(dynamic raw) {
    try {
      final msg = jsonDecode(raw as String) as List<dynamic>;
      final type = msg.isNotEmpty ? msg[0] as String : '';
      if (type == 'EVENT' && msg.length >= 3) {
        final event = NostrEvent.fromJson(
          (msg[2] as Map).cast<String, dynamic>(),
        );
        _events.add(event);
      } else if (type == 'NOTICE' && msg.length >= 2) {
        _logger.warn('relay: NOTICE: ${msg[1]}');
      } else if (type == 'OK' && msg.length >= 4) {
        // // PERCHÉ: gli OK negativi dicono PERCHÉ il relay ha rifiutato la
        // pubblicazione (rate limit, auth, bloccato): senza questo log i
        // rifiuti sono invisibili.
        final accepted = msg[2] == true;
        if (accepted) {
          _logger.debug('relay: evento accettato (${msg[1]})');
        } else {
          _logger.warn('relay: evento RIFIUTATO (${msg[1]}): ${msg[3]}');
        }
      } else if (type == 'CLOSED' && msg.length >= 3) {
        _logger.warn('relay: subscription chiusa: ${msg[2]}');
      }
      // EOSE: ignorato nell'MVP.
    } catch (e) {
      _logger.warn('relay: messaggio non valido: $e');
    }
  }

  @override
  Future<void> publish(NostrEvent event) async {
    final channel = _channel;
    if (channel == null) {
      throw StateError('Transport non connesso');
    }
    channel.sink.add(jsonEncode(['EVENT', event.toJson()]));
  }

  @override
  Stream<NostrEvent> subscribe(List<Map<String, dynamic>> filters) {
    final channel = _channel;
    if (channel == null) {
      throw StateError('Transport non connesso');
    }
    final subId = 'bridge_${_subCounter++}';
    channel.sink.add(jsonEncode(['REQ', subId, ...filters]));
    return _events.stream;
  }

  @override
  Future<void> close() async {
    _closing = true;
    await _sub?.cancel();
    _sub = null;
    final channel = _channel;
    _channel = null;
    _connectedSince = null;
    if (channel != null) {
      await channel.sink.close();
    }
    _closing = false;
  }
}
