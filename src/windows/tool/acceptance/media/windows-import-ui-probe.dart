// Isolated UI verification with artificial credentials. Not a shipping entry.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../support/tool_paths.dart';

import 'package:flutter/widgets.dart';

import 'package:encrypted_photo_app/app/vault_controller.dart';
import 'package:encrypted_photo_app/main.dart' show PhotoVaultApp;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final root = ToolPaths.data('isolated-import-ui');
  await root.create(recursive: true);
  final controller = VaultController(
    Directory('${root.path}/vault'),
    automaticCheck: false,
  );
  await controller.start();
  if (controller.screen == VaultScreen.setup) {
    await controller.initialize(
      password: 'artificial UI import validation password',
      confirmation: 'artificial UI import validation password',
      pin: '5837',
      pinConfirmation: '5837',
    );
  }
  runApp(PhotoVaultApp(controller: controller));
  // PhotoVaultApp attaches the real native lifecycle channel before opening.
  await Future<void>.delayed(const Duration(seconds: 1));
  await controller.unlock('5837');
  Timer.periodic(const Duration(seconds: 1), (timer) async {
    if (controller.screen != VaultScreen.library) return;
    final records = controller.catalog.media();
    await ToolPaths.reportFile(
      'isolated-import-ui',
      'ui-result.json',
    ).writeAsString(
      jsonEncode({
        'pid': pid,
        'mediaCount': records.length,
        'sources': controller.catalog.sources().length,
        'pending': controller.imports!.pending,
        'artificialOnly': true,
      }),
      flush: true,
    );
  });
}
