// A separate, never-shipped Flutter entry point for isolated runner validation.
// Uses real production services and artificial credentials, not a demo store.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../support/tool_paths.dart';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

import 'package:encrypted_photo_app/app/vault_controller.dart';
import 'package:encrypted_photo_app/main.dart' show PhotoVaultApp;
import 'package:encrypted_photo_app/storage/library_catalog.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final scratch = await ToolPaths.freshData(
    'security',
    'epa-runner-verification-',
  );
  final controller = VaultController(Directory('${scratch.path}/vault'));
  final report = ToolPaths.reportFile(
    'security',
    'windows-runner-evidence.json',
  );
  await controller.start();
  const artificialPassword = 'isolated native runner verification password';
  await controller.initialize(
    password: artificialPassword,
    confirmation: artificialPassword,
    pin: '7946',
    pinConfirmation: '7946',
  );
  if (controller.screen != VaultScreen.pin)
    throw StateError('Initialization failed');
  final expires = controller.expiresAt;
  await controller.close();
  controller.dispose();
  final restarted = VaultController(Directory('${scratch.path}/vault'));
  await restarted.start();
  if (restarted.screen != VaultScreen.pin || restarted.expiresAt != expires) {
    throw StateError(
      'Restart did not preserve ordinary lock and original deadline',
    );
  }
  runApp(PhotoVaultApp(controller: restarted));
  await WidgetsBinding.instance.endOfFrame;
  // The runner shows its window after the first frame. Let those initial
  // lifecycle notifications settle before preparing the isolated unlocked view.
  await Future<void>.delayed(const Duration(seconds: 2));
  const channel = MethodChannel('miyu/access');
  final subscribed = await channel.invokeMethod<bool>('available') == true;
  if (!subscribed)
    throw StateError('Native window security subscription unavailable');
  await restarted.unlock('7946');
  if (restarted.screen != VaultScreen.library || restarted.mediaCount != 0) {
    throw StateError('Actual PIN/catalog initialization did not complete');
  }
  final handle = restarted.catalog;
  final evidence = <String, Object?>{
    'recorded_at_utc': DateTime.now().toUtc().toIso8601String(),
    'platform': Platform.operatingSystemVersion,
    'isolated_fixture': true,
    'real_initialization': true,
    'restart_preserved_pin_gate_and_deadline': true,
    'actual_windows_session_notifications_registered': subscribed,
    'real_pin_unlock_and_empty_sqlcipher_catalog': true,
    'lock_delivery': 'waiting for an observed native window action',
    'system_lock_and_suspend': 'not forced on user workstation; event handlers implemented, not physically exercised',
  };
  await report.writeAsString(
    const JsonEncoder.withIndent('  ').convert(evidence),
    flush: true,
  );
  var recorded = false;
  restarted.addListener(() {
    if (recorded || restarted.screen != VaultScreen.pin) return;
    recorded = true;
    var revoked = false;
    try {
      handle.mediaCount;
    } on CatalogFailure {
      revoked = true;
    }
    evidence['lock_delivery'] = 'PIN screen restored';
    evidence['test_callback_stack'] = StackTrace.current.toString();
    evidence['catalog_handle_revoked'] = revoked;
    unawaited(
      report.writeAsString(
        const JsonEncoder.withIndent('  ').convert(evidence),
        flush: true,
      ),
    );
  });
}
