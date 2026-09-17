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
      case 'make_new_address':
        return _makeNewAddress(params);
      case 'pay_onchain':
        return _payOnchain(params);
      case 'estimate_onchain_fees':
        return _estimateOnchainFees();
      case 'list_addresses':
        return _listAddresses();
      case 'list_utxos':
        return _listUtxos();
      case 'list_invoices':
        return _listInvoices(params);
      case 'lookup_invoice':
        return _lookupInvoice(params);
      case 'list_pays':
        return _listPays(params);
      case 'get_pending_htlcs':
        return _getPendingHtlcs();
      case 'list_transactions':
        return _listTransactions(params);
      case 'list_channels':
        return _listChannels();
      case 'open_channel':
        return _openChannel(params);
      case 'close_channel':
        return _closeChannel(params);
      case 'connect_peer':
        return _connectPeer(params);
      case 'disconnect_peer':
        return _disconnectPeer(params);
      case 'list_peers':
        return _listPeers();
      case 'get_channel_fees':
        return _getChannelFees(params);
      case 'set_channel_fees':
        return _setChannelFees(params);
      case 'get_node_stats':
        return _getNodeStats();
      // PERCHÉ (NIP-XX): i nomi canonici della spec NNC (Nostr Node Control)
      // sono accettati insieme a quelli storici — il bridge aggiornato serve
      // sia le app nuove sia quelle già installate (zero breaking).
      case 'get_forwarding_history':
      case 'list_forwards':
        return _listForwards(params);
      case 'get_network_node':
      case 'get_node_info':
        return _getNodeInfo(params);
      case 'query_routes':
      case 'get_route':
        return _getRoute(params);
      case 'keysend':
        return _keysend(params);
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
    // PERCHÉ (I4a): `getinfo.num_peers` conta i peer REGISTRATI nel peer table
    // (anche disconnessi, se hanno un canale) — la UI deve mostrare i CONNESSI.
    // Fail-soft: se `listpeers` fallisce il campo è omesso e `get_info` resta
    // valida (retro-compatibile: i client vecchi lo ignorano).
    int? peersConnected;
    try {
      final peers = await cln.call('listpeers');
      peersConnected = (peers['peers'] as List? ?? const [])
          .where((p) => (p as Map)['connected'] == true)
          .length;
    } on Exception catch (_) {
      _logger.warn(
        'get_info: listpeers non disponibile — conteggio connessi omesso',
      );
    }
    return {
      'alias': info['alias'],
      'pubkey': info['id'],
      // PERCHÉ: la UX deve poter distinguere la rete — il fork è blake2b.
      'network': 'blake2b',
      'blockheight': info['blockheight'],
      // PERCHÉ (spec dln/NIP-47): il campo canonico è `block_height`;
      // emetto entrambi per retrocompatibilità del probe.
      'block_height': info['blockheight'],
      // PERCHÉ (I3): il dashboard "Gestione nodo" mostra identità e stato del
      // nodo senza una seconda chiamata.
      if (info['color'] != null) 'color': info['color'],
      if (info['version'] != null) 'version': info['version'],
      if (info['num_peers'] != null) 'num_peers': info['num_peers'],
      if (peersConnected != null) 'num_peers_connected': peersConnected,
      if (info['num_active_channels'] != null)
        'num_active_channels': info['num_active_channels'],
      if (info['num_pending_channels'] != null)
        'num_pending_channels': info['num_pending_channels'],
      'methods': Protocol.nwcInfoContent.split(' '),
    };
  }

  /// Saldo totale spendibile = canali attivi (`to_us_msat`) + fondi on-chain
  /// confermati e non riservati.
  ///
  /// // PERCHÉ: è il numero che l'utente si aspetta dal wallet (LN + on-chain);
  /// le riserve dei canali restano conteggiate finché il canale è aperto.
  /// I campi additivi `onchain`/`lightning` alimentano il dashboard dell'app.
  Future<Map<String, dynamic>> _getBalance() async {
    var onchainMsat = 0;

    final funds = await cln.call('listfunds');
    for (final o in (funds['outputs'] as List? ?? const [])) {
      final out = (o as Map).cast<String, dynamic>();
      if ('${out['status']}' == 'confirmed' && out['reserved'] != true) {
        onchainMsat += (out['amount_msat'] as num?)?.toInt() ?? 0;
      }
    }

    var lnMsat = 0;
    final channels = await cln.call('listpeerchannels');
    for (final c in (channels['channels'] as List? ?? const [])) {
      final ch = (c as Map).cast<String, dynamic>();
      if ('${ch['state']}' == 'CHANNELD_NORMAL') {
        lnMsat += (ch['to_us_msat'] as num?)?.toInt() ?? 0;
      }
    }
    // // PERCHÉ (I1): `balance` resta il totale (retrocompatibile); i campi
    // additivi `onchain`/`lightning` alimentano il dashboard dell'app con
    // fallback al totale sui client vecchi.
    return {
      'balance': onchainMsat + lnMsat,
      'onchain': onchainMsat,
      'lightning': lnMsat,
    };
  }

  Future<Map<String, dynamic>> _makeInvoice(
    Map<String, dynamic> params,
  ) async {
    final amount = (params['amount'] as num?)?.toInt();
    if (amount == null || amount <= 0) {
      throw const RpcError(
        'BAD_REQUEST',
        'make_invoice richiede amount (msat)',
      );
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
      throw const RpcError('BAD_REQUEST', 'pay_invoice richiede invoice');
    }
    final Map<String, dynamic> res;
    try {
      res = await cln.call('pay', {'bolt11': bolt11});
    } on RpcError catch (e) {
      throw RpcError(
        classifyClnFailure(e.message, fallback: 'PAYMENT_FAILED'),
        e.message,
      );
    }
    final sent = (res['amount_sent_msat'] as num?)?.toInt() ?? 0;
    final amount = (res['amount_msat'] as num?)?.toInt() ?? 0;
    return {
      'preimage': '${res['payment_preimage'] ?? ''}',
      // Fee = inviato − richiesto (amount_sent_msat include le fee).
      'fees_paid': sent > amount ? sent - amount : 0,
    };
  }

  /// Nuovo indirizzo on-chain del nodo (deposito) — spec dln `make_new_address`.
  ///
  /// Params opzionali: `address_type` = `bech32` (default) | `p2tr`.
  /// // PERCHÉ (I3b): il fork accetta `newaddr bech32|p2tr|all` — così l'utente
  /// può ricevere su taproot senza passare da RTL.
  Future<Map<String, dynamic>> _makeNewAddress(
    Map<String, dynamic> params,
  ) async {
    // PERCHÉ (NIP-XX): il campo spec è `type` ("p2wpkh" | "p2tr" | …);
    // `address_type` resta accettato dalle app non aggiornate. `p2wpkh` è il
    // nome spec del nostro storico `bech32` (CLN: `newaddr bech32`).
    final requested = '${params['type'] ?? params['address_type'] ?? 'bech32'}';
    if (requested != 'p2wpkh' && requested != 'bech32' && requested != 'p2tr') {
      throw RpcError(
        'BAD_REQUEST',
        'make_new_address: tipo non supportato "$requested" '
            '(p2wpkh|bech32|p2tr)',
      );
    }
    final type = requested == 'p2tr' ? 'p2tr' : 'bech32';
    final res = await cln.call('newaddr', {'addresstype': type});
    final address = type == 'p2tr' ? res['p2tr'] : res['bech32'];
    if (address == null) {
      throw const RpcError(
        'INTERNAL',
        'newaddr non ha restituito un indirizzo',
      );
    }
    return {'address': '$address', 'type': type};
  }

  /// Invio on-chain dal nodo — spec dln `pay_onchain` → CLN `withdraw`.
  ///
  /// Contratto params (nostro, documentato):
  /// - `address` (string, obbligatorio)
  /// - `amount_sat` (int, satoshi) — assente = invio di TUTTO
  /// - `feerate` (string opzionale, es. `500perkw`)
  ///
  /// // PERCHÉ futuro-proof dln: se arriva `amount` (msat, convenzione NIP-47)
  /// lo converto, così la stessa API regge entrambi i nodi.
  Future<Map<String, dynamic>> _payOnchain(
    Map<String, dynamic> params,
  ) async {
    final address = '${params['address'] ?? ''}';
    if (address.isEmpty) {
      throw const RpcError('BAD_REQUEST', 'pay_onchain richiede address');
    }
    // PERCHÉ (NIP-XX nwc-units/nwc-onchain): il nome spec è `amount_sats`;
    // `amount_sat` (nostro storico) e `amount` (msat, convenzione NIP-47)
    // restano accettati per retro-compatibilità.
    int? amountSats = (params['amount_sats'] as num?)?.toInt() ??
        (params['amount_sat'] as num?)?.toInt();
    if (amountSats == null && params['amount'] is num) {
      // PERCHÉ: `amount` nella convenzione NIP-47 è in msat.
      amountSats = (params['amount'] as num).toInt() ~/ 1000;
    }
    // PERCHÉ (NIP-XX nwc-onchain): `feerate` è in sat/vB (numero); la stringa
    // CLN legacy (`500perkw`) resta accettata. 1 sat/vB = 250 sat/kw.
    final rawFeerate = params['feerate'];
    final String? feerate = switch (rawFeerate) {
      final num n when n > 0 => '${(n * 250).round()}perkw',
      final String s when s.isNotEmpty => s,
      _ => null,
    };
    _logger.info('pay_onchain: $address, ${amountSats ?? 'ALL'} sat');
    final Map<String, dynamic> res;
    try {
      res = await cln.call('withdraw', {
        'destination': address,
        if (amountSats != null) 'satoshi': '$amountSats' else 'all': true,
        if (feerate != null) 'feerate': feerate,
      });
    } on RpcError catch (e) {
      throw RpcError(
        classifyClnFailure(e.message, fallback: 'PAYMENT_FAILED'),
        e.message,
      );
    }
    final txid = res['txid'];
    if (txid == null) {
      throw const RpcError('OTHER', 'withdraw non ha restituito un txid');
    }
    return {'txid': '$txid'};
  }

  /// Stime fee on-chain (spec dln `estimate_onchain_fees`).
  ///
  /// // PERCHÉ: dln dichiara il metodo ma risponde "not yet implemented" —
  /// qui lo implementiamo mappando `feerates` (perkb = sat/1000B) su tre
  /// livelli in sat/vB. Shape provvisoria finché dln non la stabilizza.
  Future<Map<String, dynamic>> _estimateOnchainFees() async {
    final res = await cln.call('feerates', {'style': 'perkb'});
    final perkb = (res['perkb'] as Map?)?.cast<String, dynamic>() ?? const {};
    int satVb(Object? v) {
      final n = (v as num?)?.toDouble();
      if (n == null) return 1;
      return max(1, (n / 1000).round());
    }

    return {
      'min': satVb(perkb['min_acceptable']),
      'economical': satVb(perkb['opening']),
      'priority': satVb(perkb['unilateral_close']),
    };
  }

  /// Indirizzi on-chain del nodo (spec dln `list_addresses`).
  ///
  /// // PERCHÉ: `listaddresses` non esiste su tutte le build CLN (nodo di test
  /// `.2`): su errore ricado su `listfunds`, che copre gli indirizzi con fondi.
  Future<Map<String, dynamic>> _listAddresses() async {
    try {
      final res = await cln.call('listaddresses');
      // PERCHÉ (I3b, verificato sul nodo): `listaddresses` risponde
      // `{addresses: [{keyidx, bech32}]}` — NON esiste il campo `address` né
      // un flag `used`: l'utilizzo va dedotto dagli output in `listfunds`.
      final funded = await _fundedAddresses();
      final out = <Map<String, dynamic>>[];
      for (final a in (res['addresses'] as List? ?? const [])) {
        final e = (a as Map).cast<String, dynamic>();
        final bech32 = e['bech32']?.toString();
        final p2tr = e['p2tr']?.toString();
        final address = bech32 ?? p2tr ?? e['address']?.toString() ?? '';
        if (address.isEmpty) continue;
        out.add({
          'address': address,
          'type': bech32 != null ? 'bech32' : (p2tr != null ? 'p2tr' : ''),
          if (e['keyidx'] != null) 'keyidx': e['keyidx'],
          'has_funds': funded.contains(address),
        });
      }
      return {'addresses': out};
    } on RpcError catch (e) {
      _logger.warn(
        'listaddresses non disponibile (${e.message}): fallback su listfunds',
      );
      final res = await cln.call('listfunds');
      final out = <Map<String, dynamic>>[];
      for (final o in (res['outputs'] as List? ?? const [])) {
        final f = (o as Map).cast<String, dynamic>();
        if (f['address'] == null) continue;
        out.add({
          'address': '${f['address']}',
          if (f['amount_msat'] != null) 'amount_msat': f['amount_msat'],
          if (f['status'] != null) 'status': f['status'],
        });
      }
      return {'addresses': out};
    }
  }

  /// Indirizzi che oggi detengono fondi (da `listfunds.outputs`).
  ///
  /// // PERCHÉ: CLN non espone "indirizzo usato" — l'unico segnale reale è
  /// "questo indirizzo ha output non spesi". Etichetta UI: "con saldo".
  Future<Set<String>> _fundedAddresses() async {
    try {
      final funds = await cln.call('listfunds');
      return {
        for (final o in (funds['outputs'] as List? ?? const []))
          if ((o as Map)['address'] != null) '${o['address']}',
      };
    } on RpcError catch (e) {
      _logger.warn('listfunds non disponibile (${e.message})');
      return const {};
    }
  }

  /// UTXO on-chain del nodo (spec dln `list_utxos` → CLN `listfunds`).
  ///
  /// // PERCHÉ (I3b): l'utente deve vedere su quali output poggia il saldo
  /// on-chain e se uno è riservato a un'operazione in corso.
  Future<Map<String, dynamic>> _listUtxos() async {
    final res = await cln.call('listfunds');
    final out = <Map<String, dynamic>>[];
    for (final o in (res['outputs'] as List? ?? const [])) {
      final e = (o as Map).cast<String, dynamic>();
      out.add({
        'txid': '${e['txid'] ?? ''}',
        'vout': (e['output'] as num?)?.toInt() ?? 0,
        'amount_msat': (e['amount_msat'] as num?)?.toInt() ?? 0,
        if (e['address'] != null) 'address': '${e['address']}',
        'status': '${e['status'] ?? 'unknown'}',
        if (e['blockheight'] != null) 'blockheight': e['blockheight'],
        'reserved': e['reserved'] as bool? ?? false,
      });
    }
    return {'utxos': out};
  }

  /// Fatture del nodo (spec dln `list_invoices` → CLN `listinvoices`).
  ///
  /// // PERCHÉ (I3c): lo storico fatture dice se un pagamento è arrivato e
  /// quando scade l'invoice. `bolt11` è ESCLUSO dal payload (~300 byte per
  /// voce): la stringa si riusa dal flusso di ricezione.
  /// Params: `limit` (default 25, max 100), `offset` (default 0).
  Future<Map<String, dynamic>> _listInvoices(
    Map<String, dynamic> params,
  ) async {
    final res = await cln.call('listinvoices');
    final raw = (res['invoices'] as List? ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();

    // PERCHÉ: `created_index` è monotono sul nodo — le più recenti per prime.
    raw.sort((a, b) {
      final ia = (a['created_index'] as num?)?.toInt() ?? 0;
      final ib = (b['created_index'] as num?)?.toInt() ?? 0;
      return ib.compareTo(ia);
    });

    final rawLimit = (params['limit'] as num?)?.toInt() ?? 25;
    final limit = rawLimit < 1 ? 1 : (rawLimit > 100 ? 100 : rawLimit);
    final rawOffset = (params['offset'] as num?)?.toInt() ?? 0;
    final offset =
        rawOffset < 0 ? 0 : (rawOffset > raw.length ? raw.length : rawOffset);

    return {
      'invoices': [
        for (final e in raw.skip(offset).take(limit)) _mapInvoice(e),
      ],
      'total': raw.length,
    };
  }

  /// Singola fattura (spec dln `lookup_invoice` → `listinvoices` filtrato).
  ///
  /// Params: `payment_hash` oppure `label` (il flusso Ricevi usa il primo).
  Future<Map<String, dynamic>> _lookupInvoice(
    Map<String, dynamic> params,
  ) async {
    final hash = '${params['payment_hash'] ?? ''}'.trim();
    final label = '${params['label'] ?? ''}'.trim();
    if (hash.isEmpty && label.isEmpty) {
      throw const RpcError(
        'BAD_REQUEST',
        'lookup_invoice richiede payment_hash o label',
      );
    }
    final res = await cln.call('listinvoices', {
      if (hash.isNotEmpty) 'payment_hash': hash,
      if (hash.isEmpty) 'label': label,
    });
    final list = (res['invoices'] as List? ?? const []);
    if (list.isEmpty) {
      throw const RpcError('NOT_FOUND', 'fattura non trovata');
    }
    return _mapInvoice((list.first as Map).cast<String, dynamic>());
  }

  /// Pagamenti in uscita del nodo (spec dln `list_pays` → CLN `listpays`).
  ///
  /// La fee è calcolata qui (`amount_sent_msat − amount_msat`): l'app non deve
  /// conoscere le convenzioni del nodo.
  /// Params: `limit` (default 25, max 100), `offset` (default 0).
  Future<Map<String, dynamic>> _listPays(Map<String, dynamic> params) async {
    final res = await cln.call('listpays');
    final raw = (res['pays'] as List? ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();

    // Dal più recente: `created_index` è monotono sul nodo.
    raw.sort((a, b) {
      final ia = (a['created_index'] as num?)?.toInt() ?? 0;
      final ib = (b['created_index'] as num?)?.toInt() ?? 0;
      return ib.compareTo(ia);
    });

    final rawLimit = (params['limit'] as num?)?.toInt() ?? 25;
    final limit = rawLimit < 1 ? 1 : (rawLimit > 100 ? 100 : rawLimit);
    final rawOffset = (params['offset'] as num?)?.toInt() ?? 0;
    final offset =
        rawOffset < 0 ? 0 : (rawOffset > raw.length ? raw.length : rawOffset);

    return {
      'pays': [
        for (final e in raw.skip(offset).take(limit)) _mapPay(e),
      ],
      'total': raw.length,
    };
  }

  /// Mapping pagamento → payload app (fee inclusa, `bolt11`/preimage esclusi).
  static Map<String, dynamic> _mapPay(Map<String, dynamic> e) {
    final amount = (e['amount_msat'] as num?)?.toInt() ?? 0;
    final sent = (e['amount_sent_msat'] as num?)?.toInt() ?? amount;
    return {
      'payment_hash': '${e['payment_hash'] ?? ''}',
      if (e['destination'] != null) 'destination': '${e['destination']}',
      'amount_msat': amount,
      'amount_sent_msat': sent,
      'fee_msat': sent - amount,
      'status': '${e['status'] ?? 'unknown'}',
      if (e['created_at'] != null) 'created_at': e['created_at'],
      if (e['completed_at'] != null) 'completed_at': e['completed_at'],
      if (e['created_index'] != null) 'created_index': e['created_index'],
    };
  }

  /// HTLC del canale, con `pending` derivato dallo stato (spec dln
  /// `get_pending_htlcs` → CLN `listhtlcs`).
  ///
  /// // PERCHÉ: `listhtlcs` è in realtà uno STORICO (contiene anche gli HTLC
  /// risolti); lo stato "in corso" si riconosce dall'assenza di
  /// `ACK_REVOCATION`, che marca il completamento del ciclo (verificato sul
  /// nodo: un HTLC concluso riporta `RCVD_REMOVE_ACK_REVOCATION`).
  Future<Map<String, dynamic>> _getPendingHtlcs() async {
    final res = await cln.call('listhtlcs');
    final out = <Map<String, dynamic>>[];
    for (final h in (res['htlcs'] as List? ?? const [])) {
      final e = (h as Map).cast<String, dynamic>();
      final state = '${e['state'] ?? ''}';
      out.add({
        if (e['id'] != null) 'id': e['id'],
        if (e['short_channel_id'] != null)
          'short_channel_id': '${e['short_channel_id']}',
        'payment_hash': '${e['payment_hash'] ?? ''}',
        'amount_msat': (e['amount_msat'] as num?)?.toInt() ?? 0,
        if (e['direction'] != null) 'direction': '${e['direction']}',
        'state': state,
        if (e['expiry'] != null) 'expiry': e['expiry'],
        'pending': !state.contains('ACK_REVOCATION'),
      });
    }
    return {'htlcs': out};
  }

  /// Pagamento a un nodo senza invoice (spec dln `keysend` → plugin CLN).
  ///
  /// // PERCHÉ (I3e): è una SCRITTURA che muove fondi subito. Dal man del nodo:
  /// `maxfee` prevale su `maxfeepercent` (non si possono passare entrambi) e
  /// `retry_for` limita i tentativi. La forma della risposta del plugin non è
  /// ancora stata osservata (mai eseguito un keysend reale): il mapping riusa
  /// quello di `pay` — `payment_hash`, `amount_sent_msat`, `status` — e tratta
  /// preimage e fee come opzionali.
  Future<Map<String, dynamic>> _keysend(Map<String, dynamic> params) async {
    final destination = '${params['destination'] ?? ''}'.trim();
    final amount = (params['amount_msat'] as num?)?.toInt();
    if (destination.isEmpty || amount == null || amount <= 0) {
      throw const RpcError(
        'BAD_REQUEST',
        'keysend richiede destination e amount_msat positivi',
      );
    }
    final label = '${params['label'] ?? ''}'.trim();
    final maxFee = (params['maxfee_msat'] as num?)?.toInt();
    final maxFeePercent = (params['maxfeepercent'] as num?)?.toDouble();
    final retryFor = (params['retry_for'] as num?)?.toInt();

    final Map<String, dynamic> res;
    try {
      res = await cln.call('keysend', {
        'destination': destination,
        'amount_msat': amount,
        if (label.isNotEmpty) 'label': label,
        if (maxFee != null) 'maxfee': maxFee,
        if (maxFee == null && maxFeePercent != null)
          'maxfeepercent': maxFeePercent,
        if (retryFor != null) 'retry_for': retryFor,
      });
    } on RpcError catch (e) {
      throw RpcError(
        classifyClnFailure(e.message, fallback: 'PAYMENT_FAILED'),
        e.message,
      );
    }
    final mapped = _mapPay(res);
    _logger.info(
      'keysend: ${_shortId(destination)} amount=$amount '
      'fee=${mapped['fee_msat']} status=${mapped['status']}',
    );
    return {
      ...mapped,
      'destination': '${res['destination'] ?? destination}',
      if (res['payment_preimage'] != null)
        'payment_preimage': '${res['payment_preimage']}',
    };
  }

  /// Taglio del node id per i log (mai l'id intero: rumore).
  static String _shortId(String id) =>
      id.length <= 12 ? id : '${id.substring(0, 12)}…';

  /// Mapping invoice → payload app.
  ///
  /// // PERCHÉ: `paid_at`/`amount_received_msat` esistono solo sulle fatture
  /// pagate (e sul nodo attuale non ce ne sono ancora): restano additivi.
  static Map<String, dynamic> _mapInvoice(Map<String, dynamic> e) => {
        'payment_hash': '${e['payment_hash'] ?? ''}',
        'label': '${e['label'] ?? ''}',
        if (e['description'] != null) 'description': '${e['description']}',
        'amount_msat': (e['amount_msat'] as num?)?.toInt() ?? 0,
        'status': '${e['status'] ?? 'unknown'}',
        if (e['expires_at'] != null) 'expires_at': e['expires_at'],
        if (e['created_index'] != null) 'created_index': e['created_index'],
        if (e['paid_at'] != null) 'paid_at': e['paid_at'],
        if (e['amount_received_msat'] != null)
          'amount_received_msat': e['amount_received_msat'],
      };

  /// Policy di routing del canale (spec dln `get_channel_fees`).
  ///
  /// // PERCHÉ: base/ppm sono annunciati alla rete, htlc min/max limitano ciò
  /// che il canale accetta di instradare, cltv è il delta di scadenza che
  /// pubblichiamo. Solo la lettura: `setchannel` NON ha un parametro cltv.
  Future<Map<String, dynamic>> _getChannelFees(
    Map<String, dynamic> params,
  ) async {
    final id = '${params['id'] ?? ''}'.trim();
    if (id.isEmpty) {
      throw const RpcError('BAD_REQUEST', 'get_channel_fees richiede id');
    }
    final res = await cln.call('listpeerchannels');
    for (final c in (res['channels'] as List? ?? const [])) {
      final ch = (c as Map).cast<String, dynamic>();
      final channelId = '${ch['channel_id'] ?? ''}';
      final scid = '${ch['short_channel_id'] ?? ''}';
      if (channelId != id && scid != id && '${ch['peer_id']}' != id) continue;

      // I nostri valori annunciati stanno in `updates.local` (verificato sul
      // nodo); base/ppm esistono anche a livello di canale → fallback.
      final local = ((ch['updates'] as Map?)?['local'] as Map?)
              ?.cast<String, dynamic>() ??
          const <String, dynamic>{};
      int? pick(String key, String fallbackKey) =>
          (local[key] as num?)?.toInt() ?? (ch[fallbackKey] as num?)?.toInt();

      return {
        'id': channelId,
        if (scid.isNotEmpty) 'short_channel_id': scid,
        'fee_base_msat': pick('fee_base_msat', 'fee_base_msat') ?? 0,
        'fee_proportional_millionths': pick(
              'fee_proportional_millionths',
              'fee_proportional_millionths',
            ) ??
            0,
        if (pick('htlc_minimum_msat', 'minimum_htlc_in_msat') != null)
          'htlc_min_msat': pick('htlc_minimum_msat', 'minimum_htlc_in_msat'),
        if (pick('htlc_maximum_msat', 'maximum_htlc_out_msat') != null)
          'htlc_max_msat': pick('htlc_maximum_msat', 'maximum_htlc_out_msat'),
        if (local['cltv_expiry_delta'] != null)
          'cltv_delta': local['cltv_expiry_delta'],
        if (ch['our_reserve_msat'] != null)
          'our_reserve_msat': ch['our_reserve_msat'],
        if (ch['their_reserve_msat'] != null)
          'their_reserve_msat': ch['their_reserve_msat'],
        if (ch['our_to_self_delay'] != null)
          'to_self_delay': ch['our_to_self_delay'],
      };
    }
    throw const RpcError('NOT_FOUND', 'canale non trovato');
  }

  /// Aggiorna la policy di routing (spec dln `set_channel_fees` → `setchannel`).
  ///
  /// Params: `id` (obbligatorio) + almeno uno fra `base_msat`, `ppm`,
  /// `htlc_min_msat`, `htlc_max_msat`, `enforce_delay` (secondi).
  /// Valori in msat (unità CLN); ritorna la policy aggiornata rileggendola.
  Future<Map<String, dynamic>> _setChannelFees(
    Map<String, dynamic> params,
  ) async {
    final id = '${params['id'] ?? ''}'.trim();
    if (id.isEmpty) {
      throw const RpcError('BAD_REQUEST', 'set_channel_fees richiede id');
    }
    final base = (params['base_msat'] as num?)?.toInt();
    final ppm = (params['ppm'] as num?)?.toInt();
    final htlcMin = (params['htlc_min_msat'] as num?)?.toInt();
    final htlcMax = (params['htlc_max_msat'] as num?)?.toInt();
    final enforceDelay = (params['enforce_delay'] as num?)?.toInt();
    if (base == null && ppm == null && htlcMin == null && htlcMax == null) {
      throw const RpcError(
        'BAD_REQUEST',
        'set_channel_fees richiede almeno un valore (base_msat, ppm, htlc_min_msat, htlc_max_msat)',
      );
    }

    final Map<String, dynamic> res;
    try {
      res = await cln.call('setchannel', {
        'id': id,
        if (base != null) 'feebase': base,
        if (ppm != null) 'feeppm': ppm,
        if (htlcMin != null) 'htlcmin': htlcMin,
        if (htlcMax != null) 'htlcmax': htlcMax,
        if (enforceDelay != null) 'enforcedelay': enforceDelay,
      });
    } on RpcError catch (e) {
      throw RpcError(
        classifyClnFailure(e.message, fallback: 'NOT_FOUND'),
        e.message,
      );
    }
    _logger.info(
      'set_channel_fees: $id (base=$base ppm=$ppm min=$htlcMin max=$htlcMax)',
    );

    final updated = await _getChannelFees({'id': id});
    // PERCHÉ: `setchannel` può rispondere con un avviso (es. htlcmin alzato dal
    // peer): va portato all'utente invece di essere nascosto.
    if (res['warning'] != null) {
      updated['warning'] = '${res['warning']}';
    }
    return updated;
  }

  // ── NCC ─────────────────────────────────────────────────────────────────────

  /// Movimenti del nodo → lista unificata per l'app (fonte: `bkpr`).
  ///
  /// // PERCHÉ (I3): `bkpr-listaccountevents` è l'unica fonte che copre on-chain
  /// E Lightning con importi netti e categorie stabili (deposit, withdrawal,
  /// channel_open, invoice, onchain_fee): una sola lista per l'utente.
  /// Params: `limit` (default 50, max 200), `offset` (default 0).
  Future<Map<String, dynamic>> _listTransactions(
    Map<String, dynamic> params,
  ) async {
    final res = await cln.call('bkpr-listaccountevents');
    final raw = (res['events'] as List? ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();

    // PERCHÉ: ordino dal più recente — la paginazione dev'essere stabile.
    raw.sort((a, b) {
      final ta = (a['timestamp'] as num?)?.toInt() ?? 0;
      final tb = (b['timestamp'] as num?)?.toInt() ?? 0;
      return tb.compareTo(ta);
    });

    final rawLimit = (params['limit'] as num?)?.toInt() ?? 50;
    final limit = rawLimit < 1 ? 1 : (rawLimit > 200 ? 200 : rawLimit);
    final rawOffset = (params['offset'] as num?)?.toInt() ?? 0;
    final offset =
        rawOffset < 0 ? 0 : (rawOffset > raw.length ? raw.length : rawOffset);

    final out = <Map<String, dynamic>>[];
    var index = offset;
    for (final e in raw.skip(offset).take(limit)) {
      final credit = (e['credit_msat'] as num?)?.toInt() ?? 0;
      final debit = (e['debit_msat'] as num?)?.toInt() ?? 0;
      final type = _movementType('${e['tag'] ?? ''}');
      // PERCHÉ (verificato sul nodo): bkpr registra credit/debit dal punto di
      // vista del CONTO, non del portafoglio — l'apertura di un canale
      // accredita il canale (sembrerebbe "in") ma per l'utente i fondi ESCONO.
      // Il verso dei movimenti strutturali lo decide quindi il tag; per gli
      // altri (deposit, withdrawal, invoice, routed) vale credit/debit.
      final bool incoming;
      if (type == 'channel_open' || type == 'onchain_fee') {
        incoming = false;
      } else if (type == 'channel_close') {
        incoming = true;
      } else {
        incoming = credit > 0;
      }
      out.add({
        'id': '${e['timestamp'] ?? 0}-$index',
        'type': type,
        'direction': incoming ? 'in' : 'out',
        'amount_msat': credit > 0 ? credit : debit,
        'timestamp': (e['timestamp'] as num?)?.toInt() ?? 0,
        if (e['blockheight'] != null) 'blockheight': e['blockheight'],
        if (e['outpoint'] != null) 'outpoint': '${e['outpoint']}',
        if (e['description'] != null) 'description': '${e['description']}',
      });
      index++;
    }
    return {'transactions': out, 'total': raw.length};
  }

  /// Tag bkpr → categoria stabile per la UI (`other` = mai un errore).
  static String _movementType(String tag) {
    switch (tag) {
      case 'deposit':
        return 'deposit';
      case 'withdrawal':
        return 'withdrawal';
      case 'channel_open':
        return 'channel_open';
      case 'channel_close':
        return 'channel_close';
      case 'invoice':
        return 'invoice';
      case 'onchain_fee':
        return 'onchain_fee';
      case 'routed':
      case 'forward':
        return 'forward';
      default:
        return 'other';
    }
  }

  /// Mapping `listpeerchannels` (CLN) → LdkChannelInfo + arricchimenti (I2).
  /// Unità: TUTTI i saldi in msat (convenzione NWC/LDK); la UI divide per 1000.
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
        // NOTA (I2): NON si espone `ch['alias']` — su CLN è l'oggetto degli
        // **scid alias** (`{local, remote}`, es. "111x1x1"), non il nome del
        // peer: mostrarlo nella UI sembrerebbe spazzatura. Il nome vero sta in
        // `listnodes[].alias`, che il nodo compila solo per i peer annunciati
        // presenti nel gossip store (verificato sul nodo reale: 0 risultati).
        // L'app gestisce l'alias assente mostrando la pubkey abbreviata.
        if (ch['fee_base_msat'] != null) 'fee_base_msat': ch['fee_base_msat'],
        if (ch['fee_proportional_millionths'] != null)
          'fee_proportional_millionths': ch['fee_proportional_millionths'],
        if (ch['spendable_msat'] != null)
          'spendable_msat': ch['spendable_msat'],
        if (ch['receivable_msat'] != null)
          'receivable_msat': ch['receivable_msat'],
        if (ch['peer_connected'] != null)
          'peer_connected': ch['peer_connected'],
        if (ch['status'] != null) 'status': ch['status'],
        'htlc_count': (ch['htlcs'] as List?)?.length ?? 0,
      });
    }
    return {'channels': out};
  }

  Future<Map<String, dynamic>> _openChannel(
    Map<String, dynamic> params,
  ) async {
    final pubkey = '${params['pubkey'] ?? ''}';
    // PERCHÉ (NIP-XX nwc-units): `amount_sats` è il nome spec; `amount` resta
    // accettato dalle app non ancora aggiornate.
    final amount = (params['amount_sats'] as num?)?.toInt() ??
        (params['amount'] as num?)?.toInt();
    final host = params['host'] as String?;
    final isPrivate = params['private'] as bool? ?? false;
    if (pubkey.isEmpty || amount == null || amount <= 0) {
      throw const RpcError(
        'BAD_REQUEST',
        'open_channel richiede pubkey e amount_sats (sat)',
      );
    }
    // PERCHÉ: se il client fornisce l'host, il bridge fa anche il connect —
    // l'app non deve conoscere lo stato dei peer del nodo.
    if (host != null && host.isNotEmpty) {
      try {
        await cln.call('connect', {'id': '$pubkey@$host'});
      } on RpcError catch (e) {
        throw RpcError(
          classifyClnFailure(e.message, fallback: 'CONNECTION_FAILED'),
          e.message,
        );
      }
    }
    _logger.info(
      'open_channel: $pubkey, $amount sat (private=$isPrivate)',
    );
    final Map<String, dynamic> res;
    try {
      res = await cln.call('fundchannel', {
        'id': pubkey,
        'amount': '$amount',
        'announce': !isPrivate,
      });
    } on RpcError catch (e) {
      throw RpcError(
        classifyClnFailure(e.message, fallback: 'CHANNEL_FAILED'),
        e.message,
      );
    }
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
      throw const RpcError('BAD_REQUEST', 'close_channel richiede id');
    }
    final Map<String, dynamic> res;
    try {
      res = await cln.call('close', {
        'id': id,
        // PERCHÉ: unilateraltimeout=0 = chiusura forzata immediata (force).
        if (force) 'unilateraltimeout': 0,
      });
    } on RpcError catch (e) {
      throw RpcError(
        classifyClnFailure(e.message, fallback: 'CHANNEL_FAILED'),
        e.message,
      );
    }
    return {
      if (res['tx'] != null) 'txid': res['tx'],
      if (res['txid'] != null) 'txid': res['txid'],
    };
  }

  /// Peer del nodo (spec dln NCC `list_peers` → CLN `listpeers`).
  ///
  /// NOTA (I2): nessun `alias`. `listpeers` non lo espone e l'unica altra
  /// fonte (`listpeerchannels[].alias`) è l'oggetto degli scid alias: sul nodo
  /// reale `listnodes` ritorna 0 nodi (gossip store vuoto), quindi l'alias non
  /// è disponibile e l'app mostra la pubkey abbreviata.
  Future<Map<String, dynamic>> _listPeers() async {
    final res = await cln.call('listpeers');
    final out = <Map<String, dynamic>>[];
    for (final p in (res['peers'] as List? ?? const [])) {
      final peer = (p as Map).cast<String, dynamic>();
      final id = '${peer['id'] ?? ''}';
      final addresses =
          (peer['netaddr'] as List? ?? const []).map((a) => '$a').toList();
      out.add({
        'id': id,
        // PERCHÉ (NIP-XX): `pubkey`/`address` sono i nomi spec — emessi in
        // aggiunta ai nostri, così un client conforme legge lo stesso evento
        // senza rompere le app già installate.
        'pubkey': id,
        if (addresses.isNotEmpty) 'address': addresses.first,
        'connected': peer['connected'] as bool? ?? false,
        'num_channels': (peer['num_channels'] as num?)?.toInt() ?? 0,
        'addresses': addresses,
        if (peer['remote_addr'] != null) 'remote_addr': peer['remote_addr'],
      });
    }
    return {'peers': out};
  }

  /// Connessione a un peer (spec dln NCC `connect_peer` → CLN `connect`).
  ///
  /// Contratto params: `id` (o `pubkey`), `host?`, `port?`; accetta anche la
  /// forma compatta `pubkey@host:porta` nel campo id (come la UI dell'app).
  Future<Map<String, dynamic>> _connectPeer(
    Map<String, dynamic> params,
  ) async {
    var id = '${params['id'] ?? params['pubkey'] ?? ''}'.trim();
    var host = '${params['host'] ?? ''}'.trim();
    int? port = (params['port'] as num?)?.toInt();
    if (id.contains('@')) {
      final parts = id.split('@');
      id = parts.first;
      final rest = parts.sublist(1).join('@');
      final colon = rest.lastIndexOf(':');
      if (colon > 0) {
        host = rest.substring(0, colon);
        port ??= int.tryParse(rest.substring(colon + 1));
      } else {
        host = rest;
      }
    }
    if (id.isEmpty) {
      throw const RpcError(
        'BAD_REQUEST',
        'connect_peer richiede id (pubkey)',
      );
    }
    _logger.info('connect_peer: $id${host.isEmpty ? '' : ' @ $host'}');
    final Map<String, dynamic> res;
    try {
      res = await cln.call('connect', {
        'id': id,
        if (host.isNotEmpty) 'host': host,
        if (port != null) 'port': port,
      });
    } on RpcError catch (e) {
      throw RpcError(
        classifyClnFailure(e.message, fallback: 'CONNECTION_FAILED'),
        e.message,
      );
    }
    return {'id': '${res['id'] ?? id}'};
  }

  /// Disconnessione da un peer (spec dln NCC `disconnect_peer` → `disconnect`).
  Future<Map<String, dynamic>> _disconnectPeer(
    Map<String, dynamic> params,
  ) async {
    final id = '${params['id'] ?? params['pubkey'] ?? ''}'.trim();
    if (id.isEmpty) {
      throw const RpcError(
        'BAD_REQUEST',
        'disconnect_peer richiede id (pubkey)',
      );
    }
    final force = params['force'] as bool? ?? false;
    _logger.info('disconnect_peer: $id (force=$force)');
    try {
      await cln.call('disconnect', {
        'id': id,
        if (force) 'force': true,
      });
    } on RpcError catch (e) {
      throw RpcError(
        classifyClnFailure(e.message, fallback: 'NOT_FOUND'),
        e.message,
      );
    }
    return {'id': id};
  }

  /// Economia del nodo e stato dei plugin (spec dln `get_node_stats`).
  ///
  /// // PERCHÉ (I3e): `bkpr-listincome` è l'unica fonte che dice se il nodo
  /// guadagna o perde — depositi, spese on-chain, pagamenti, fee di routing —
  /// con tag che cambiano nel tempo: il bridge li aggrega senza ipotesi e
  /// lascia all'app l'etichetta (tag ignoti inclusi).
  Future<Map<String, dynamic>> _getNodeStats() async {
    final income = await cln.call('bkpr-listincome');
    final events = (income['income_events'] as List? ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();

    var credits = 0;
    var debits = 0;
    final byTag = <String, Map<String, dynamic>>{};
    for (final e in events) {
      final credit = (e['credit_msat'] as num?)?.toInt() ?? 0;
      final debit = (e['debit_msat'] as num?)?.toInt() ?? 0;
      credits += credit;
      debits += debit;
      final tag = '${e['tag'] ?? 'unknown'}'.trim().isEmpty
          ? 'unknown'
          : '${e['tag']}'.trim();
      final slot = byTag.putIfAbsent(
        tag,
        () => {
          'tag': tag,
          'credit_msat': 0,
          'debit_msat': 0,
          'entries': 0,
        },
      );
      slot['credit_msat'] = (slot['credit_msat'] as int) + credit;
      slot['debit_msat'] = (slot['debit_msat'] as int) + debit;
      slot['entries'] = (slot['entries'] as int) + 1;
    }
    // I tag più "pesanti" (netto assoluto) per primi: la UI mostra poche righe.
    final tags = byTag.values.toList()
      ..sort((a, b) {
        final netA =
            ((a['credit_msat'] as int) - (a['debit_msat'] as int)).abs();
        final netB =
            ((b['credit_msat'] as int) - (b['debit_msat'] as int)).abs();
        return netB.compareTo(netA);
      });

    // PERCHÉ: plugin e forwarding sono contorno alle statistiche economiche —
    // se il comando non risponde il resto delle statistiche resta utile.
    var plugins = <Map<String, dynamic>>[];
    try {
      final res = await cln.call('plugin', {'subcommand': 'list'});
      plugins = [
        for (final p in (res['plugins'] as List? ?? const []))
          _mapPlugin((p as Map).cast<String, dynamic>()),
      ];
    } on RpcError catch (e) {
      _logger
          .warn('get_node_stats: plugin list non disponibile (${e.message})');
    }

    var forwardCount = 0;
    try {
      final res = await cln.call('listforwards');
      forwardCount = (res['forwards'] as List? ?? const []).length;
    } on RpcError catch (e) {
      _logger
          .warn('get_node_stats: listforwards non disponibile (${e.message})');
    }

    return {
      'net_msat': credits - debits,
      'credits_msat': credits,
      'debits_msat': debits,
      'tags': tags,
      'plugins': plugins,
      'forward_count': forwardCount,
    };
  }

  /// Plugin → payload app: nome corto (basename) e stato.
  static Map<String, dynamic> _mapPlugin(Map<String, dynamic> p) {
    final path = '${p['name'] ?? ''}';
    final name = path.contains('/') ? path.split('/').last : path;
    return {
      'name': name,
      'active': p['active'] as bool? ?? false,
      'dynamic': p['dynamic'] as bool? ?? false,
    };
  }

  /// Forwarding del nodo (spec dln `list_forwards` → CLN `listforwards`).
  ///
  /// ⚠️ I campi dell'elemento NON sono ancora stati osservati (sul nodo non è
  /// mai passato un forward): mapping difensivo, `fee_msat` solo se il nodo lo
  /// riporta (i forward non risolti non hanno ancora una fee).
  /// Params: `limit` (default 25, max 100), `offset` (default 0).
  Future<Map<String, dynamic>> _listForwards(
    Map<String, dynamic> params,
  ) async {
    final res = await cln.call('listforwards');
    final raw = (res['forwards'] as List? ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();

    // Dal più recente: `received_time` è l'istante di arrivo (secondi).
    raw.sort((a, b) {
      final ta = (a['received_time'] as num?)?.toInt() ?? 0;
      final tb = (b['received_time'] as num?)?.toInt() ?? 0;
      return tb.compareTo(ta);
    });

    // PERCHÉ (NIP-XX get_forwarding_history): `from`/`until` sono finestre
    // temporali inclusive in secondi su `received_time`; il filtro è locale
    // perché `listforwards` di CLN non le accetta.
    final from = (params['from'] as num?)?.toInt();
    final until = (params['until'] as num?)?.toInt();
    final filtered = raw.where((e) {
      final t = (e['received_time'] as num?)?.toInt() ?? 0;
      if (from != null && t < from) return false;
      if (until != null && t > until) return false;
      return true;
    }).toList();

    final rawLimit = (params['limit'] as num?)?.toInt() ?? 25;
    final limit = rawLimit < 1 ? 1 : (rawLimit > 100 ? 100 : rawLimit);
    final rawOffset = (params['offset'] as num?)?.toInt() ?? 0;
    final offset = rawOffset < 0
        ? 0
        : (rawOffset > filtered.length ? filtered.length : rawOffset);

    return {
      'forwards': [
        for (final e in filtered.skip(offset).take(limit)) _mapForward(e),
      ],
      'total': filtered.length,
    };
  }

  static Map<String, dynamic> _mapForward(Map<String, dynamic> e) => {
        // PERCHÉ (NIP-XX): nomi campo spec di `get_forwarding_history`
        // accanto ai nostri: nessuno rimosso, i client spec-li leggono i
        // primi, le app installate i secondi.
        if (e['in_channel'] != null) 'in_channel': '${e['in_channel']}',
        if (e['in_channel'] != null)
          'incoming_channel_id': '${e['in_channel']}',
        if (e['out_channel'] != null) 'out_channel': '${e['out_channel']}',
        if (e['out_channel'] != null)
          'outgoing_channel_id': '${e['out_channel']}',
        'in_msat': (e['in_msat'] as num?)?.toInt() ?? 0,
        'incoming_amount': (e['in_msat'] as num?)?.toInt() ?? 0,
        'out_msat': (e['out_msat'] as num?)?.toInt() ?? 0,
        'outgoing_amount': (e['out_msat'] as num?)?.toInt() ?? 0,
        if (e['fee_msat'] != null)
          'fee_msat': (e['fee_msat'] as num?)?.toInt() ?? 0,
        if (e['fee_msat'] != null)
          'fee_earned': (e['fee_msat'] as num?)?.toInt() ?? 0,
        'status': '${e['status'] ?? 'unknown'}',
        if (e['received_time'] != null) 'received_time': e['received_time'],
        if (e['resolved_time'] != null) 'resolved_time': e['resolved_time'],
        if (e['resolved_time'] != null) 'settled_at': e['resolved_time'],
      };

  /// Info sul nodo di rete (spec dln `get_node_info` → CLN `listnodes`).
  ///
  /// // PERCHÉ: SEMPRE con `node_id` esplicito — `listnodes` senza argomento
  /// restituisce tutto il gossip e non è mai quello che serve all'app.
  Future<Map<String, dynamic>> _getNodeInfo(
    Map<String, dynamic> params,
  ) async {
    // PERCHÉ (NIP-XX get_network_node): `pubkey` è il nome spec del parametro;
    // `node_id`/`id` restano accettati dalle app non ancora aggiornate.
    final nodeId =
        '${params['pubkey'] ?? params['node_id'] ?? params['id'] ?? ''}'.trim();
    if (nodeId.isEmpty) {
      throw const RpcError(
        'BAD_REQUEST',
        'get_network_node richiede pubkey',
      );
    }
    final res = await cln.call('listnodes', {'id': nodeId});
    for (final n in (res['nodes'] as List? ?? const [])) {
      final node = (n as Map).cast<String, dynamic>();
      return {
        'node_id': '${node['nodeid'] ?? nodeId}',
        // PERCHÉ (NIP-XX): alias spec dello stesso valore.
        'pubkey': '${node['nodeid'] ?? nodeId}',
        if (node['alias'] != null) 'alias': '${node['alias']}',
        if (node['color'] != null) 'color': '${node['color']}',
        if (node['last_timestamp'] != null)
          'last_timestamp': node['last_timestamp'],
        if (node['features'] != null) 'features': '${node['features']}',
        'addresses': [
          for (final a in (node['addresses'] as List? ?? const []))
            _mapNodeAddress((a as Map).cast<String, dynamic>()),
        ],
      };
    }
    throw RpcError('NOT_FOUND', 'Nodo non trovato: $nodeId');
  }

  static Map<String, dynamic> _mapNodeAddress(Map<String, dynamic> a) => {
        if (a['type'] != null) 'type': '${a['type']}',
        if (a['address'] != null) 'address': '${a['address']}',
        if (a['port'] != null) 'port': a['port'],
      };

  /// Percorso verso una destinazione (spec dln `get_route` → CLN `getroute`).
  ///
  /// // PERCHÉ: il primo hop porta l'importo MAGGIORATO delle fee di tutta la
  /// rotta: `fee_msat` = amount del primo hop − amount richiesto (0 quando la
  /// destinazione è un nostro peer diretto). `total_delay` è il CLTV chiesto
  /// al primo hop.
  Future<Map<String, dynamic>> _getRoute(
    Map<String, dynamic> params,
  ) async {
    final destination = '${params['destination'] ?? ''}'.trim();
    // PERCHÉ (NIP-XX query_routes): `amount` è il nome spec (msat, senza
    // suffisso — regola nwc-units); `amount_msat` resta accettato. `max_routes`
    // è accettato ma CLN `getroute` restituisce una sola rotta: valori > 1 non
    // sono implementabili senza cambiare il motore.
    final amount = (params['amount'] as num?)?.toInt() ??
        (params['amount_msat'] as num?)?.toInt();
    if (destination.isEmpty || amount == null || amount <= 0) {
      throw const RpcError(
        'BAD_REQUEST',
        'query_routes richiede destination e amount positivi (msat)',
      );
    }
    final risk = (params['risk_factor'] as num?)?.toInt() ?? 10;
    final Map<String, dynamic> res;
    try {
      res = await cln.call('getroute', {
        'id': destination,
        'amount_msat': amount,
        'riskfactor': risk,
      });
    } on RpcError catch (e) {
      throw RpcError(
        classifyClnFailure(e.message, fallback: 'NOT_FOUND'),
        e.message,
      );
    }

    final hops = [
      for (final h in (res['route'] as List? ?? const []))
        _mapRouteHop((h as Map).cast<String, dynamic>()),
    ];
    final firstAmount = hops.isEmpty ? null : hops.first['amount_msat'] as int;
    final firstDelay = hops.isEmpty ? null : hops.first['delay'] as int?;
    return {
      'route': hops,
      if (firstAmount != null) 'fee_msat': firstAmount - amount,
      if (firstDelay != null) 'total_delay': firstDelay,
    };
  }

  static Map<String, dynamic> _mapRouteHop(Map<String, dynamic> h) => {
        'id': '${h['id'] ?? ''}',
        if (h['channel'] != null) 'channel': '${h['channel']}',
        if (h['direction'] != null) 'direction': h['direction'],
        'amount_msat': (h['amount_msat'] as num?)?.toInt() ?? 0,
        if (h['delay'] != null) 'delay': (h['delay'] as num?)?.toInt(),
        if (h['style'] != null) 'style': '${h['style']}',
      };

  // ── Notifiche (I2) ─────────────────────────────────────────────────────────

  final Set<String> _seenPaidInvoices = <String>{};
  final Set<String> _seenCompletedPays = <String>{};
  final Map<String, String> _channelStates = <String, String>{};
  bool _notifyPrimed = false;

  /// Confronta lo stato del nodo con il giro precedente e ritorna i cambiamenti.
  ///
  /// // PERCHÉ: il primo giro "innesca" soltanto (nessuna notifica per lo
  /// storico); i giri successivi emettono solo i cambiamenti, deduplicati.
  Future<List<BridgeNotification>> pollNotifications() async {
    final notifications = <BridgeNotification>[];

    // 1) Pagamenti ricevuti (listinvoices → status paid)
    try {
      final res = await cln.call('listinvoices');
      for (final i in (res['invoices'] as List? ?? const [])) {
        final inv = (i as Map).cast<String, dynamic>();
        if ('${inv['status']}' != 'paid') continue;
        final hash = '${inv['payment_hash'] ?? ''}';
        if (hash.isEmpty || !_seenPaidInvoices.add(hash)) continue;
        if (_notifyPrimed) {
          notifications.add(
            BridgeNotification(
              type: 'payment_received',
              isNcc: false,
              payload: {
                'payment_hash': hash,
                'amount_msat': (inv['amount_received_msat'] as num?)?.toInt() ??
                    (inv['amount_msat'] as num?)?.toInt() ??
                    0,
                if (inv['label'] != null) 'description': inv['label'],
              },
            ),
          );
        }
      }
    } on RpcError catch (e) {
      _logger.warn('notifiche: listinvoices non disponibile (${e.message})');
    }

    // 2) Pagamenti inviati (listpays → status complete)
    try {
      final res = await cln.call('listpays');
      for (final p in (res['pays'] as List? ?? const [])) {
        final pay = (p as Map).cast<String, dynamic>();
        if ('${pay['status']}' != 'complete') continue;
        final hash = '${pay['payment_hash'] ?? ''}';
        if (hash.isEmpty || !_seenCompletedPays.add(hash)) continue;
        if (_notifyPrimed) {
          final sent = (pay['amount_sent_msat'] as num?)?.toInt() ?? 0;
          final amount = (pay['amount_msat'] as num?)?.toInt() ?? 0;
          notifications.add(
            BridgeNotification(
              type: 'payment_sent',
              isNcc: false,
              payload: {
                'payment_hash': hash,
                'amount_msat': amount,
                'fees_msat': sent > amount ? sent - amount : 0,
              },
            ),
          );
        }
      }
    } on RpcError catch (e) {
      _logger.warn('notifiche: listpays non disponibile (${e.message})');
    }

    // 3) Canali: comparsi → channel_opened, scomparsi/on-chain → closed
    try {
      final res = await cln.call('listpeerchannels');
      final current = <String, String>{};
      for (final c in (res['channels'] as List? ?? const [])) {
        final ch = (c as Map).cast<String, dynamic>();
        final id = '${ch['channel_id'] ?? ''}';
        if (id.isEmpty) continue;
        final state = '${ch['state'] ?? ''}';
        current[id] = state;
        if (_notifyPrimed && !_channelStates.containsKey(id)) {
          notifications.add(
            BridgeNotification(
              type: 'channel_opened',
              isNcc: true,
              payload: {
                'channel_id': id,
                'peer_pubkey': '${ch['peer_id'] ?? ''}',
                'capacity_msat': (ch['total_msat'] as num?)?.toInt() ?? 0,
              },
            ),
          );
        }
      }
      if (_notifyPrimed) {
        for (final entry in _channelStates.entries) {
          final gone = !current.containsKey(entry.key);
          final onchain = '${current[entry.key]}' == 'ONCHAIN';
          if (gone || onchain) {
            notifications.add(
              BridgeNotification(
                type: 'channel_closed',
                isNcc: true,
                payload: {'channel_id': entry.key, 'state': entry.value},
              ),
            );
          }
        }
      }
      _channelStates
        ..clear()
        ..addAll(current);
    } on RpcError catch (e) {
      _logger.warn(
        'notifiche: listpeerchannels non disponibile (${e.message})',
      );
    }

    _notifyPrimed = true;
    if (notifications.isNotEmpty) {
      _logger.info('notifiche: ${notifications.length} da pubblicare');
    }
    return notifications;
  }

  // ── Util ────────────────────────────────────────────────────────────────────

  /// Classifica un fallimento CLN in un codice d'errore NIP-XX.
  ///
  /// // PERCHÉ: ClnApi incapsula ogni errore del nodo in RpcError('OTHER',
  /// messaggio) — l'unico segnale disponibile è il testo. Il confronto è per
  /// sottostringa (case-insensitive) e senza riscontro si ricade su
  /// [fallback]: mai un codice inventato.
  static String classifyClnFailure(
    String message, {
    required String fallback,
  }) {
    final m = message.toLowerCase();
    if (m.contains('not found') ||
        m.contains('unknown channel') ||
        m.contains('no such') ||
        m.contains('does not exist')) {
      return 'NOT_FOUND';
    }
    if (m.contains('insufficient')) {
      return 'INSUFFICIENT_BALANCE';
    }
    if (m.contains('could not connect') ||
        m.contains('connection refused') ||
        m.contains('connection timed out') ||
        m.contains('unreachable') ||
        m.contains('not connected')) {
      return 'CONNECTION_FAILED';
    }
    return fallback;
  }

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
