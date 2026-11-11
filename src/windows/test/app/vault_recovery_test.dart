import 'dart:convert';
import 'dart:io';

import 'package:encrypted_photo_app/app/vault_controller.dart';
import 'package:encrypted_photo_shared/security/security_failure.dart';
import 'package:encrypted_photo_shared/security/vault_bootstrap_store.dart';
import 'package:flutter_test/flutter_test.dart';

// Real controller, filesystem, DPAPI, crypto and SQLCipher. Faults are created
// only inside each disposable fixture by occupying a destination with a folder.
void main() {
  if (!Platform.isWindows) return;
  const password = 'artificial interrupted application password';
  const nextPassword = 'different artificial application password';
  const marker = 'ARTIFICIAL_APP_RECOVERY_PRIVATE_20261110';
  late Directory scratch;
  late Directory directory;
  late VaultController app;

  Future<void> reopen() async {
    await app.close();
    app.dispose();
    app = VaultController(directory, automaticCheck: false);
    await app.start();
  }

  Future<void> initialize() => app.initialize(
    password: password,
    confirmation: password,
    pin: '8392',
    pinConfirmation: '8392',
  );

  Future<void> seed() async {
    await initialize();
    expect(app.screen, VaultScreen.pin, reason: app.message);
    await app.unlock('8392');
    expect(app.screen, VaultScreen.library, reason: app.message);
    app.catalog.putRecord('preferences', 'sentinel', {'value': marker});
  }

  Future<void> change() => app.changePassword(
    oldPassword: password,
    newPassword: nextPassword,
    confirmation: nextPassword,
  );

  Future<Future<void> Function()> occupy(String name) async {
    final path = '${directory.path}/$name';
    final existing = File(path);
    final saved = File('$path.fixture-copy');
    if (await existing.exists()) await existing.rename(saved.path);
    final blocker = await Directory(path).create();
    return () async {
      await blocker.delete();
      if (await saved.exists()) await saved.rename(existing.path);
    };
  }

  void expectLocked() {
    expect(app.screen, isNot(VaultScreen.library));
    expect(() => app.catalog, throwsA(isA<SecurityFailure>()));
  }

  Future<void> authenticate(String value) async {
    app.requestPhotoPassword();
    await app.authenticatePhotoPassword(value);
  }

  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('epa-app-recovery-');
    directory = Directory('${scratch.path}/vault');
    app = VaultController(directory, automaticCheck: false);
    await app.start();
    expect(app.screen, VaultScreen.setup, reason: app.message);
  });
  tearDown(() async {
    await app.close();
    app.dispose();
    await scratch.delete(recursive: true);
  });

  test(
    'initialization cannot overwrite an occupied catalog destination',
    () async {
      final release = await occupy('catalog.db');
      await initialize();
      expect(app.screen, VaultScreen.failure, reason: app.message);
      final bootstrap = File('${directory.path}/vault.bootstrap');
      final saved = await bootstrap.readAsBytes();
      await release();
      await reopen();
      expect(app.screen, VaultScreen.failure);
      expect(await bootstrap.readAsBytes(), saved);
      expect(await app.catalogFile.exists(), false);
    },
  );

  test(
    'partial initialization with missing PIN requires explicit PIN recovery',
    () async {
      final release = await occupy('pin.sealed');
      await initialize();
      expect(app.screen, VaultScreen.failure, reason: app.message);
      expect(await app.catalogFile.exists(), true);
      final catalogBefore = await app.catalogFile.readAsBytes();
      await release();
      await reopen();
      expect(app.screen, VaultScreen.photoPassword);
      await app.authenticatePhotoPassword(password);
      expect(app.screen, VaultScreen.photoPassword, reason: app.message);
      expect(app.message, contains('重新设置本机四位应用锁'));
      await app.authenticatePhotoPassword(
        password,
        newPin: '5618',
        pinConfirmation: '5618',
      );
      expect(app.screen, VaultScreen.pin, reason: app.message);
      await app.unlock('5618');
      expect(app.screen, VaultScreen.library, reason: app.message);
      expect(app.mediaCount, 0);
      expect(await app.catalogFile.readAsBytes(), catalogBefore);
    },
  );

  test('missing PIN after setup cannot report a usable PIN gate', () async {
    await seed();
    final deadline = app.expiresAt;
    app.lock();
    await File('${directory.path}/pin.sealed').delete();
    await authenticate(password);
    expect(app.screen, VaultScreen.photoPassword, reason: app.message);
    expect(app.message, contains('重新设置本机四位应用锁'));
    expect(app.expiresAt, deadline);
    expectLocked();
  });

  for (final name in ['photo-retry.sealed', 'vault.bootstrap.update-lock']) {
    test(
      'password-change failure before commit preserves old password: $name',
      () async {
        await seed();
        final bootstrap = File('${directory.path}/vault.bootstrap');
        final before = await bootstrap.readAsBytes();
        final release = await occupy(name);
        await change();
        expectLocked();
        expect(app.message, isNot(contains('已修改')));
        expect(await bootstrap.readAsBytes(), before);
        await release();
        await reopen();
        await authenticate(nextPassword);
        expect(app.screen, VaultScreen.photoPassword);
        await authenticate(password);
        expect(app.screen, VaultScreen.pin, reason: app.message);
        await app.unlock('8392');
        expect(app.catalog.record('preferences', 'sentinel')!['value'], marker);
      },
    );
  }

  for (final name in ['auxiliary.sealed', 'access-state.sealed']) {
    test(
      'failure after password commit recovers only with new password: $name',
      () async {
        await seed();
        final bootstrap = VaultBootstrapStore(
          File('${directory.path}/vault.bootstrap'),
        );
        final before = await bootstrap.read();
        final catalogBefore = await app.catalogFile.readAsBytes();
        final release = await occupy(name);
        await change();
        expectLocked();
        expect(app.message, isNot(contains('已修改')));
        expect((await bootstrap.read()).generation, before.generation + 1);
        await release();
        await reopen();
        expect(app.screen, VaultScreen.photoPassword);
        await app.unlock('8392');
        expectLocked();
        await authenticate(password);
        expect(app.screen, VaultScreen.photoPassword);
        await authenticate(nextPassword);
        expect(app.screen, VaultScreen.pin, reason: app.message);
        await app.unlock('8392');
        expect(app.catalog.record('preferences', 'sentinel')!['value'], marker);
        expect(await app.catalogFile.readAsBytes(), catalogBefore);
      },
    );
  }

  test(
    'PIN retry write failure never opens a catalog and remains recoverable',
    () async {
      await seed();
      app.lock();
      final release = await occupy('pin-retry.sealed');
      await app.unlock('8392');
      expectLocked();
      await release();
      await reopen();
      await app.unlock('8392');
      expect(app.catalog.record('preferences', 'sentinel')!['value'], marker);
    },
  );

  test('real application files contain no artificial password or metadata plaintext', () async {
    await seed();
    await change();
    await app.close();
    final markers = [password, nextPassword, marker];
    var checked = 0;
    for (final file in directory.listSync().whereType<File>()) {
      final raw = latin1.decode(file.readAsBytesSync());
      for (final sensitive in markers) {
        expect(
          raw.contains(sensitive),
          false,
          reason: file.uri.pathSegments.last,
        );
        final utf16 = sensitive.codeUnits
            .expand((value) => [value & 255, value >> 8])
            .toList();
        expect(raw.contains(latin1.decode(utf16)), false);
      }
      checked++;
    }
    expect(checked, greaterThanOrEqualTo(8));
    await reopen();
    await app.unlock('8392');
    expect(app.catalog.record('preferences', 'sentinel')!['value'], marker);
  });
}
