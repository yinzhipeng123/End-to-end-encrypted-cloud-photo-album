// Isolated, never-shipped entry point. Uses the real production root, native
// notifications, PIN service and SQLCipher. No user vault is opened.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../support/tool_paths.dart';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:encrypted_photo_app/app/vault_controller.dart';
import 'package:encrypted_photo_app/main.dart' show PhotoVaultApp;
import 'package:encrypted_photo_app/storage/library_catalog.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (arguments.length != 1) throw StateError('Expected isolated report path');
  final report = File(
    ToolPaths.checkedPath(
      arguments.single,
      ToolPaths.reports('lifecycle').path,
    ),
  );
  await report.parent.create(recursive: true);
  final scratch = await ToolPaths.freshData('lifecycle', 'epa-lifecycle-');
  final directory = Directory('${scratch.path}/vault');
  var controller = VaultController(directory);
  const password = 'artificial lifecycle verification passphrase';
  const pin = '7946';
  await controller.start();
  await controller.initialize(
    password: password,
    confirmation: password,
    pin: pin,
    pinConfirmation: pin,
  );
  if (controller.screen != VaultScreen.pin) throw StateError('Setup failed');
  final expires = controller.expiresAt;
  await controller.close();
  controller.dispose();
  controller = VaultController(directory);
  await controller.start();
  if (controller.screen != VaultScreen.pin || controller.expiresAt != expires) {
    throw StateError('Restart changed access policy');
  }
  runApp(PhotoVaultApp(controller: controller));
  await WidgetsBinding.instance.endOfFrame;
  await Future<void>.delayed(const Duration(seconds: 2));
  const channel = MethodChannel('miyu/access');
  if (await channel.invokeMethod<bool>('available') != true) {
    throw StateError('Native events unavailable');
  }
  await controller.unlock(pin);
  if (controller.screen != VaultScreen.library || controller.mediaCount != 0) {
    throw StateError('Real PIN/empty catalog check failed');
  }
  LibraryCatalog previousHandle = controller.catalog;
  final evidence = <String, Object?>{
    'recorded_at_utc': DateTime.now().toUtc().toIso8601String(),
    'platform': Platform.operatingSystemVersion,
    'isolated_fixture': true,
    'scratch_directory': scratch.path,
    'production_root': 'lib/main.dart PhotoVaultApp',
    'restart_preserved_pin_and_deadline': true,
    'phase': 'ready_for_session_lock',
    'events': <Map<String, Object?>>[],
  };
  Future<void> save() => report.writeAsString(
    const JsonEncoder.withIndent('  ').convert(evidence),
    flush: true,
  );
  await save();
  var checking = false;
  var seenLock = 0;
  var seenSuspend = 0;
  var seenResume = 0;
  var awaitingRecovery = false;
  final timer = Timer.periodic(const Duration(milliseconds: 300), (_) async {
    if (checking) return;
    checking = true;
    try {
      final state = await channel.invokeMapMethod<String, Object?>('state');
      if (state == null) throw StateError('Missing native state');
      final locks = state['sessionLockEvents'] as int;
      final suspends = state['suspendEvents'] as int;
      final resumes = state['resumeEvents'] as int;
      if (locks > seenLock || suspends > seenSuspend || resumes > seenResume) {
        var revoked = false;
        try {
          previousHandle.mediaCount;
        } on CatalogFailure {
          revoked = true;
        }
        final blocked = controller.screen != VaultScreen.library && revoked;
        (evidence['events'] as List).add({
          'observed_at_utc': DateTime.now().toUtc().toIso8601String(),
          ...state,
          'screen': controller.screen.name,
          'old_catalog_handle_revoked': revoked,
          'access_blocked': blocked,
          'deadline_unchanged': controller.expiresAt == expires,
        });
        if (!blocked || controller.expiresAt != expires) {
          throw StateError('Native event failed access revocation');
        }
        seenLock = locks;
        seenSuspend = suspends;
        seenResume = resumes;
        awaitingRecovery = true;
        evidence['phase'] = 'waiting_for_windows_return';
        await save();
      }
      if (awaitingRecovery &&
          await channel.invokeMethod<bool>('available') == true) {
        // Only artificial credentials in this separate fixture. Production
        // never automatically submits a PIN or restores an unlocked session.
        await controller.unlock('0000');
        if (controller.screen == VaultScreen.library) {
          throw StateError('Wrong PIN unlocked after OS event');
        }
        await controller.unlock(pin);
        if (controller.screen != VaultScreen.library ||
            controller.expiresAt != expires ||
            controller.mediaCount != 0) {
          throw StateError('PIN recovery/deadline failed');
        }
        previousHandle = controller.catalog;
        awaitingRecovery = false;
        evidence['phase'] = seenSuspend > 0 && seenResume > 0 && seenLock > 0
            ? 'passed'
            : 'ready_for_suspend';
        evidence['wrong_pin_blocked_correct_pin_reopened'] = true;
        await save();
      }
    } catch (error) {
      evidence['phase'] = 'failed';
      evidence['failure_type'] = error.runtimeType.toString();
      await save();
    } finally {
      checking = false;
    }
  });
  // Keep the fixture open for inspection; a separate controller owns shutdown.
  unawaited(
    Future<void>(() async {
      while (evidence['phase'] != 'passed' && evidence['phase'] != 'failed') {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      timer.cancel();
    }),
  );
}
