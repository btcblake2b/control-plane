import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nwc_cln_bridge/src/nostr/nostr_crypto.dart';
import 'package:nwc_cln_bridge/src/nostr/nostr_event.dart';
import 'package:nwc_cln_bridge/src/nostr/websocket_transport.dart';
import 'package:nwc_cln_bridge/src/protocol.dart';

/// Sonda di verifica del bridge: invia richieste NWC/NCC come farebbe l'app
/// (stesso protocollo, stessa cifratura NIP-04) e stampa le risposte.
///
/// Uso:
///   dart run bin/probe.dart --uri-file=uri.txt
///   dart run bin/probe.dart --uri=nostr+walletconnect://…
Future<void> main(List<String> args) async {
  final opts = _parseArgs(args);
  var uri = opts['uri'] ?? '';
  final uriFile = opts['uri-file'];
  if (uri.isEmpty && uriFile != null) {
    uri = File(uriFile).readAsStringSync().trim();
  }
  if (uri.isEmpty) {
    stderr.writeln(
      'Uso: --uri-file=uri.txt oppure --uri=nostr+walletconnect://…',
    );
    exit(1);
  }
  final parsed = Uri.parse(uri);
  final bridgePub = parsed.host.toLowerCase();
  final relay = parsed.queryParameters['relay'] ?? '';
  final secret = (parsed.queryParameters['secret'] ?? '').toLowerCase();
  if (bridgePub.length != 64 || secret.length != 64 || relay.isEmpty) {
    stderr.writeln('URI non valida');
    exit(1);
  }
  final clientPub = NostrCrypto.derivePublicKey(secret);

  final transport = WebSocketTransport();
  await transport.connect(relay);
  final pending = <String, Completer<Map<String, dynamic>>>{};
  transport.subscribe([
    {
      'kinds': [Protocol.nwcResponseKind, Protocol.nccResponseKind],
      '#p': [clientPub],
    },
  ]).listen((event) {
    if (event.pubkey != bridgePub || !event.verify()) {
      return;
    }
    final requestId = event.firstTagValue('e');
    final completer = requestId == null ? null : pending.remove(requestId);
    if (completer == null || completer.isCompleted) {
      return;
    }
    try {
      final decrypted = NostrCrypto.nip04Decrypt(
        privkeyHex: secret,
        pubkeyHex: event.pubkey,
        payload: event.content,
      );
      completer.complete(
        (jsonDecode(decrypted) as Map).cast<String, dynamic>(),
      );
    } catch (e) {
      completer.completeError(e);
    }
  });

  Future<Map<String, dynamic>> request(
    int kind,
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    final payload = jsonEncode({
      'method': method,
      if (params.isNotEmpty) 'params': params,
    });
    final encrypted = NostrCrypto.nip04Encrypt(
      privkeyHex: secret,
      pubkeyHex: bridgePub,
      plaintext: payload,
    );
    final event = NostrEvent.unsigned(
      pubkey: clientPub,
      kind: kind,
      tags: [
        ['p', bridgePub],
      ],
      content: encrypted,
    ).sign(secret);
    final completer = Completer<Map<String, dynamic>>();
    pending[event.id] = completer;
    await transport.publish(event);
    return completer.future.timeout(const Duration(seconds: 25));
  }

  var failures = 0;
  final probes = [
    (Protocol.nwcRequestKind, 'get_info', const <String, dynamic>{}),
    (Protocol.nwcRequestKind, 'get_balance', const <String, dynamic>{}),
    (Protocol.nccRequestKind, 'list_channels', const <String, dynamic>{}),
    (Protocol.nccRequestKind, 'list_peers', const <String, dynamic>{}),
    (
      Protocol.nwcRequestKind,
      'list_transactions',
      const <String, dynamic>{'limit': 5}
    ),
    (Protocol.nwcRequestKind, 'list_addresses', const <String, dynamic>{}),
    (Protocol.nwcRequestKind, 'list_utxos', const <String, dynamic>{}),
    (
      Protocol.nwcRequestKind,
      'list_invoices',
      const <String, dynamic>{'limit': 3}
    ),
    (
      Protocol.nwcRequestKind,
      'list_pays',
      const <String, dynamic>{'limit': 3}
    ),
    (Protocol.nwcRequestKind, 'get_pending_htlcs', const <String, dynamic>{}),
    (
      Protocol.nwcRequestKind,
      'estimate_onchain_fees',
      const <String, dynamic>{}
    ),
    (Protocol.nccRequestKind, 'get_node_stats', const <String, dynamic>{}),
    (Protocol.nccRequestKind, 'list_forwards', const <String, dynamic>{}),
    (
      Protocol.nwcRequestKind,
      'make_invoice',
      const <String, dynamic>{
        'amount': 1000000,
        'description': 'probe-test',
      }
    ),
  ];
  for (final probe in probes) {
    final method = probe.$2;
    try {
      final res = await request(probe.$1, method, probe.$3);
      stdout.writeln('$method → ${jsonEncode(res)}');
      if (res['error'] != null) {
        failures++;
      }
    } catch (e) {
      stdout.writeln('$method → FALLITO: $e');
      failures++;
    }
  }

  // Le fee di canale richiedono un id: probe in due tempi (solo lettura).
  try {
    final channels = await request(
      Protocol.nccRequestKind,
      'list_channels',
      const <String, dynamic>{},
    );
    final list = (channels['result'] as Map?)?['channels'] as List?;
    final id = (list == null || list.isEmpty)
        ? null
        : (list.first as Map)['id'] as String?;
    if (id == null) {
      stdout.writeln('get_channel_fees → saltato (nessun canale)');
    } else {
      final res = await request(
        Protocol.nccRequestKind,
        'get_channel_fees',
        <String, dynamic>{'id': id},
      );
      stdout.writeln('get_channel_fees → ${jsonEncode(res)}');
      if (res['error'] != null) {
        failures++;
      }
    }
  } catch (e) {
    stdout.writeln('get_channel_fees → FALLITO: $e');
    failures++;
  }

  // Le info di rete richiedono un node id: si usa il peer del canale.
  // NB: `keysend` NON è nella sonda — è una scrittura che spende fondi.
  try {
    final channels = await request(
      Protocol.nccRequestKind,
      'list_channels',
      const <String, dynamic>{},
    );
    final channelList = (channels['result'] as Map?)?['channels'] as List?;
    final peerId = (channelList == null || channelList.isEmpty)
        ? null
        : (channelList.first as Map)['peer_pubkey'] as String?;
    // PERCHÉ: `get_route` può riuscire solo verso un canale "Usable" con peer
    // connesso. Con soli canali chiusi/in attesa (es. nodo senza peer per il
    // gate bit 68 del `.4`) la rotta non può esistere: si salta il controllo
    // invece di segnalare un falso fallimento del deploy.
    String? routePeerId;
    if (channelList != null) {
      for (final c in channelList.cast<Map>()) {
        if (c['peer_connected'] == true && c['state'] == 'Usable') {
          routePeerId = c['peer_pubkey'] as String?;
          if (routePeerId != null) {
            break;
          }
        }
      }
    }
    if (peerId == null) {
      stdout.writeln('get_node_info → saltato (nessun canale)');
    } else {
      final info = await request(
        Protocol.nccRequestKind,
        'get_node_info',
        <String, dynamic>{'node_id': peerId},
      );
      stdout.writeln('get_node_info → ${jsonEncode(info)}');
      if (info['error'] != null) {
        failures++;
      }
      if (routePeerId == null) {
        stdout.writeln('get_route → saltato (nessun canale usabile)');
      } else {
        final route = await request(
          Protocol.nccRequestKind,
          'get_route',
          <String, dynamic>{
            'destination': routePeerId,
            'amount_msat': 1000000,
          },
        );
        stdout.writeln('get_route → ${jsonEncode(route)}');
        if (route['error'] != null) {
          failures++;
        }
      }
    }
  } catch (e) {
    stdout.writeln('get_node_info/get_route → FALLITO: $e');
    failures++;
  }

  await transport.close();
  if (failures > 0) {
    stderr.writeln('PROBE: $failures richieste fallite');
    exit(1);
  }
  stdout.writeln('PROBE_OK');
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
