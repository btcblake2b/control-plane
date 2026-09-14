import 'dart:io';

import 'package:tlw_control_plane/src/admin_cli.dart';

/// Admin CLI del control plane — riservata all'operatore (accesso shell).
/// Esempi: admin token create --note "per Mario" | admin node list
Future<void> main(List<String> args) async {
  final runner = buildAdminRunner();
  final code = await runner.run(args);
  exit(code ?? 0);
}
