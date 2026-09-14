import 'package:nwc_cln_bridge/src/cln/cln_api.dart';
import 'package:nwc_cln_bridge/src/handlers.dart';
import 'package:nwc_cln_bridge/src/protocol.dart';
import 'package:test/test.dart';

/// Nodo CLN finto: risponde con fixture e registra le chiamate.
class FakeCln implements ClnApi {
  FakeCln(this.responses);

  final Map<String, Map<String, dynamic>> responses;
  final List<String> calls = [];
  final List<Map<String, dynamic>> callParams = [];

  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    calls.add(method);
    callParams.add(params);
    final r = responses[method];
    if (r == null) {
      throw RpcError('OTHER', 'comando non simulato: $method');
    }
    return r;
  }
}

void main() {
  group('NwcHandlers', () {
    late FakeCln cln;
    late NwcHandlers handlers;

    Map<String, Map<String, dynamic>> baseResponses() => {
          'getinfo': {'id': '02aa', 'alias': 'test-node', 'blockheight': 100},
          'listfunds': {
            'outputs': [
              {
                'amount_msat': 5000000,
                'status': 'confirmed',
                'reserved': false,
              },
              {'amount_msat': 1000000, 'status': 'unconfirmed'},
              {'amount_msat': 2000000, 'status': 'confirmed', 'reserved': true},
            ],
          },
          'listpeerchannels': {
            'channels': [
              {
                'channel_id': 'fx1',
                'peer_id': '02bb',
                'state': 'CHANNELD_NORMAL',
                'private': false,
                'to_us_msat': 15000000,
                'total_msat': 16000000,
                'funding_txid': 'aa',
                'short_channel_id': '100x1x1',
              },
              {
                'channel_id': 'fx2',
                'peer_id': '02cc',
                'state': 'CHANNELD_AWAITING_LOCKIN',
                'private': true,
                'to_us_msat': 0,
                'total_msat': 20000000,
              },
            ],
          },
          'invoice': {
            'bolt11': 'lnbc1test',
            'payment_hash': 'ph',
            'expires_at': 1234,
          },
          'pay': {
            'payment_preimage': 'pre',
            'amount_sent_msat': 1001000,
            'amount_msat': 1000000,
          },
          'connect': {},
          'fundchannel': {'txid': 'ftx', 'channel_id': 'fid'},
          'close': {'tx': 'ctx'},
        };

    setUp(() {
      cln = FakeCln(baseResponses());
      handlers = NwcHandlers(cln: cln);
    });

    test('get_info espone alias, pubkey e rete blake2b', () async {
      final r = await handlers.handle('get_info', {});
      expect(r['alias'], 'test-node');
      expect(r['pubkey'], '02aa');
      expect(r['network'], 'blake2b');
      expect(r['methods'], contains('pay_invoice'));
    });

    test('get_balance somma canali attivi + onchain confermato non riservato',
        () async {
      final r = await handlers.handle('get_balance', {});
      // 5_000_000 (onchain) + 15_000_000 (canale attivo) — esclusi unconfirmed
      // e reserved.
      expect(r['balance'], 20000000);
    });

    test('make_invoice ritorna bolt11 + payment_hash + amount (msat)',
        () async {
      final r = await handlers.handle(
        'make_invoice',
        {'amount': 1000000, 'description': 'test'},
      );
      expect(r['invoice'], 'lnbc1test');
      expect(r['payment_hash'], 'ph');
      expect(r['amount'], 1000000);
      expect(r['expires_at'], 1234);
      // La label generata è unica e prefissata.
      final params = cln.callParams.last;
      expect('${params['label']}', startsWith('nwcb-'));
    });

    test('make_invoice senza amount → errore', () async {
      expect(
        () => handlers.handle('make_invoice', {}),
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', 'OTHER'),
        ),
      );
    });

    test('pay_invoice ritorna preimage e fee calcolate', () async {
      final r = await handlers.handle('pay_invoice', {'invoice': 'lnbc1x'});
      expect(r['preimage'], 'pre');
      expect(r['fees_paid'], 1000);
    });

    test('list_channels mappa stato, saldi (msat) e privacy', () async {
      final r = await handlers.handle('list_channels', {});
      final channels = (r['channels'] as List).cast<Map<String, dynamic>>();
      expect(channels, hasLength(2));

      final c1 = channels.first;
      expect(c1['id'], 'fx1');
      expect(c1['state'], 'Usable');
      expect(c1['is_private'], false);
      expect(c1['local_balance'], 15000000);
      expect(c1['remote_balance'], 1000000);
      expect(c1['capacity'], 16000000);
      expect(c1['short_channel_id'], '100x1x1');

      final c2 = channels[1];
      expect(c2['state'], 'PendingOpen');
      expect(c2['is_private'], true);
      expect(c2.containsKey('short_channel_id'), isFalse);
    });

    test('open_channel con host fa connect poi fundchannel', () async {
      final r = await handlers.handle('open_channel', {
        'pubkey': '02bf',
        'amount': 16000,
        'host': 'lightning.example.com:9735',
      });
      expect(cln.calls, ['connect', 'fundchannel']);
      expect(
        cln.callParams.first['id'],
        '02bf@lightning.example.com:9735',
      );
      final fc = cln.callParams.last;
      expect(fc['id'], '02bf');
      expect(fc['amount'], '16000');
      expect(fc['announce'], true);
      expect(r['txid'], 'ftx');
    });

    test('open_channel private → announce false', () async {
      await handlers.handle('open_channel', {
        'pubkey': '02bf',
        'amount': 20000,
        'private': true,
      });
      expect(cln.callParams.last['announce'], false);
    });

    test('close_channel force → unilateraltimeout 0', () async {
      await handlers.handle('close_channel', {'id': 'fx1', 'force': true});
      expect(cln.callParams.last['unilateraltimeout'], 0);
    });

    test('close_channel normale → nessun timeout forzato', () async {
      await handlers.handle('close_channel', {'id': 'fx1'});
      expect(cln.callParams.last.containsKey('unilateraltimeout'), isFalse);
    });

    test('metodo sconosciuto → NOT_IMPLEMENTED', () async {
      expect(
        () => handlers.handle('frobnicate', {}),
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', 'NOT_IMPLEMENTED'),
        ),
      );
    });
  });
}
