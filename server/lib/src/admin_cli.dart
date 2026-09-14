import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';

import 'auth.dart';
import 'config.dart';
import 'db.dart';

/// Costruisce la CLI di amministrazione (riservata all'operatore del CP).
///
/// // PERCHÉ (sicurezza): NON esiste alcun endpoint HTTP di amministrazione.
/// Emettere token è possibile solo da qui, quindi solo da chi ha accesso
/// shell al server del control plane. Vedi docs/THREAT_MODEL.md.
///
/// [print] è iniettabile per i test (raccolta dell'output).
CommandRunner<int> buildAdminRunner({void Function(String line)? print}) {
  final out = print ?? (String line) => stdout.writeln(line);
  return CommandRunner<int>(
    'admin',
    'Admin CLI del control plane — solo operatore (accesso shell).',
  )
    ..argParser.addOption('db',
        help: 'Percorso del DB SQLite (default: TLW_CP_DB o data/control.db)')
    ..addCommand(_TokenCommand(out))
    ..addCommand(_NodeCommand(out));
}

/// Risoluzione del path DB: --db > TLW_CP_DB > default.
String resolveDbPath(ArgResults? globalResults) {
  final fromArg = globalResults?['db'] as String?;
  if (fromArg != null && fromArg.isNotEmpty) return fromArg;
  final fromEnv = Platform.environment['TLW_CP_DB'];
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
  return ServerConfig.defaultDbPath;
}

/// Parsa una TTL tipo `30m`, `24h`, `7d`.
Duration parseTtl(String value) {
  final match =
      RegExp(r'^(\d+)([mhd])$').firstMatch(value.trim().toLowerCase());
  if (match == null) {
    throw FormatException('TTL non valido: "$value" (usa es. 30m, 24h, 7d)');
  }
  final n = int.parse(match.group(1)!);
  return switch (match.group(2)!) {
    'm' => Duration(minutes: n),
    'h' => Duration(hours: n),
    _ => Duration(days: n),
  };
}

String _pad(String value, int width) =>
    value.length >= width ? '$value ' : value.padRight(width);

class _TokenCommand extends Command<int> {
  _TokenCommand(this._out) {
    addSubcommand(_TokenCreate(_out));
    addSubcommand(_TokenList(_out));
    addSubcommand(_TokenPurge(_out));
  }

  final void Function(String) _out;

  @override
  String get name => 'token';

  @override
  String get description => 'Gestione dei token di registrazione';

  @override
  Future<int> run() async {
    _out('Uso: admin token <create|list|purge>');
    return 0;
  }
}

class _TokenCreate extends Command<int> {
  _TokenCreate(this._out) {
    argParser
      ..addOption('note', defaultsTo: '', help: 'Nota operativa')
      ..addOption('ttl', defaultsTo: '24h', help: 'Validità: 30m, 24h, 7d');
  }

  final void Function(String) _out;

  @override
  String get name => 'create';

  @override
  String get description =>
      'Crea un token monouso (mostrato UNA sola volta)';

  @override
  Future<int> run() async {
    final ttl = parseTtl(argResults!['ttl'] as String);
    final note = argResults!['note'] as String;
    final db = Db.open(resolveDbPath(globalResults));
    try {
      final token = AuthService.randomHex32();
      final id = AuthService.randomHex16();
      final now = DateTime.now().toUtc();
      final expiresAt = now.add(ttl);
      db.insertToken(
        id: id,
        tokenSha256: AuthService.sha256Hex(token),
        note: note,
        createdAt: now,
        expiresAt: expiresAt,
      );
      _out('Token creato (mostrato UNA sola volta — consegnalo via canale sicuro):');
      _out('  token:  $token');
      _out('  id:     $id');
      _out('  scade:  ${expiresAt.toIso8601String()}');
      return 0;
    } finally {
      db.close();
    }
  }
}

class _TokenList extends Command<int> {
  _TokenList(this._out) {
    argParser.addFlag('all',
        negatable: false, help: 'Mostra anche token usati e scaduti');
  }

  final void Function(String) _out;

  @override
  String get name => 'list';

  @override
  String get description => 'Elenca i token (default: solo attivi)';

