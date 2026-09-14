import 'dart:math';

import 'cln/cln_api.dart';
import 'logger.dart';
import 'protocol.dart';

/// Traduce i metodi NWC/NCC nei comandi CLN e mappa le risposte nel formato
/// atteso dal client (spec dln-node, verificata nei test del client Flutter).
class NwcHandlers {
  NwcHandlers({required this.cln, Logger? logger})
      : _logger = logger ?? Logger();

  final ClnApi cln;
  final Logger _logger;

  final Random _random = Random();

  /// Dispatch: ritorna il campo `result` della risposta al client.
  /// Lancia [RpcError] per errori applicativi (mappati nel campo `error`).
  Future<Map<String, dynamic>> handle(
    String method,
    Map<String, dynamic> params,
  ) async {
    switch (method) {
      case 'get_info':
        return _getInfo();
      case 'get_balance':
        return _getBalance();
      case 'make_invoice':
        return _makeInvoice(params);
      case 'pay_invoice':
        return _payInvoice(params);
      case 'list_channels':
        return _listChannels();
      case 'open_channel':
        return _openChannel(params);
      case 'close_channel':
        return _closeChannel(params);
      default:
        throw RpcError(
          'NOT_IMPLEMENTED',
          'Metodo non supportato: $method',
        );
    }
  }

