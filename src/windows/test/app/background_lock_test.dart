// Real Windows files, SQLCipher, DPAPI and production controller. Only clock
// inputs and the GitHub HTTP endpoint are controlled; not platform acceptance.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:encrypted_photo_app/app/vault_controller.dart';
import 'package:encrypted_photo_app/repositories/github_api.dart';
import 'package:encrypted_photo_shared/security/reverification_gate.dart';
import 'package:encrypted_photo_shared/security/security_failure.dart';
import 'package:encrypted_photo_app/services/import/windows_source_reader.dart';
import 'package:encrypted_photo_app/storage/library_catalog.dart';

import '../support/git_database_transport.dart';
import 'vault_controller_test.dart' show ControlledClock;

Future<void> waitFor(bool Function() ready) async {
  final limit = DateTime.now().add(const Duration(minutes: 2));
  while (!ready()) {
    if (DateTime.now().isAfter(limit)) throw StateError('Condition timed out');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  if (!Platform.isWindows) return;
  WindowsSourceReader.setTestLibrary(
    File('build/source-reader/Release/epa_source_reader.dll').absolute.path,
  );
  late Directory scratch, photos, vault;
  late VaultController app;
  late ControlledClock clock;
  late GitDatabaseTransport wire;
  const password = 'isolated background lock password';
  const pin = '8392';
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=',
  );
  Future<void> photo(String name) async {
    final file = File('${photos.path}/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(png);
  }

  Future<void> connect() async {
    await app.github!.authorize();
    expect(app.github!.repositories, hasLength(1), reason: app.github!.message);
    await app.github!.selectRepository(app.github!.repositories.single);
    await app.sync!.initializeRepository();
    expect(app.sync!.initialized, true, reason: app.sync!.issue);
  }

  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('epa-background-lock-');
    photos = await Directory('${scratch.path}/sources').create();
    vault = Directory('${scratch.path}/vault');
    clock = ControlledClock();
    wire = GitDatabaseTransport();
    app = VaultController(
      vault,
      clock: clock,
      automaticCheck: false,
      repositoryApi: GitHubApi(transport: wire),
    );
    await app.start();
    await app.initialize(
      password: password,
      confirmation: password,
      pin: pin,
      pinConfirmation: pin,
    );
    await app.unlock(pin);
    expect(app.screen, VaultScreen.library, reason: app.message);
  });
  tearDown(() async {
    wire.beforeRequest = null;
    await app.close();
    app.dispose();
    await scratch.delete(recursive: true);
  });

  test('ordinary lock revokes old views, imports new nested files and retains encrypted records across restart', () async {
    final imports = app.imports!;
    final sync = app.sync!;
    final catalog = app.catalog;
    final organization = app.organization!;
    final deadline = app.expiresAt;
    await photo('first');
    await imports.addFolder(photos.path);
    await waitFor(() => catalog.mediaCount == 1);
    final id = catalog.media().single['id'] as String;
    final preview = await imports.preview(id);
    expect(preview, png);
    app.lock();
    expect(app.screen, VaultScreen.pin);
    expect(() => app.catalog, throwsA(isA<SecurityFailure>()));
    expect(() => catalog.mediaCount, throwsA(isA<CatalogFailure>()));
    expect(() => organization.count, throwsA(isA<CatalogFailure>()));
    expect(preview!.every((b) => b == 0), true);
    await expectLater(imports.preview(id), throwsA(isA<SecurityFailure>()));
    await expectLater(
      imports.addFolder(photos.path),
      throwsA(isA<SecurityFailure>()),
    );
    await photo('new/deep/locked');
    await waitFor(() => imports.mediaCount == 2);
    await app.unlock('0000');
    expect(app.screen, VaultScreen.pin);
    expect(app.sync, same(sync));
    expect(app.imports, same(imports));
    await app.unlock(pin);
    expect(app.screen, VaultScreen.library, reason: app.message);
    expect(app.mediaCount, 2);
    expect(app.sync, same(sync));
    expect(app.imports, same(imports));
    expect(app.expiresAt, deadline);
    expect(() => catalog.mediaCount, throwsA(isA<CatalogFailure>()));
    expect(
      latin1.decode(await app.catalogFile.readAsBytes()),
      isNot(contains('locked.png')),
    );
    await app.close();
    app.dispose();
    app = VaultController(vault, clock: clock, automaticCheck: false);
    await app.start();
    expect(app.screen, VaultScreen.pin);
    expect(app.sync, isNull);
    expect(app.imports, isNull);
    await app.unlock(pin);
    expect(app.mediaCount, 2);
    expect(app.expiresAt, deadline);
  });

  test('queued local preview cannot survive lock then unlock', () async {
    final imports = app.imports!;
    await photo('one');
    await imports.addFolder(photos.path);
    await waitFor(() => app.mediaCount == 1);
    await imports.settled;
    final held = Completer<void>();
    final entered = Completer<void>();
    final blocker = imports.withContentRead(() async {
      entered.complete();
      await held.future;
    });
    await entered.future;
    final pending = imports.preview(app.catalog.media().single['id'] as String);
    final rejected = expectLater(pending, throwsA(anything));
    app.lock();
    await app.unlock(pin);
    held.complete();
    await blocker;
    await rejected;
    expect(app.screen, VaultScreen.library);
  });

  test('PIN limits retain background until tenth failure then require photo password', () async {
    final sync = app.sync!;
    app.lock();
    for (var i = 1; i <= 10; i++) {
      await app.unlock('0000');
      if (i < 10) {
        expect(app.screen, VaultScreen.pin);
        expect(app.sync, same(sync));
      }
      if (i == 5) {
        await app.unlock(pin);
        expect(
          app.screen,
          VaultScreen.pin,
          reason: 'Waiting cannot admit correct PIN',
        );
        expect(app.sync, same(sync));
      }
      clock.advance(600000);
    }
    expect(app.screen, VaultScreen.photoPassword);
    expect(app.sync, isNull);
    expect(() => sync.check(), throwsA(anything));
    await app.unlock(pin);
    expect(app.screen, VaultScreen.photoPassword);
  });

  test('corrupt protected PIN material revokes background instead of counting as wrong PIN', () async {
    app.lock();
    await File('${vault.path}/pin.sealed').writeAsBytes([1, 2, 3], flush: true);
    await app.unlock(pin);
    expect(app.screen, VaultScreen.photoPassword);
    expect(app.sync, isNull);
    expect(app.imports, isNull);
  });

  for (final anomaly in [false, true]) {
    test(
      'locked background revoked by ${anomaly ? 'clock anomaly' : '72 hour expiry'}',
      () async {
        final sync = app.sync!, imports = app.imports!;
        final deadline = app.expiresAt;
        app.lock();
        if (anomaly) {
          clock.utc -= 120000;
        } else {
          clock.advance(ReverificationGate.durationMillis);
        }
        await app.checkAccess();
        expect(app.screen, VaultScreen.photoPassword);
        expect(app.sync, isNull);
        expect(imports.token.cancelled, true);
        expect(() => sync.check(), throwsA(anything));
        await app.unlock(pin);
        expect(app.screen, VaultScreen.photoPassword);
        expect(app.expiresAt, deadline);
      },
    );
  }

  test('system suspension overrides interface lock; manual pause survives both and restart', () async {
    final sync = app.sync!, imports = app.imports!;
    sync.pause();
    app.lock();
    expect(sync.paused, true);
    await app.unlock(pin);
    expect(app.sync, same(sync));
    expect(sync.paused, true);
    app.lock();
    app.suspend();
    app.lock(); // Late duplicate minimize must not resurrect anything.
    expect(app.sync, isNull);
    expect(imports.token.cancelled, true);
    await app.unlock(pin);
    expect(app.sync, isNot(same(sync)));
    expect(app.sync!.paused, true);
    await app.close();
    app.dispose();
    app = VaultController(vault, clock: clock, automaticCheck: false);
    await app.start();
    expect(app.sync, isNull);
    await app.unlock(pin);
    expect(app.sync!.paused, true);
  });

  test('HTTP fixture: newly imported file encrypts, publishes and reads back while interface locked', () async {
    await connect();
    final imports = app.imports!, sync = app.sync!, connection = app.github!;
    await imports.addFolder(photos.path);
    await imports.settled;
    app.lock();
    await photo('locked-upload');
    await waitFor(() => imports.mediaCount == 1);
    final id = imports.catalog().media().single['id'] as String;
    await waitFor(() => sync.receipt(id)?['status'] == 'verified');
    await sync.settled;
    expect(app.screen, VaultScreen.pin);
    expect(wire.writes, isNotEmpty);
    expect(
      wire.blobs.values.any((b) => latin1.decode(b).contains('locked-upload')),
      false,
    );
    await expectLater(
      sync.readRemotePhoto(id),
      throwsA(isA<SecurityFailure>()),
    );
    await app.unlock(pin);
    expect(app.github, same(connection));
    expect(app.sync, same(sync));
    final restored = await sync.readRemotePhoto(id);
    expect(restored, png);
    app.lock();
    expect(restored.every((b) => b == 0), true);
    await app.unlock(pin);
    final entered = Completer<void>(), release = Completer<void>();
    wire.beforeRequest = (uri, method) async {
      if (uri.path == '/user' && !entered.isCompleted) {
        entered.complete();
        await release.future;
      }
    };
    final lateView = sync.readRemotePhoto(id);
    final rejected = expectLater(lateView, throwsA(anything));
    await entered.future;
    app.lock();
    await app.unlock(pin);
    release.complete();
    await rejected;
    wire.beforeRequest = null;
    expect(app.sync, same(sync));
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('HTTP fixture: interface lock cancels authorization without destroying background service', () async {
    final entered = Completer<void>(), release = Completer<void>();
    wire.beforeRequest = (uri, method) async {
      if (uri.path == '/login/device/code') {
        entered.complete();
        await release.future;
      }
    };
    final github = app.github!;
    final pending = github.authorize();
    await entered.future;
    app.lock();
    release.complete();
    await pending;
    expect(app.github, same(github));
    expect(github.user, isNull);
    expect(github.waitingForAuthorization, false);
    expect(app.imports, isNotNull);
  });

  test('HTTP fixture: expiry during locked upload prevents publication and further requests', () async {
    await connect();
    final sync = app.sync!, imports = app.imports!;
    await imports.addFolder(photos.path);
    await imports.settled;
    var triggered = false;
    wire.beforeRequest = (uri, method) async {
      if (!triggered && method == 'POST' && uri.path.endsWith('/git/blobs')) {
        triggered = true;
        clock.advance(ReverificationGate.durationMillis);
        await app.checkAccess();
      }
    };
    app.lock();
    final originalHead = wire.refs['epa-data-v1'];
    await photo('expires-upload');
    await waitFor(() => triggered);
    await sync.settled;
    expect(app.screen, VaultScreen.photoPassword);
    expect(app.sync, isNull);
    expect(wire.refs['epa-data-v1'], originalHead);
    final writes = wire.writes.length;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(wire.writes.length, writes);
    expect(imports.token.cancelled, true);
  }, timeout: const Timeout(Duration(minutes: 4)));
}
