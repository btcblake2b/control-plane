import 'dart:io';

import 'package:nwc_cln_bridge/src/bootstrap.dart';
import 'package:nwc_cln_bridge/src/config.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bridge_boot_');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  group('ensureConfig', () {
    test('crea la config dal primo avvio leggendo gli env', () async {
      final path = '${tmp.path}/config.json';

      final config = await ensureConfig(
        configPath: path,
        env: const {
          'BRIDGE_CLN_URL': 'http://127.0.0.1:3001',
          'BRIDGE_RUNE_FILE': '/tmp/bridge-rune',
          'BRIDGE_UI_PORT': '3000',
        },
      );

      expect(File(path).existsSync(), isTrue);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(config.privkeyHex), isTrue);
      expect(config.relay, kDefaultRelay);
      expect(config.clnUrl, 'http://127.0.0.1:3001');
      expect(config.runeFile, '/tmp/bridge-rune');
      expect(config.uiPort, 3000);
      // // PERCHÉ: con la UI attiva la pagina non deve restare aperta su
      // LAN/Tor: se nessun token è fornito, il bridge ne genera uno.
      expect(config.uiToken, isNotNull);
      expect(BridgeConfig.fromJsonFile(path).privkeyHex, config.privkeyHex);
    });

    test('non sovrascrive una config esistente', () async {
      final path = '${tmp.path}/config.json';
      final first = await ensureConfig(
        configPath: path,
        env: const {
          'BRIDGE_CLN_URL': 'http://a:1',
          'BRIDGE_RUNE_HEX': 'aa',
        },
      );

      final second = await ensureConfig(
        configPath: path,
        env: const {'BRIDGE_CLN_URL': 'http://b:2'},
      );

      expect(second.privkeyHex, first.privkeyHex);
      expect(second.clnUrl, 'http://a:1');
    });

    test('BRIDGE_UI_TOKEN=none disattiva il token (pagina dietro proxy)',
        () async {
      final path = '${tmp.path}/config.json';

      final config = await ensureConfig(
        configPath: path,
        env: const {
          'BRIDGE_CLN_URL': 'http://127.0.0.1:3001',
          // // PERCHÉ: con un nodo configurato la rune è obbligatoria
          // (fail-fast): il token è l'oggetto di questo test, non la rune.
          'BRIDGE_RUNE_HEX': 'test-rune',
          'BRIDGE_UI_PORT': '3000',
          'BRIDGE_UI_TOKEN': 'none',
        },
      );

      // // PERCHÉ: su Umbrel l'autenticazione la fa app_proxy (login + 2FA): un
      // token del bridge renderebbe la pagina inaccessibile dall'app.
      expect(config.uiToken, isNull);
    });

    test('senza BRIDGE_CLN_URL crea una config senza nodo (da configurare)',
        () async {
      final path = '${tmp.path}/config.json';

      final config = await ensureConfig(configPath: path, env: const {});

      // // PERCHÉ: nel package senza dependency installata il bridge deve
      // partire comunque e farsi configurare dalla pagina di stato.
      expect(config.clnUrl, isEmpty);
      expect(File(path).existsSync(), isTrue);
    });

    test('senza rune (né file né hex) lancia FormatException esplicita',
        () async {
      // // PERCHÉ: nel container il bridge moriva al primo uso con uno
      // stacktrace: qui è un errore di configurazione chiaro all'avvio.
      await expectLater(
        ensureConfig(
          configPath: '${tmp.path}/config.json',
          env: const {'BRIDGE_CLN_URL': 'http://127.0.0.1:3001'},
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('BRIDGE_RUNE'),
          ),
        ),
      );
    });
  });

  group('generateClientUri', () {
    test('produce una URI valida e autorizza la pubkey del client', () async {
      final path = '${tmp.path}/config.json';
      final config = await ensureConfig(
        configPath: path,
        env: const {
          'BRIDGE_CLN_URL': 'http://127.0.0.1:3001',
          'BRIDGE_RUNE_HEX': 'bb',
        },
      );

      final uri = await generateClientUri(config: config, configPath: path);

      expect(uri, startsWith('nostr+walletconnect://'));
      final parsed = Uri.parse(uri);
      expect(parsed.host.length, 64);
      expect(parsed.queryParameters['relay'], isNotNull);
      expect(parsed.queryParameters['secret'], isNotNull);
      // // PERCHÉ: la pubkey del client deve essere persistita, altrimenti
      // l'app verrebbe rifiutata dal bridge al primo utilizzo.
      final persisted = BridgeConfig.fromJsonFile(path);
      expect(persisted.allowedClientPubkeys, hasLength(1));
    });
  });
}