  @override
  Future<int> run() async {
    final showAll = argResults!['all'] as bool;
    final db = Db.open(resolveDbPath(globalResults));
    try {
      final tokens = db.listTokens(onlyActive: !showAll);
      if (tokens.isEmpty) {
        _out('(nessun token)');
        return 0;
      }
      _out('${_pad('ID', 34)}${_pad('NOTA', 24)}${_pad('SCADE', 22)}STATO');
      final now = DateTime.now().toUtc();
      for (final t in tokens) {
        final state = t.isUsed
            ? 'usato'
            : (t.isExpired(now) ? 'scaduto' : 'attivo');
        _out('${_pad(t.id, 34)}${_pad(t.note.isEmpty ? '-' : t.note, 24)}'
            '${_pad(t.expiresAt.toIso8601String(), 22)}$state');
      }
      return 0;
    } finally {
      db.close();
    }
  }
}

class _TokenPurge extends Command<int> {
  _TokenPurge(this._out);

  final void Function(String) _out;

  @override
  String get name => 'purge';

  @override
  String get description =>
      'Rimuove i token scaduti o usati da oltre 7 giorni (retention)';

  @override
  Future<int> run() async {
    final db = Db.open(resolveDbPath(globalResults));
    try {
      final threshold = DateTime.now().toUtc().subtract(const Duration(days: 7));
      final removed = db.purgeTokens(threshold: threshold);
      _out('Token rimossi (scaduti o usati da oltre 7 giorni): $removed');
      return 0;
    } finally {
      db.close();
    }
  }
}

class _NodeCommand extends Command<int> {
  _NodeCommand(this._out) {
    addSubcommand(_NodeList(_out));
    addSubcommand(_NodeDelete(_out));
  }

  final void Function(String) _out;

  @override
  String get name => 'node';

  @override
  String get description => 'Gestione dei nodi registrati';

  @override
  Future<int> run() async {
    _out('Uso: admin node <list|delete>');
    return 0;
  }
}

class _NodeList extends Command<int> {
  _NodeList(this._out);

  final void Function(String) _out;

  @override
  String get name => 'list';

  @override
  String get description => 'Elenca i nodi registrati';

  @override
  Future<int> run() async {
    final db = Db.open(resolveDbPath(globalResults));
    try {
      final nodes = db.listNodes();
      if (nodes.isEmpty) {
        _out('(nessun nodo)');
        return 0;
      }
      _out('${_pad('ID', 34)}${_pad('PUBKEY (x-only)', 26)}'
          '${_pad('ALIAS', 18)}${_pad('VERSIONE', 12)}CREATO');
      for (final n in nodes) {
        _out('${_pad(n.id, 34)}${_pad('${n.bridgePubkey.substring(0, 16)}…', 26)}'
            '${_pad(n.alias ?? '-', 18)}${_pad(n.version, 12)}'
            '${n.createdAt.toIso8601String()}');
      }
      return 0;
    } finally {
      db.close();
    }
  }
}

class _NodeDelete extends Command<int> {
  _NodeDelete(this._out) {
    argParser.addFlag('yes',
        abbr: 'y', negatable: false, help: 'Conferma senza prompt');
  }

  final void Function(String) _out;

  @override
  String get name => 'delete';

  @override
  String get description =>
      'Rimuove il record di un nodo (recovery: l\'utente riregistra con un nuovo token)';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) {
      throw UsageException('specifica l\'id del nodo (32 hex)', usage);
    }
    final id = rest.first.toLowerCase();
    final db = Db.open(resolveDbPath(globalResults));
    try {
      final node = db.findNode(id);
      if (node == null) {
        _out('Nodo non trovato: $id');
        return 1;
      }
      if (!(argResults!['yes'] as bool)) {
        _out('Record del nodo ${node.id} (pubkey ${node.bridgePubkey.substring(0, 16)}…) — '
            'il nodo sul server dell\'utente NON viene toccato.');
        _out('Ripeti con --yes per confermare la rimozione.');
        return 1;
      }
      db.deleteNode(node.id);
      _out('Record rimosso: ${node.id}');
      return 0;
    } finally {
      db.close();
    }
  }
}
