import 'dart:convert';
import 'dart:io';

import 'package:encrypted_photo_app/app/vault_controller.dart';
import 'package:encrypted_photo_app/app/vault_location_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  if (!Platform.isWindows) return;
  late Directory scratch;
  late Directory defaults;
  late Directory parent;
  late VaultController app;
  const password = 'artificial custom location password';

  Future<void> initialize({String value = password}) => app.initialize(
    password: value,
    confirmation: value,
    pin: '7582',
    pinConfirmation: '7582',
  );

  Future<void> reopen() async {
    await app.close();
    app.dispose();
    app = VaultController(defaults, automaticCheck: false);
    await app.start();
  }

  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('epa-location-');
    defaults = Directory('${scratch.path}/default');
    parent = await Directory('${scratch.path}/中文 保存位置').create();
    app = VaultController(defaults, automaticCheck: false);
    await app.start();
    expect(app.screen, VaultScreen.setup, reason: app.message);
  });
  tearDown(() async {
    await app.close();
    app.dispose();
    await scratch.delete(recursive: true);
  });

  test('custom setup persists real encrypted files and reopens through sealed locator with PIN', () async {
    app.selectDataParent(parent.path);
    final target = app.setupDirectory;
    expect(await target.exists(), false);
    await initialize();
    expect(app.screen, VaultScreen.pin, reason: app.message);
    expect(VaultLocationStore.sameDirectory(app.directory, target), true);
    expect(await File('${defaults.path}/catalog.db').exists(), false);
    expect(await File('${defaults.path}/vault.bootstrap').exists(), false);
    expect(await File('${target.path}/pin.sealed').exists(), true);
    final locator = await File('${defaults.path}/data-location.sealed')
        .readAsBytes();
    expect(
      utf8.decode(locator, allowMalformed: true),
      isNot(contains(target.path)),
    );
    expect(
      (await app.catalogFile.readAsBytes()).take(15),
      isNot('SQLite format 3'.codeUnits),
    );
    await app.unlock('7582');
    expect(app.screen, VaultScreen.library, reason: app.message);
    final expires = app.expiresAt;
    app.catalog.putRecord('preferences', 'location-test', {
      'value': 'retained',
    });
    final other = VaultController(defaults, automaticCheck: false);
    try {
      await other.start();
      expect(other.screen, VaultScreen.failure);
      expect(other.message, contains('其他客户端'));
    } finally {
      await other.close();
      other.dispose();
    }
    await reopen();
    expect(app.screen, VaultScreen.pin, reason: app.message);
    expect(VaultLocationStore.sameDirectory(app.directory, target), true);
    await app.unlock('0000');
    expect(app.screen, VaultScreen.pin);
    await app.unlock('7582');
    expect(app.screen, VaultScreen.library, reason: app.message);
    expect(
      app.catalog.record('preferences', 'location-test')!['value'],
      'retained',
    );
    expect(app.expiresAt, expires);
  });

  test(
    'default setup and legacy restart work without a location record',
    () async {
      await initialize();
      expect(app.screen, VaultScreen.pin, reason: app.message);
      expect(
        await File('${defaults.path}/data-location.sealed').exists(),
        false,
      );
      final before = await app.catalogFile.readAsBytes();
      await reopen();
      expect(app.screen, VaultScreen.pin);
      expect(await app.catalogFile.readAsBytes(), before);
      app.selectDataParent(parent.path);
      expect(VaultLocationStore.sameDirectory(app.directory, defaults), true);
      await app.unlock('7582');
      expect(app.screen, VaultScreen.library);
    },
  );

  test('selection and restoring default make no custom files or persistent selection', () async {
    app.selectDataParent(parent.path);
    final target = app.setupDirectory;
    expect(await target.exists(), false);
    app.useDefaultDataDirectory();
    expect(
      VaultLocationStore.sameDirectory(app.setupDirectory, defaults),
      true,
    );
    app.selectDataParent(parent.path);
    await reopen();
    expect(app.screen, VaultScreen.setup);
    expect(
      VaultLocationStore.sameDirectory(app.setupDirectory, defaults),
      true,
    );
    expect(await target.exists(), false);
  });

  test(
    'invalid passwords do not create a selected directory or commit a locator',
    () async {
      app.selectDataParent(parent.path);
      final target = app.setupDirectory;
      await initialize(value: 'short');
      expect(app.screen, VaultScreen.setup);
      expect(await target.exists(), false);
      expect(
        await File('${defaults.path}/data-location.sealed').exists(),
        false,
      );
    },
  );

  test('occupied custom child is rejected and a selection-time race never overwrites files', () async {
    app.selectDataParent(parent.path);
    final target = app.setupDirectory;
    await target.create();
    final kept = await File('${target.path}/keep.txt')
        .writeAsString('untouched');
    await initialize();
    expect(app.screen, VaultScreen.setup);
    expect(app.message, contains('未覆盖'));
    expect(await kept.readAsString(), 'untouched');
    expect(await File('${target.path}/catalog.db').exists(), false);
    expect(await File('${defaults.path}/data-location.sealed').exists(), false);
    app.useDefaultDataDirectory();
    app.selectDataParent(parent.path);
    expect(
      VaultLocationStore.sameDirectory(app.setupDirectory, defaults),
      true,
    );
    expect(app.message, contains('已有数据未修改'));
  });

  test('missing selected directory fails without recreating it; restored directory opens again', () async {
    app.selectDataParent(parent.path);
    await initialize();
    expect(app.screen, VaultScreen.pin, reason: app.message);
    final target = app.directory;
    await app.close();
    final moved = await target.rename('${parent.path}/retained-copy');
    await reopen();
    expect(app.screen, VaultScreen.failure);
    expect(await target.exists(), false);
    expect(await File('${defaults.path}/catalog.db').exists(), false);
    await app.close();
    await moved.rename(target.path);
    await reopen();
    expect(app.screen, VaultScreen.pin, reason: app.message);
    await app.unlock('7582');
    expect(app.screen, VaultScreen.library, reason: app.message);
  });

  for (final name in ['vault.bootstrap', 'catalog.db']) {
    test(
      'missing custom $name never starts new setup or overwrites surviving files',
      () async {
        app.selectDataParent(parent.path);
        await initialize();
        expect(app.screen, VaultScreen.pin, reason: app.message);
        final target = app.directory;
        await app.close();
        final original = File('${target.path}/$name');
        final bytes = await original.readAsBytes();
        final retained = await original.rename('${target.path}/retained.bin');
        await reopen();
        expect(app.screen, VaultScreen.failure);
        expect(await original.exists(), false);
        expect(await retained.readAsBytes(), bytes);
        expect(await File('${defaults.path}/catalog.db').exists(), false);
      },
    );
  }

  test(
    'corrupt locator fails closed and preserves the custom catalog',
    () async {
      app.selectDataParent(parent.path);
      await initialize();
      expect(app.screen, VaultScreen.pin, reason: app.message);
      final catalog = app.catalogFile;
      await app.close();
      final before = await catalog.readAsBytes();
      await File('${defaults.path}/data-location.sealed')
          .writeAsBytes([1, 2, 3], flush: true);
      await reopen();
      expect(app.screen, VaultScreen.failure);
      expect(await catalog.readAsBytes(), before);
      expect(await File('${defaults.path}/catalog.db').exists(), false);
    },
  );

  test(
    'network and nonexistent parents are rejected without changing selection',
    () async {
      for (final invalid in [
        r'\\server\share',
        '${scratch.path}/missing',
        'relative',
      ]) {
        app.selectDataParent(invalid);
        expect(app.message, contains('无法使用所选位置'));
        expect(
          VaultLocationStore.sameDirectory(app.setupDirectory, defaults),
          true,
        );
      }
    },
  );

  test('interruption after locator commit preserves the incomplete target and refuses setup', () async {
    app.selectDataParent(parent.path);
    final target = app.setupDirectory;
    await app.close();
    final locations = VaultLocationStore(defaults);
    try {
      await locations.open();
      locations.prepareNew(target);
      await locations.save(target);
    } finally {
      await locations.close();
    }
    await reopen();
    expect(app.screen, VaultScreen.failure);
    expect(await target.exists(), true);
    expect(await target.list().isEmpty, true);
    expect(await File('${defaults.path}/catalog.db').exists(), false);
  });
}
