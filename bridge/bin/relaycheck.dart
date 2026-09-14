import 'dart:convert';
import 'dart:io';

import 'package:nwc_cln_bridge/src/config.dart';
import 'package:nwc_cln_bridge/src/nostr/nostr_crypto.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Verifica che gli eventi pubblicati dal bridge (risposte + info) siano
/// effettivamente presenti sul relay — diagnostica per "l'app non riceve
/// le risposte".
///
/// Uso: dart run bin/relaycheck.dart [--config=config.json]
Future<void> main(List<String> args) async {
  final opts = _parseArgs(args);
  final config = BridgeConfig.fromJsonFile(opts['config'] ?? 'config.json');
  final bridgePub = NostrCrypto.derivePublicKey(config.privkeyHex);

  stdout.writeln('relay: ${config.relay}');
  stdout.writeln('bridge pubkey: $bridgePub');

  final channel = WebSocketChannel.connect(Uri.parse(config.relay));
  await channel.ready;
  stdout.writeln('connesso — invio REQ per gli eventi del bridge…');

  channel.sink.add(
    jsonEncode([
      'REQ',
      'check',
      {
        'authors': [bridgePub],
        'kinds': [23195, 23199, 13194, 13198],
        'limit': 20,
      },
    ]),
  );

  var count = 0;
  await for (final raw in channel.stream) {
    final msg = jsonDecode(raw as String) as List<dynamic>;
    final type = msg.isNotEmpty ? '${msg[0]}' : '';
    if (type == 'EVENT' && msg.length >= 3) {
      final event = msg[2] as Map;
      count++;
      stdout.writeln(
        'EVENT kind=${event['kind']} '
        'created_at=${event['created_at']} id=${event['id']}',
      );
    } else if (type == 'EOSE') {
      break;
    } else if (type == 'NOTICE') {
      stdout.writeln('NOTICE: ${msg.length > 1 ? msg[1] : ''}');
    }
  }
  stdout.writeln('TOTALE EVENTI DEL BRIDGE SUL RELAY: $count');
  await channel.sink.close();
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
