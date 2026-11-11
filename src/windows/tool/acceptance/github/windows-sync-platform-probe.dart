// Isolated real-GitHub acceptance entry. Never shipped as lib/main.dart.
// Uses artificial files only. User completes the product's Device Flow.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../support/tool_paths.dart';

import 'package:flutter/widgets.dart';

import 'package:encrypted_photo_app/app/vault_controller.dart';
import 'package:encrypted_photo_app/main.dart' show PhotoVaultApp;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final root = ToolPaths.data('sync-platform');
  await root.create(recursive: true);
  final controller = VaultController(Directory('${root.path}/sender'));
  await controller.start();
  if (controller.screen == VaultScreen.setup) {
    await controller.initialize(
      password: 'isolated GitHub sync password 2026',
      confirmation: 'isolated GitHub sync password 2026',
      pin: '5837',
      pinConfirmation: '5837',
    );
  }
  runApp(PhotoVaultApp(controller: controller));
  var checking = false, imported = false, initialized = false;
  final evidence = ToolPaths.reportFile('sync-platform', 'sender-status.json');
  Timer.periodic(const Duration(seconds: 2), (_) async {
    if (checking) return;
    checking = true;
    try {
      if (controller.screen != VaultScreen.library) {
        await evidence.writeAsString(
          jsonEncode({
            'pid': pid,
            'screen': controller.screen.name,
            'artificialOnly': true,
            'needsUserUnlock': true,
          }),
        );
        return;
      }
      final connection = controller.github!;
      final sync = controller.sync!;
      if (!imported) {
        await controller.imports!.addFolder('${root.path}/artificial-source');
        imported = true;
      }
      if (!connection.busy && !sync.busy && connection.verified) {
        final choices = connection.repositories.where(
          (r) =>
              r.id == 1452541678 &&
              r.fullName == 'yinzhipeng123/test-album' &&
              r.eligible,
        );
        if (choices.length == 1 && connection.selected?.id != 1452541678) {
          await connection.selectRepository(choices.single);
        }
        if (connection.selected?.id == 1452541678 &&
            !sync.initialized &&
            !initialized) {
          initialized = true;
          // User explicitly approved this exact repository and WSR-1 initialization.
          await sync.initializeRepository();
        }
      }
      if (controller.screen != VaultScreen.library) return;
      await evidence.writeAsString(
        jsonEncode({
          'pid': pid,
          'screen': controller.screen.name,
          'artificialOnly': true,
          'authorized': connection.user != null,
          'targetId': connection.selected?.id,
          'initialized': sync.initialized,
          'importedCount': controller.mediaCount,
          'verifiedCount': controller.catalog
              .media()
              .where(sync.verified)
              .length,
          'phase': sync.phase,
          'bytesDone': sync.bytesDone,
          'bytesTotal': sync.bytesTotal,
          'issue': sync.issue,
          'connectionMessage': connection.message,
          'jobPhases': sync.jobs.map((j) => j['phase']).toList(),
        }),
      );
    } catch (_) {
      // No stack, credentials, media names or response bodies in diagnostic output.
    } finally {
      checking = false;
    }
  });
}
