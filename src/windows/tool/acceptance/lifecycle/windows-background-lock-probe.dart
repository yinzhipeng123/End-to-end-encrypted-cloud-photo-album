// Isolated native minimize acceptance; never shipped as lib/main.dart.
// No user vault, credentials, photographs or repository are opened.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../support/tool_paths.dart';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:encrypted_photo_app/app/vault_controller.dart';
import 'package:encrypted_photo_app/main.dart' show PhotoVaultApp;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final root = ToolPaths.data('background-lock-platform');
  await root.create(recursive: true);
  final scratch = await ToolPaths.freshData(
    'background-lock-platform',
    'epa-background-native-',
  );
  final photos = await Directory('${scratch.path}/sources').create();
  final app = VaultController(Directory('${scratch.path}/vault'));
  await app.start();
  const password = 'artificial native background lock password';
  await app.initialize(
    password: password,
    confirmation: password,
    pin: '7946',
    pinConfirmation: '7946',
  );
  runApp(PhotoVaultApp(controller: app));
  await WidgetsBinding.instance.endOfFrame;
  await Future<void>.delayed(const Duration(seconds: 2));
  const channel = MethodChannel('miyu/access');
  if (await channel.invokeMethod<bool>('available') != true) {
    throw StateError('Native security events unavailable');
  }
  // Only artificial credentials created above in this isolated fixture.
  await app.unlock('7946');
  if (app.screen != VaultScreen.library) throw StateError('PIN failed');
  final imports = app.imports!, sync = app.sync!, view = app.catalog;
  final deadline = app.expiresAt;
  await imports.addFolder(photos.path);
  await imports.settled;
  final evidence = <String, Object?>{
    'recordedAtUtc': DateTime.now().toUtc().toIso8601String(),
    'platform': Platform.operatingSystemVersion,
    'artificialOnly': true,
    'networkUsed': false,
    'productionRoot': 'PhotoVaultApp',
    'pid': pid,
    'phase': 'ready_for_minimize',
  };
  final report = ToolPaths.reportFile(
    'background-lock-platform',
    'result.json',
  );
  Future<void> save() => report.writeAsString(
    const JsonEncoder.withIndent('  ').convert(evidence),
    flush: true,
  );
  await save();
  var running = false, added = false;
  Timer? timer;
  timer = Timer.periodic(const Duration(milliseconds: 300), (_) async {
    if (running) return;
    running = true;
    try {
      final state = await channel.invokeMapMethod<String, Object?>('state');
      if ((state?['minimizeEvents'] as int? ?? 0) == 0 ||
          state?['minimized'] != true)
        return;
      if (app.screen != VaultScreen.pin ||
          !identical(app.imports, imports) ||
          !identical(app.sync, sync) ||
          app.expiresAt != deadline) {
        throw StateError('Minimize did not preserve background and lock UI');
      }
      var revoked = false;
      try {
        view.mediaCount;
      } catch (_) {
        revoked = true;
      }
      if (!revoked) throw StateError('Old view remained usable');
      if (!added) {
        final file = File('${photos.path}/new/nested/artificial.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=',
          ),
        );
        added = true;
        evidence['phase'] = 'waiting_for_locked_import';
        await save();
      }
      if (imports.mediaCount == 1) {
        evidence.addAll({
          'phase': 'passed',
          'nativeState': state,
          'screen': app.screen.name,
          'oldViewRevoked': revoked,
          'sameImportService': identical(imports, app.imports),
          'sameSyncService': identical(sync, app.sync),
          'lockedNewFileImported': true,
          'deadlineUnchanged': app.expiresAt == deadline,
          'encryptedDatabase': !latin1
              .decode(await app.catalogFile.readAsBytes())
              .contains('artificial.png'),
        });
        await save();
        timer?.cancel();
      }
    } catch (e) {
      evidence['phase'] = 'failed';
      evidence['failureType'] = e.runtimeType.toString();
      await save();
      timer?.cancel();
    } finally {
      running = false;
    }
  });
}
