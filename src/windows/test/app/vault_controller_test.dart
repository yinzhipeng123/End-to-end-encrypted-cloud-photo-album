import 'dart:io';

import 'package:encrypted_photo_app/app/vault_controller.dart';
import 'package:encrypted_photo_shared/security/reverification_gate.dart';
import 'package:encrypted_photo_shared/security/security_failure.dart';
import 'package:encrypted_photo_app/storage/library_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

// Only time is deterministic. Credentials, DPAPI, ACLs, files and SQLCipher are real.
class ControlledClock implements SecurityClock {
  int utc = 1900000000000;
  int ticks = 1000000;
  void advance(int milliseconds) {
    utc += milliseconds;
    ticks += milliseconds;
  }

  @override
  int utcMilliseconds() => utc;
  @override
  int monotonicMilliseconds() => ticks;
}

void main() {
  if (!Platform.isWindows) return;
  late Directory scratch;
  late Directory directory;
  late ControlledClock clock;
  late VaultController app;
  const password = 'artificial river sunset photo password';
  const nextPassword = 'different artificial valley photo password';

  Future<void> setup() async {
    await app.initialize(
      password: password,
      confirmation: password,
      pin: '8392',
      pinConfirmation: '8392',
    );
    expect(app.screen, VaultScreen.pin, reason: app.message);
  }

  Future<void> reopen() async {
    await app.close();
    app.dispose();
    app = VaultController(directory, clock: clock, automaticCheck: false);
    await app.start();
  }

  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('epa-controller-');
    directory = Directory('${scratch.path}/vault');
    clock = ControlledClock();
    app = VaultController(directory, clock: clock, automaticCheck: false);
    await app.start();
    expect(app.screen, VaultScreen.setup, reason: app.message);
  });
  tearDown(() async {
    await app.close();
    app.dispose();
    await scratch.delete(recursive: true);
  });

  test('first actual setup has no default credentials, sample rows or unlocked PIN bypass', () async {
    await setup();
    expect(() => app.catalog, throwsA(isA<SecurityFailure>()));
    await app.unlock('0000');
    expect(app.screen, VaultScreen.pin, reason: app.message);
    await app.unlock('8392');
    expect(app.screen, VaultScreen.library, reason: app.message);
    expect(app.mediaCount, 0);
    expect(app.catalog.albums(), isEmpty);
    expect(app.catalog.sources(), isEmpty);
    final bytes = await app.catalogFile.readAsBytes();
    expect(bytes.take(15), isNot('SQLite format 3'.codeUnits));
  });

  test('restart requires PIN and recovers actual encrypted data without extending deadline', () async {
    await setup();
    await app.unlock('8392');
    final expires = app.expiresAt;
    app.catalog.putMedia({
      'id': 'one',
      'observedAt': 1,
      'kind': 'photo',
      'fileName': 'ARTIFICIAL_PRIVATE_RESTART.jpg',
      'favorite': true,
    });
    await reopen();
    expect(app.screen, VaultScreen.pin, reason: app.message);
    expect(() => app.catalog, throwsA(isA<SecurityFailure>()));
    await app.unlock('8392');
    expect(app.mediaCount, 1);
    expect(app.catalog.media().single['favorite'], true);
    expect(app.expiresAt, expires);
  });

  test(
    'ordinary lock closes catalog and invalidates previously obtained handle',
    () async {
      await setup();
      await app.unlock('8392');
      final handle = app.catalog;
      app.lock();
      expect(app.screen, VaultScreen.pin, reason: app.message);
      expect(() => handle.mediaCount, throwsA(isA<CatalogFailure>()));
      await app.unlock('8392');
      expect(app.screen, VaultScreen.library);
    },
  );

  test(
    '72-hour boundary blocks PIN, requires real photo password then PIN',
    () async {
      await setup();
      await app.unlock('8392');
      final expires = app.expiresAt;
      clock.advance(ReverificationGate.durationMillis);
      await app.checkAccess();
      expect(app.screen, VaultScreen.photoPassword);
      await app.unlock('8392');
      expect(app.screen, VaultScreen.photoPassword);
      await app.authenticatePhotoPassword('wrong photo password');
      expect(app.screen, VaultScreen.photoPassword);
      expect(app.expiresAt, expires);
      await app.authenticatePhotoPassword(password);
      expect(app.screen, VaultScreen.pin, reason: app.message);
      expect(app.expiresAt, greaterThan(expires!));
      await app.unlock('8392');
      expect(app.screen, VaultScreen.library);
    },
  );

  test('PIN reset requires correct photo password and preserves catalog through restart', () async {
    await setup();
    await app.unlock('8392');
    app.catalog.putRecord('preferences', 'test', {
      'value': 'artificial persistent',
    });
    app.requestPhotoPassword();
    await app.authenticatePhotoPassword(
      'wrong photo password',
      newPin: '5618',
      pinConfirmation: '5618',
    );
    expect(app.screen, VaultScreen.photoPassword);
    await app.authenticatePhotoPassword(
      password,
      newPin: '5618',
      pinConfirmation: '5618',
    );
    expect(app.screen, VaultScreen.pin, reason: app.message);
    await app.unlock('8392');
    expect(app.screen, VaultScreen.pin, reason: app.message);
    await app.unlock('5618');
    expect(app.screen, VaultScreen.library);
    await reopen();
    await app.unlock('5618');
    expect(
      app.catalog.record('preferences', 'test')!['value'],
      'artificial persistent',
    );
  });

  test('real password change requires unlocked PIN and old password, keeps database', () async {
    await setup();
    await app.changePassword(
      oldPassword: password,
      newPassword: nextPassword,
      confirmation: nextPassword,
    );
    expect(app.screen, isNot(VaultScreen.library));
    await app.unlock('8392');
    expect(app.screen, VaultScreen.library, reason: app.message);
    app.catalog.putRecord('preferences', 'kept', {'v': true});
    await app.changePassword(
      oldPassword: 'incorrect old password',
      newPassword: nextPassword,
      confirmation: nextPassword,
    );
    expect(app.screen, isNot(VaultScreen.library));
    await app.unlock('8392');
    await app.changePassword(
      oldPassword: password,
      newPassword: nextPassword,
      confirmation: nextPassword,
    );
    expect(app.screen, VaultScreen.pin, reason: app.message);
    await reopen();
    app.requestPhotoPassword();
    await app.authenticatePhotoPassword(password);
    expect(app.screen, VaultScreen.photoPassword);
    await app.authenticatePhotoPassword(nextPassword);
    expect(app.screen, VaultScreen.pin, reason: app.message);
    await app.unlock('8392');
    expect(app.catalog.record('preferences', 'kept')!['v'], true);
  });

  test('missing auxiliary material never grants access and can recover through password', () async {
    await setup();
    await File('${directory.path}/auxiliary.sealed').delete();
    await app.unlock('8392');
    expect(app.screen, VaultScreen.photoPassword);
    await app.authenticatePhotoPassword(password);
    await app.unlock('8392');
    expect(app.screen, VaultScreen.library, reason: app.message);
  });

  test('missing existing catalog is reported, never rebuilt as an empty successful library', () async {
    await setup();
    final bootstrap = File('${directory.path}/vault.bootstrap');
    final before = await bootstrap.readAsBytes();
    await app.close();
    await app.catalogFile.rename(
      '${directory.path}/artificial-isolated-copy.db',
    );
    await reopen();
    expect(app.screen, VaultScreen.failure);
    expect(app.catalogFile.existsSync(), false);
    expect(await bootstrap.readAsBytes(), before);
  });

  test('an independent controller cannot concurrently own the same actual data directory', () async {
    final other = VaultController(
      directory,
      clock: clock,
      automaticCheck: false,
    );
    try {
      await other.start();
      expect(other.screen, VaultScreen.failure);
      expect(other.message, contains('其他客户端'));
    } finally {
      await other.close();
      other.dispose();
    }
  });

  test('lock during real password computation never publishes a late unlocked session', () async {
    await setup();
    app.requestPhotoPassword();
    final pending = app.authenticatePhotoPassword(password);
    app.lock();
    await pending;
    expect(app.screen, isNot(VaultScreen.library));
    expect(() => app.catalog, throwsA(isA<SecurityFailure>()));
  });
}