  // ── NWC ─────────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _getInfo() async {
    final info = await cln.call('getinfo');
    return {
      'alias': info['alias'],
      'pubkey': info['id'],
      // PERCHÉ: la UX deve poter distinguere la rete — il fork è blake2b.
      'network': 'blake2b',
      'blockheight': info['blockheight'],
      'methods': Protocol.nwcInfoContent.split(' '),
    };
  }

  /// Saldo totale spendibile = canali attivi (`to_us_msat`) + fondi on-chain
  /// confermati e non riservati.
  ///
  /// // PERCHÉ: è il numero che l'utente si aspetta dal wallet (LN + on-chain);
  /// le riserve dei canali restano conteggiate finché il canale è aperto.
  Future<Map<String, dynamic>> _getBalance() async {
    var totalMsat = 0;

    final funds = await cln.call('listfunds');
    for (final o in (funds['outputs'] as List? ?? const [])) {
      final out = (o as Map).cast<String, dynamic>();
      if ('${out['status']}' == 'confirmed' && out['reserved'] != true) {
        totalMsat += (out['amount_msat'] as num?)?.toInt() ?? 0;
      }
    }

    final channels = await cln.call('listpeerchannels');
    for (final c in (channels['channels'] as List? ?? const [])) {
      final ch = (c as Map).cast<String, dynamic>();
      if ('${ch['state']}' == 'CHANNELD_NORMAL') {
        totalMsat += (ch['to_us_msat'] as num?)?.toInt() ?? 0;
      }
    }
    return {'balance': totalMsat};
  }

  Future<Map<String, dynamic>> _makeInvoice(
    Map<String, dynamic> params,
  ) async {
    final amount = (params['amount'] as num?)?.toInt();
    if (amount == null || amount <= 0) {
      throw const RpcError('OTHER', 'make_invoice richiede amount (msat)');
    }
    final description = '${params['description'] ?? 'nwc-bridge'}';
    final label = 'nwcb-${DateTime.now().millisecondsSinceEpoch}'
        '-${_random.nextInt(0xFFFFFF).toRadixString(16)}';
    final inv = await cln.call('invoice', {
      'amount_msat': amount,
      'label': label,
      'description': description,
    });
    return {
      'invoice': inv['bolt11'],
      'payment_hash': inv['payment_hash'],
      'amount': amount,
      'description': description,
      if (inv['expires_at'] != null) 'expires_at': inv['expires_at'],
    };
  }

  Future<Map<String, dynamic>> _payInvoice(
    Map<String, dynamic> params,
  ) async {
    final bolt11 = params['invoice'] as String?;
    if (bolt11 == null || bolt11.isEmpty) {
      throw const RpcError('OTHER', 'pay_invoice richiede invoice');
    }
    final res = await cln.call('pay', {'bolt11': bolt11});
    final sent = (res['amount_sent_msat'] as num?)?.toInt() ?? 0;
    final amount = (res['amount_msat'] as num?)?.toInt() ?? 0;
    return {
      'preimage': '${res['payment_preimage'] ?? ''}',
      // Fee = inviato − richiesto (amount_sent_msat include le fee).
      'fees_paid': sent > amount ? sent - amount : 0,
    };
  }

  // ── NCC ─────────────────────────────────────────────────────────────────────

  /// Mapping `listpeerchannels` (CLN) → LdkChannelInfo (spec NCC).
  /// Unità: TUTTI i saldi in msat (convenzione NWC/LDK).
  Future<Map<String, dynamic>> _listChannels() async {
    final res = await cln.call('listpeerchannels');
    final out = <Map<String, dynamic>>[];
    for (final c in (res['channels'] as List? ?? const [])) {
      final ch = (c as Map).cast<String, dynamic>();
      final total = (ch['total_msat'] as num?)?.toInt() ?? 0;
      final toUs = (ch['to_us_msat'] as num?)?.toInt() ?? 0;
      out.add({
        'id': '${ch['channel_id'] ?? ''}',
        if (ch['short_channel_id'] != null)
          'short_channel_id': ch['short_channel_id'],
        'peer_pubkey': '${ch['peer_id'] ?? ''}',
        'state': mapState('${ch['state']}'),
        'is_private': ch['private'] as bool? ?? false,
        'local_balance': toUs,
        'remote_balance': total - toUs,
        'capacity': total,
        if (ch['funding_txid'] != null) 'funding_txid': ch['funding_txid'],
      });
    }
    return {'channels': out};
  }

  Future<Map<String, dynamic>> _openChannel(
    Map<String, dynamic> params,
  ) async {
    final pubkey = '${params['pubkey'] ?? ''}';
    final amount = (params['amount'] as num?)?.toInt();
    final host = params['host'] as String?;
    final isPrivate = params['private'] as bool? ?? false;
    if (pubkey.isEmpty || amount == null || amount <= 0) {
      throw const RpcError(
        'OTHER',
        'open_channel richiede pubkey e amount (sat)',
      );
    }
    // PERCHÉ: se il client fornisce l'host, il bridge fa anche il connect —
    // l'app non deve conoscere lo stato dei peer del nodo.
    if (host != null && host.isNotEmpty) {
      await cln.call('connect', {'id': '$pubkey@$host'});
    }
    _logger.info(
      'open_channel: $pubkey, $amount sat (private=$isPrivate)',
    );
    final res = await cln.call('fundchannel', {
      'id': pubkey,
      'amount': '$amount',
      'announce': !isPrivate,
    });
    return {
      if (res['txid'] != null) 'txid': res['txid'],
      if (res['channel_id'] != null) 'channel_id': res['channel_id'],
    };
  }

  Future<Map<String, dynamic>> _closeChannel(
    Map<String, dynamic> params,
  ) async {
    final id = '${params['id'] ?? ''}';
    final force = params['force'] as bool? ?? false;
    if (id.isEmpty) {
      throw const RpcError('OTHER', 'close_channel richiede id');
    }
    final res = await cln.call('close', {
      'id': id,
      // PERCHÉ: unilateraltimeout=0 = chiusura forzata immediata (force).
      if (force) 'unilateraltimeout': 0,
    });
    return {
      if (res['tx'] != null) 'txid': res['tx'],
      if (res['txid'] != null) 'txid': res['txid'],
    };
  }

  // ── Util ────────────────────────────────────────────────────────────────────

  /// Mappa gli stati CLN sugli stati ldk-node attesi dal client.
  static String mapState(String clnState) {
    switch (clnState) {
      case 'CHANNELD_NORMAL':
        return 'Usable';
      case 'CHANNELD_AWAITING_LOCKIN':
        return 'PendingOpen';
      case 'ONCHAIN':
        return 'Closed';
      default:
        if (clnState.startsWith('CLOSINGD')) {
          return 'Closing';
        }
        return clnState;
    }
  }
}
