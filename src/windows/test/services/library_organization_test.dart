// Real SQLCipher/service integration with isolated artificial catalog records.
// File import and process restart are additionally covered by the process probe.
import 'dart:convert';
import 'dart:io';

import 'package:encrypted_photo_shared/model/library_query.dart';
import 'package:encrypted_photo_shared/security/vault_bootstrap_store.dart';
import 'package:encrypted_photo_shared/security/vault_credentials.dart';
import 'package:encrypted_photo_app/security/windows_data_protection.dart';
import 'package:encrypted_photo_app/services/library/library_organization_service.dart';
import 'package:encrypted_photo_app/services/import/windows_import_service.dart';
import 'package:encrypted_photo_app/storage/library_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  if (!Platform.isWindows) return;
  late Directory root;
  late File dbFile;
  late VaultCredentials credentials;
  late VaultCredentialSession session;
  late LibraryCatalog catalog;
  late WindowsImportService imports;
  late LibraryOrganizationService service;
  const marker = 'ARTIFICIAL_ORGANIZATION_PRIVATE';

  void seed(int count) => catalog.transaction(() {
    for (var i = 0; i < count; i++) {
      catalog.putMedia({
        'id': 'm$i',
        'observedAt': i,
        'kind': i.isEven ? 'photo' : 'video',
        'fileName': '$marker-$i.${i.isEven ? 'png' : 'mp4'}',
        'path': 'C:/$marker/$i',
        'local': true,
        'favorite': false,
        'size': 10,
        'version': 'artificial-version-$i',
        'autoUploadSuppressed': i == 0,
      });
    }
  });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('epa-organization-');
    WindowsDataProtection().preparePrivateDirectory('${root.path}/vault');
    credentials = VaultCredentials(
      VaultBootstrapStore(File('${root.path}/vault/vault.bootstrap')),
    );
    session = await credentials.initialize(
      password: 'artificial organization password',
      confirmation: 'artificial organization password',
    );
    dbFile = File('${root.path}/vault/catalog.db');
    catalog = LibraryCatalog.create(dbFile, session);
    imports = WindowsImportService(catalog: () => catalog);
    service = LibraryOrganizationService(imports);
  });
  tearDown(() async {
    service.dispose();
    imports.dispose();
    await imports.settled;
    catalog.close();
    credentials.revoke();
    await root.delete(recursive: true);
  });

  test(
    'album CRUD, favorite and memberships survive actual encrypted reopen',
    () async {
      seed(3);
      final a = await service.createAlbum('$marker A');
      final b = await service.createAlbum('$marker A');
      expect(a, isNot(b)); // Names are not identities.
      service.organize(['m0', 'm1'], albumId: a);
      service.organize(['m0'], favorite: true);
      service.renameAlbum(a, '$marker renamed');
      service.setHidden(a, true);
      catalog.close();
      final vaultId = session.vaultId;
      credentials.revoke();
      session = await credentials.unlock(
        password: 'artificial organization password',
        expectedVaultId: vaultId,
      );
      catalog = LibraryCatalog.open(dbFile, session);
      expect(catalog.albumById(a)!['name'], '$marker renamed');
      expect(catalog.albumMembers(a), ['m0', 'm1']);
      expect(catalog.mediaById('m0')!['favorite'], true);
      expect(service.count, 1);
      service.setQuery(LibraryQuery(albumId: a));
      service.organize(['m1'], albumId: a, remove: true);
      expect(catalog.albumMembers(a), ['m0']);
      service.deleteAlbum(a);
      expect(catalog.mediaCount, 3);
      expect(service.count, 3);
      expect(catalog.mediaById('m0')!['favorite'], true);
      expect(catalog.mediaById('m0')!['autoUploadSuppressed'], true);
      catalog.verifyIntegrity();
      final raw = latin1.decode(dbFile.readAsBytesSync());
      expect(raw, isNot(contains(marker)));
      expect(raw, isNot(startsWith('SQLite format 3')));
    },
  );

  test('any hidden album excludes aggregate search, counts and selection, not album access', () async {
    seed(4);
    final a = await service.createAlbum('a'),
        b = await service.createAlbum('b');
    service.organize(['m0', 'm1'], albumId: a);
    service.organize(['m1', 'm2'], albumId: b);
    service.organize(['m0', 'm1', 'm2'], favorite: true);
    service.selectAll();
    service.setHidden(a, true);
    service.setHidden(b, true);
    expect(service.selection.ids, {'m3'});
    expect(service.countFor(const LibraryQuery(favoritesOnly: true)), 0);
    expect(service.countFor(const LibraryQuery(search: '$marker-1')), 0);
    expect(service.countFor(LibraryQuery(albumId: a)), 2);
    service.setHidden(a, false);
    expect(service.count, 2); // m1 remains hidden by b.
    service.deleteAlbum(b);
    expect(service.count, 4);
    expect(service.countFor(const LibraryQuery(favoritesOnly: true)), 3);
    expect(catalog.mediaById('m0')!['autoUploadSuppressed'], true);
  });

  test('select all snapshots 257 offscreen mixed items and only IDs, no newly imported items', () async {
    seed(257);
    expect(service.page(0).length, 200);
    expect(service.page(1).length, 57);
    service.selectAll();
    final selected = service.selection.ids.toSet();
    expect(selected.length, 257);
    catalog.putMedia({
      'id': 'later',
      'observedAt': 1000,
      'kind': 'photo',
      'local': true,
      'favorite': false,
    });
    imports.requestScan();
    await imports.settled;
    expect(service.selection.ids, selected);
    expect(service.organize(selected, favorite: true), 257);
    expect(catalog.mediaById('later')!['favorite'], false);
    expect(service.countFor(const LibraryQuery(favoritesOnly: true)), 257);
    service.setQuery(const LibraryQuery(search: '-25'));
    expect(service.selection.ids, isEmpty);
    expect(service.selection.active, false);
    service.selectAll();
    expect(service.selection.ids.length, 8); // 25, 250..256
    service.clearSelection(exit: false);
    expect(service.selection.active, true);
    expect(service.selection.ids, isEmpty);
    expect(catalog.mediaById('later')!['favorite'], false);
  });

  test('SQL search is Unicode case-insensitive and binds literal wildcard/injection characters', () {
    seed(2);
    catalog.putMedia({
      ...catalog.mediaById('m0')!,
      'fileName': "ÉTÉ_100%'; --.png",
    });
    catalog.putMedia({
      ...catalog.mediaById('m1')!,
      'resources': [
        {'fileName': '实况配对.MOV'},
      ],
    });
    for (final term in ['été', '100%', "'; --"]) {
      expect(catalog.queryIds(LibraryQuery(search: term)), ['m0']);
    }
    expect(catalog.queryIds(const LibraryQuery(search: '实况配对.mov')), ['m1']);
    expect(catalog.queryIds(const LibraryQuery(search: '不存在')), isEmpty);
    expect(catalog.mediaCount, 2);
  });

  test('current status filters do not promote unverified old replica flags or reset suppression', () {
    seed(3);
    catalog.putMedia({
      ...catalog.mediaById('m2')!,
      'local': false,
      'sourceMissing': true,
      'remote': true,
      'remoteVersionVerified': 'artificial-version-2',
    });
    expect(
      catalog.queryIds(const LibraryQuery(filter: LibraryFilter.pending)),
      ['m1'],
    );
    expect(
      catalog
          .queryIds(const LibraryQuery(filter: LibraryFilter.localOnly))
          .toSet(),
      {'m0', 'm1'},
    );
    for (final filter in [LibraryFilter.synced, LibraryFilter.remoteOnly]) {
      expect(
        catalog.queryCount(LibraryQuery(filter: filter)),
        0,
        reason: 'Legacy remote flags are not authenticated target receipts',
      );
      service.setQuery(LibraryQuery(filter: filter));
    }
    service.setQuery(const LibraryQuery());
    service.organize(['m0', 'm1'], favorite: true);
    expect(catalog.mediaById('m0')!['autoUploadSuppressed'], true);
  });

  test(
    'execution revalidates frozen IDs against changed visibility and scope',
    () async {
      seed(3);
      final a = await service.createAlbum('a');
      service.organize(['m0'], albumId: a);
      service.selectAll();
      final frozen = service.selection.ids.toList();
      service.setHidden(a, true);
      expect(service.organize([...frozen, 'absent'], favorite: true), 2);
      expect(catalog.mediaById('m0')!['favorite'], false);
      service.setQuery(LibraryQuery(albumId: a));
      expect(service.organize(['m0', 'm1'], favorite: true), 1);
      service.setQuery(const LibraryQuery(favoritesOnly: true));
      service.selectAll();
      service.organize(service.selection.ids.toList(), favorite: false);
      expect(service.selection.ids, isEmpty);
      expect(service.count, 0);
    },
  );

  test('actual SQL write failure rolls back entire batch, reports failure and keeps prior data on reopen', () async {
    seed(3);
    catalog.close();
    final raw = sqlite3.open(dbFile.path);
    session.configureCatalogConnection((key) {
      final hex = key.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
      raw.execute('PRAGMA key = "x\'$hex\'"');
    });
    raw.execute(
      "CREATE TRIGGER organization_fail BEFORE UPDATE ON media WHEN NEW.id='m1' BEGIN SELECT RAISE(ABORT,'artificial injected failure'); END",
    );
    raw.close();
    catalog = LibraryCatalog.open(dbFile, session);
    service.selectAll();
    expect(
      () => service.organize(service.selection.ids, favorite: true),
      throwsA(isA<CatalogFailure>()),
    );
    catalog.close();
    catalog = LibraryCatalog.open(dbFile, session);
    expect(catalog.media().every((m) => m['favorite'] == false), true);
    expect(service.selection.ids.length, 3);
    catalog.verifyIntegrity();
  });

  test('deleted destination and revoked session cannot recreate albums or save stale operations', () async {
    seed(2);
    final a = await service.createAlbum('deleted');
    service.deleteAlbum(a);
    expect(
      () => service.organize(['m0'], albumId: a),
      throwsA(isA<CatalogFailure>()),
    );
    expect(catalog.albums(), isEmpty);
    expect(catalog.mediaCount, 2);
    credentials.revoke();
    expect(
      () => service.organize(['m0'], favorite: true),
      throwsA(isA<CatalogFailure>()),
    );
    expect(
      service.createAlbum('must not save'),
      throwsA(isA<CatalogFailure>()),
    );
  });
}
