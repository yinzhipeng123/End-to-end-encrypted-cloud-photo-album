import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:encrypted_photo_shared/security/vault_bootstrap_store.dart';
import 'package:encrypted_photo_shared/security/vault_credentials.dart';
import 'package:encrypted_photo_app/security/windows_data_protection.dart';
import 'package:encrypted_photo_app/storage/library_catalog.dart';
import 'package:encrypted_photo_app/services/import/windows_source_reader.dart';
import 'package:encrypted_photo_app/services/import/windows_import_service.dart';

Future<void> until(bool Function() check) async {
  final limit = DateTime.now().add(const Duration(seconds: 25));
  while (!check()) {
    if (DateTime.now().isAfter(limit))
      throw StateError('Import condition timed out');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  if (!Platform.isWindows) return;
  WindowsSourceReader.setTestLibrary(
    File('build/source-reader/Release/epa_source_reader.dll').absolute.path,
  );
  late Directory scratch, photos;
  late File database;
  late VaultCredentials credentials;
  late VaultCredentialSession session;
  late LibraryCatalog catalog;
  late WindowsImportService service;
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=',
  );
  const password = 'artificial Windows import password';
  Future<File> photo(String name) async {
    final file = File('${photos.path}/$name');
    await file.parent.create(recursive: true);
    return file.writeAsBytes(png);
  }

  Future<void> complete() => until(
    () => catalog.sources().every(
      (s) => (s['state'] as Map)['phase'] == 'complete',
    ),
  );
  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('epa-import-real-');
    photos = await Directory('${scratch.path}/PRIVATE_SOURCE_MARKER').create();
    final vault = Directory('${scratch.path}/vault');
    WindowsDataProtection().preparePrivateDirectory(vault.path);
    credentials = VaultCredentials(
      VaultBootstrapStore(File('${vault.path}/vault.bootstrap')),
    );
    session = await credentials.initialize(
      password: password,
      confirmation: password,
    );
    database = File('${vault.path}/catalog.db');
    catalog = LibraryCatalog.create(database, session);
    service = WindowsImportService(catalog: () => catalog)..start();
  });
  tearDown(() async {
    service.dispose();
    await service.settled;
    catalog.close();
    credentials.revoke();
    await scratch.delete(recursive: true);
  });
  test('recursive real files persist in SQLCipher; bytes stay unchanged and no path plaintext', () async {
    final one = await photo('one.png');
    await photo('子目录/再下一层/two.png');
    await service.addFolder(photos.path);
    await until(() => catalog.mediaCount == 2);
    await complete();
    expect(await one.readAsBytes(), png);
    expect(catalog.media().every((r) => r['takenAt'] == null), true);
    expect(
      latin1.decode(await database.readAsBytes()),
      isNot(contains('PRIVATE_SOURCE_MARKER')),
    );
    service.dispose();
    await service.settled;
    catalog.close();
    catalog = LibraryCatalog.open(database, session);
    expect(catalog.mediaCount, 2);
    expect(catalog.sources().length, 1);
    catalog.verifyIntegrity();
  });
  test('actual watcher imports a new nested directory and repeated events do not duplicate', () async {
    await service.addFolder(photos.path);
    await until(() => catalog.sources().isNotEmpty);
    await complete();
    final item = await photo('after/start.png');
    await until(() => catalog.mediaCount == 1);
    await complete();
    await item.setLastModified(DateTime.now());
    service.requestScan();
    await service.settled;
    await until(() => catalog.pendingImportCount == 0);
    await complete();
    expect(catalog.mediaCount, 1);
  });
  test('same-volume move preserves identity, organization and explicit no-auto-upload intent', () async {
    var file = await photo('before.png');
    await service.addFolder(photos.path);
    await until(() => catalog.mediaCount == 1);
    await complete();
    final old = catalog.media().single;
    catalog.putMedia({...old, 'favorite': true, 'autoUploadSuppressed': true});
    catalog.putAlbum(
      id: 'album',
      name: '人工相册',
      hidden: true,
      members: [old['id'] as String],
    );
    await Directory('${photos.path}/moved').create();
    file = await file.rename('${photos.path}/moved/after.png');
    service.requestScan();
    await until(
      () =>
          catalog.media().single['path'] ==
          WindowsSourceReader.absolute(file.path),
    );
    await complete();
    expect(catalog.mediaCount, 1);
    expect(catalog.media().single['favorite'], true);
    expect(catalog.media().single['autoUploadSuppressed'], true);
    expect(catalog.albumMembers('album'), [old['id']]);
  });
  test('independent equal-byte copies remain separate; overlapping roots do not duplicate', () async {
    final one = await photo('nested/one.png');
    await one.copy('${photos.path}/copy.png');
    await service.addFolder(photos.path);
    await until(() => catalog.mediaCount == 2);
    await complete();
    await service.addFolder('${photos.path}/nested');
    await until(() => catalog.sources().length == 2);
    await complete();
    expect(catalog.mediaCount, 2);
  });
  test('actual close/reopen imports files added while stopped and retains organization', () async {
    await photo('one.png');
    await service.addFolder(photos.path);
    await until(() => catalog.mediaCount == 1);
    await complete();
    final old = catalog.media().single;
    catalog.putMedia({...old, 'favorite': true});
    service.dispose();
    await service.settled;
    catalog.close();
    await photo('offline/two.png');
    catalog = LibraryCatalog.open(database, session);
    service = WindowsImportService(catalog: () => catalog)..start();
    await until(() => catalog.mediaCount == 2);
    await complete();
    expect(catalog.mediaById(old['id'] as String)!['favorite'], true);
  });
  test('externally deleted file is missing; source directory outage does not erase records', () async {
    final file = await photo('one.png');
    await service.addFolder(photos.path);
    await until(() => catalog.mediaCount == 1);
    await complete();
    final old = catalog.media().single;
    catalog.putRecord('replicas', 'artificial-prior-record', {
      'mediaId': old['id'],
      'status': 'historical-test-record',
    });
    await file.delete();
    service.requestScan();
    await until(() => catalog.media().single['sourceMissing'] == true);
    expect(catalog.record('replicas', 'artificial-prior-record'), isNotNull);
    final moved = await photos.rename('${scratch.path}/source-offline');
    service.requestScan();
    await service.settled;
    await until(
      () => (catalog.sources().single['state'] as Map)['phase'] == 'incomplete',
    );
    expect(catalog.mediaCount, 1);
    await moved.rename(photos.path);
  });
  test(
    'busy writer stays pending then imports only after writer closes',
    () async {
      final file = await photo('busy.png');
      final writer = await file.open(mode: FileMode.append);
      try {
        await service.addFolder(photos.path);
        await Future<void>.delayed(const Duration(seconds: 4));
        expect(catalog.mediaCount, 0);
        expect(catalog.pendingImportCount, 1);
      } finally {
        await writer.close();
      }
      await until(() => catalog.mediaCount == 1);
      await complete();
    },
  );
  test('revocation during quiet period stops work, reopening resumes persisted candidates', () async {
    await photo('one.png');
    await service.addFolder(photos.path);
    await until(() => catalog.pendingImportCount == 1);
    service.dispose();
    await service.settled;
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(catalog.mediaCount, 0);
    service = WindowsImportService(catalog: () => catalog)..start();
    await until(() => catalog.mediaCount == 1);
    await complete();
  });
  test('same native file new bytes keep media id but never inherit old version verification', () async {
    final file = await photo('one.png');
    await service.addFolder(photos.path);
    await until(() => catalog.mediaCount == 1);
    await complete();
    final old = catalog.media().single;
    catalog.putMedia({
      ...old,
      'remoteVersionVerified': old['version'],
      'favorite': true,
    });
    final changed = Uint8List.fromList(png)..[30] ^= 1;
    await file.writeAsBytes(changed);
    service.requestScan();
    await until(() => catalog.media().single['version'] != old['version']);
    expect(catalog.media().single['id'], old['id']);
    expect(catalog.media().single['remoteVersionVerified'], isNull);
    expect(catalog.media().single['favorite'], true);
  });
  test('extension disguise has an explicit failure and does not appear as imported media', () async {
    await File('${photos.path}/fake.jpg').writeAsString('not media');
    await service.addFolder(photos.path);
    await until(
      () =>
          catalog.sourceImportCounts().any((r) => r['status'] == 'unsupported'),
    );
    expect(catalog.mediaCount, 0);
    expect(
      (catalog.sources().single['state'] as Map)['phase'],
      isNot('complete'),
    );
  });

  test(
    'preview uses real bytes; release and revocation wipe retained buffers',
    () async {
      await photo('preview.png');
      await service.addFolder(photos.path);
      await until(() => catalog.mediaCount == 1);
      final id = catalog.media().single['id'] as String;
      final first = await service.preview(id);
      expect(first, png);
      service.releasePreview(first);
      expect(first!.every((b) => b == 0), true);
      final second = await service.preview(id);
      expect(second, png);
      service.dispose();
      expect(second!.every((b) => b == 0), true);
      await expectLater(service.preview(id), throwsA(isA<SourceFailure>()));
    },
  );

  test('hard links share a media item and losing one reference keeps the other available', () async {
    final original = await photo('original.png');
    final hard = File('${photos.path}/hard.png');
    final made = await Process.run('fsutil', [
      'hardlink',
      'create',
      hard.path,
      original.path,
    ]);
    expect(made.exitCode, 0);
    await service.addFolder(photos.path);
    await until(
      () => catalog.mediaCount == 1 && catalog.pendingImportCount == 0,
    );
    await complete();
    expect(catalog.sourceImportCounts().single['count'], 2);
    await original.delete();
    service.requestScan();
    await until(
      () => catalog.sourceImportCounts().any((r) => r['status'] == 'missing'),
    );
    expect(catalog.media().single['local'], true);
    expect(
      catalog.media().single['path'],
      WindowsSourceReader.absolute(hard.path),
    );
  });

  test(
    'lost source watcher recovers when a deleted empty directory is recreated',
    () async {
      await service.addFolder(photos.path);
      await complete();
      await photos.delete();
      await until(
        () => (catalog.sources().single['state'] as Map)['complete'] == false,
      );
      await photo('returned/new.png');
      // No manual requestScan: the real watcher error/end recovery schedules this.
      await until(() => catalog.mediaCount == 1);
      await complete();
      expect(catalog.sources().length, 1);
    },
  );
}
