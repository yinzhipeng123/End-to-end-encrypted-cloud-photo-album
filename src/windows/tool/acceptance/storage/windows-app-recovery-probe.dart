// Separate Windows runner for real App persistence and forced-exit validation.
// Never ship this entry point. All credentials/data are artificial fixtures.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'package:encrypted_photo_app/app/vault_controller.dart';
import 'package:encrypted_photo_app/main.dart' show PhotoVaultApp;
import 'package:encrypted_photo_shared/security/vault_bootstrap_record.dart';

import 'app-recovery-file-observer.dart';

const _password = 'artificial application crash test password';
const _nextPassword = 'new artificial application crash test password';
const _pin = '7946';
const _marker = 'ARTIFICIAL_APP_CRASH_METADATA_20261110';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (args.length != 4) throw StateError('Expected mode, root, report, stage');
  final mode = args[0];
  final root = Directory(args[1]).absolute;
  final report = File(args[2]).absolute;
  final stage = args[3];
  final diskFull = mode.startsWith('disk-full-');
  final filler = File('${root.parent.path}/bounded-filler.bin');
  int? diskError;
  var filledBytes = 0;
  var appDiskErrors = 0;
  int? committedGeneration;
  var reportedSuccess = false;
  final capacityFiles = <String>[];
  var armed = false;
  var observed = false;
  final raw = RecoveryFileObserver((_, _) {});

  void checkpoint(String value) {
    if (!armed || observed || value != stage) return;
    observed = true;
    if (diskFull) {
      final handle = filler.openSync(mode: FileMode.writeOnly);
      try {
        // The parent first verifies this is the newly mounted 256 MiB VHDX.
        // The hard cap also prevents accidentally filling an ordinary disk.
        for (final size in [1024 * 1024, 4096]) {
          final buffer = Uint8List(size);
          while (filledBytes < 256 * 1024 * 1024) {
            try {
              handle.writeFromSync(buffer);
              handle.flushSync();
              filledBytes += size;
            } on FileSystemException catch (error) {
              diskError = error.osError?.errorCode;
              if (diskError != 112 && diskError != 39) rethrow;
              break;
            }
          }
        }
      } finally {
        handle.closeSync();
      }
      if (diskError == null || filledBytes >= 256 * 1024 * 1024) {
        throw StateError('Expected bounded volume exhaustion was not reached');
      }
      // NTFS can still place small protected records in unused MFT slots when
      // data clusters are full. Exhaust only those slots in this bounded disk.
      var metadataFull = false;
      for (var i = 0; i < 8192; i++) {
        final path = '${root.parent.path}/capacity-$i';
        try {
          raw.createFile(path).createSync(exclusive: true);
          capacityFiles.add(path);
        } on FileSystemException catch (error) {
          diskError = error.osError?.errorCode;
          if (diskError != 112 && diskError != 39) rethrow;
          metadataFull = true;
          break;
        }
      }
      if (!metadataFull)
        throw StateError('Metadata allocation did not reach bounded capacity');
      return;
    }
    report.writeAsStringSync(
      jsonEncode({'state': 'ready', 'stage': value, 'pid': pid}),
      flush: true,
    );
    // Parent kills this process, without executing Dart finally/dispose.
    // A bounded timeout makes a broken parent fail rather than silently resume.
    for (var i = 0; i < 60; i++) {
      sleep(const Duration(seconds: 1));
    }
    exit(95);
  }

  void observe(String path, String operation) {
    if (!armed) return;
    if (diskFull && (operation == 'error-112' || operation == 'error-39')) {
      appDiskErrors++;
    }
    final name = path.replaceAll('\\', '/').split('/').last;
    if (name == 'vault.bootstrap') {
      if (operation == 'created') checkpoint('bootstrap-created');
      if (operation == 'flushed') checkpoint('bootstrap-flushed');
      if (operation == 'before-read') {
        if (raw.createFile('${root.path}/catalog.db').existsSync())
          checkpoint('catalog-created');
        final bytes = raw.createFile(path).readAsBytesSync();
        if (bytes.length == VaultBootstrapRecord.byteLength &&
            VaultBootstrapRecord.parse(bytes).generation == 2) {
          checkpoint('password-committed');
        }
      }
    }
    if (name.startsWith('vault.bootstrap.') &&
        name.endsWith('.pending') &&
        operation == 'flushed') {
      checkpoint('password-candidate-flushed');
    }
    if (operation == 'before-create' && name.startsWith('pin-retry.sealed.'))
      checkpoint('pin-committed');
    if (operation == 'before-create' && name.startsWith('access-state.sealed.'))
      checkpoint('auxiliary-committed');
  }

  try {
    await IOOverrides.runWithIOOverrides(() async {
      final controller = VaultController(root, automaticCheck: false);
      await controller.start();
      runApp(PhotoVaultApp(controller: controller));
      await WidgetsBinding.instance.endOfFrame;
      // Settle actual runner creation before operating the isolated controller.
      await Future<void>.delayed(const Duration(milliseconds: 500));

      void require(bool value, String label) {
        if (!value) throw StateError(label);
      }

      Future<void> initialize() => controller.initialize(
        password: _password,
        confirmation: _password,
        pin: _pin,
        pinConfirmation: _pin,
      );

      if (mode == 'seed' ||
          mode == 'initialize' ||
          mode == 'disk-full-initialize') {
        require(
          controller.screen == VaultScreen.setup,
          'Expected empty fixture',
        );
        armed = mode != 'seed';
        await initialize();
        if (diskFull) {
          require(
            observed && diskError != null,
            'Actual full-volume failure missing',
          );
          require(
            controller.screen == VaultScreen.failure,
            'Incomplete initialization reported success',
          );
        } else {
          require(
            controller.screen == VaultScreen.pin,
            'Initialization did not persist',
          );
          checkpoint('initialization-completed');
        }
        if (mode == 'seed') {
          await controller.unlock(_pin);
          require(
            controller.screen == VaultScreen.library,
            'Seed unlock failed',
          );
          controller.catalog.transaction(() {
            controller.catalog.putRecord('preferences', 'sentinel', {
              'value': _marker,
            });
            controller.catalog.putMedia({
              'id': 'one',
              'kind': 'photo',
              'observedAt': 1,
              'fileName': '$_marker.jpg',
            });
            controller.catalog.putAlbum(
              id: 'old',
              name: _marker,
              hidden: true,
              members: ['one'],
            );
            controller.catalog.putRecord('tracking', 'source', {
              'generation': 1,
              'stopped': true,
            });
          });
        }
      } else if (mode == 'change' ||
          mode == 'transaction' ||
          mode == 'disk-full-change' ||
          mode == 'disk-full-transaction') {
        require(
          controller.screen == VaultScreen.pin,
          'Seed restart must require PIN',
        );
        await controller.unlock(_pin);
        require(
          controller.screen == VaultScreen.library,
          'Seed did not reopen',
        );
        armed = true;
        if (mode == 'change' || mode == 'disk-full-change') {
          checkpoint('before-change');
          await controller.changePassword(
            oldPassword: _password,
            newPassword: _nextPassword,
            confirmation: _nextPassword,
          );
          if (diskFull) {
            require(
              observed && diskError != null,
              'Actual full-volume failure missing',
            );
            reportedSuccess = (controller.message ?? '').contains('已修改');
            committedGeneration = VaultBootstrapRecord.parse(
              raw.createFile('${root.path}/vault.bootstrap').readAsBytesSync(),
            ).generation;
            require(
              controller.screen != VaultScreen.library,
              'Change bypassed PIN',
            );
            require(
              !reportedSuccess ||
                  (committedGeneration == 2 && appDiskErrors == 0),
              'Failed credential IO reported success',
            );
          } else {
            require(
              controller.screen == VaultScreen.pin,
              'Change did not finish',
            );
            checkpoint('password-change-completed');
          }
        } else {
          checkpoint('before-transaction');
          var failed = false;
          try {
            controller.catalog.transaction(() {
              controller.catalog.deleteAlbum('old');
              controller.catalog.putAlbum(
                id: 'new',
                name: '$_marker-new',
                hidden: true,
                members: ['one'],
              );
              controller.catalog.putRecord('tracking', 'source', {
                'generation': 2,
                'stopped': true,
              });
              checkpoint('transaction-uncommitted');
            });
          } catch (_) {
            if (!diskFull) rethrow;
            failed = true;
          }
          if (diskFull)
            require(
              observed && diskError != null && failed,
              'Full-volume transaction did not fail',
            );
          checkpoint('transaction-committed');
        }
      } else if (mode == 'verify') {
        require(
          controller.screen != VaultScreen.library,
          'Restart bypassed lock',
        );
        final initialization =
            stage.startsWith('bootstrap-') ||
            stage == 'catalog-created' ||
            stage == 'pin-committed' ||
            stage == 'initialization-completed' ||
            stage == 'initialize-auxiliary' ||
            stage == 'disk-initialize';
        if (stage == 'bootstrap-created' || stage == 'bootstrap-flushed') {
          require(
            controller.screen == VaultScreen.failure,
            'Incomplete initialization was not rejected',
          );
          require(
            !controller.catalogFile.existsSync(),
            'Missing catalog silently recreated',
          );
        } else {
          final changed =
              stage == 'password-committed' ||
              stage == 'change-auxiliary' ||
              stage == 'password-change-completed' ||
              stage == 'disk-after-change';
          if (changed) {
            controller.requestPhotoPassword();
            await controller.authenticatePhotoPassword(_password);
            require(
              controller.screen == VaultScreen.photoPassword,
              'Old password accepted after replacement',
            );
          }
          controller.requestPhotoPassword();
          await controller.authenticatePhotoPassword(
            changed ? _nextPassword : _password,
            newPin: initialization ? _pin : null,
            pinConfirmation: initialization ? _pin : null,
          );
          require(
            controller.screen == VaultScreen.pin,
            'Photo recovery failed',
          );
          await controller.unlock('0000');
          require(
            controller.screen != VaultScreen.library,
            'Wrong PIN bypassed lock',
          );
          await controller.unlock(_pin);
          require(
            controller.screen == VaultScreen.library,
            'Recovered PIN did not open catalog',
          );
          controller.catalog.verifyIntegrity();
          if (initialization) {
            require(
              controller.mediaCount == 0,
              'Empty fixture gained sample data',
            );
          } else {
            require(
              controller.catalog.record('preferences', 'sentinel')?['value'] ==
                  _marker,
              'Committed data lost',
            );
            final committed = stage == 'transaction-committed';
            require(
              controller.catalog.albums().single['id'] ==
                  (committed ? 'new' : 'old'),
              'Partial album transaction recovered',
            );
            require(
              controller.catalog.record('tracking', 'source')?['generation'] ==
                  (committed ? 2 : 1),
              'Partial source transaction recovered',
            );
            require(
              controller.catalog.record('tracking', 'source')?['stopped'] ==
                  true,
              'Stop state lost',
            );
          }
          final oldHandle = controller.catalog;
          controller.lock();
          var revoked = false;
          try {
            oldHandle.mediaCount;
          } catch (_) {
            revoked = true;
          }
          require(revoked, 'Recovered handle survived lock');
        }
      } else {
        throw StateError('Unknown validation mode');
      }
      if (mode != 'seed' && mode != 'verify' && !diskFull)
        throw StateError('Checkpoint not reached');
      await controller.close();
      controller.dispose();
    }, RecoveryFileObserver(observe));
    report.writeAsStringSync(
      jsonEncode({
        'state': 'passed',
        'mode': mode,
        'stage': stage,
        'platform': Platform.operatingSystemVersion,
        if (diskFull) 'actual_windows_disk_error': diskError,
        if (diskFull) 'filler_bytes': filledBytes,
        if (diskFull) 'capacity_files': capacityFiles.length,
        if (diskFull) 'app_disk_full_errors': appDiskErrors,
        if (diskFull) 'committed_generation': committedGeneration,
        if (diskFull) 'reported_success': reportedSuccess,
      }),
      flush: true,
    );
    if (diskFull && filler.existsSync()) filler.deleteSync();
    for (final path in capacityFiles) {
      File(path).deleteSync();
    }
    exit(0);
  } catch (error) {
    report.writeAsStringSync(
      jsonEncode({
        'state': 'failed',
        'mode': mode,
        'stage': stage,
        'error_type': error.runtimeType.toString(),
        if (diskFull) 'filler_bytes': filledBytes,
        if (diskFull) 'capacity_files': capacityFiles.length,
        'detail': error is StateError ? error.message : 'sanitized',
      }),
      flush: true,
    );
    if (diskFull && filler.existsSync()) filler.deleteSync();
    for (final path in capacityFiles) {
      File(path).deleteSync();
    }
    exit(1);
  }
}
