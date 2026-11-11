import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:encrypted_photo_shared/security/vault_bootstrap_store.dart';
import 'package:encrypted_photo_shared/security/vault_credentials.dart';
import 'package:encrypted_photo_app/security/windows_data_protection.dart';
import 'package:encrypted_photo_app/storage/library_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

Matcher catalogFailure(CatalogFailureCode code) =>
    throwsA(isA<CatalogFailure>().having((e) => e.code, 'code', code));

void main() {
  if (!Platform.isWindows) return;
  late Directory scratch;
  late File file;
  late VaultCredentials credentials;
  late VaultCredentialSession session;
  LibraryCatalog? catalog;
  const password = 'artificial catalog password river';
  const marker = 'ARTIFICIAL_PRIVATE_CATALOG_2026';

  Map<String, Object?> media(String id) => {
    'id': id,
    'kind': 'photo',
    'observedAt': 1700000000000,
    'fileName': '$marker-$id.jpg',
    'path': 'C:/$marker/$id.jpg',
    'favorite': true,
    'resources': [
      {'role': 'image', 'location': 'C:/$marker/$id.jpg'},
    ],
  };

  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('epa-catalog-test-');
    final root = Directory('${scratch.path}/private');
    WindowsDataProtection().preparePrivateDirectory(root.path);
    credentials = VaultCredentials(
      VaultBootstrapStore(File('${root.path}/vault.bootstrap')),
    );
    session = await credentials.initialize(
      password: password,
      confirmation: password,
    );
    file = File('${root.path}/catalog.db');
    catalog = LibraryCatalog.create(file, session);
  });
  tearDown(() async {
    catalog?.close();
    credentials.revoke();
    await scratch.delete(recursive: true);
  });

  test('actual SQLCipher catalog persists media, sources, albums, tracking and jobs', () async {
    catalog!.transaction(() {
      catalog!.putMedia(media('one'));
      catalog!.putSource(id: 'folder', path: 'C:/$marker');
      catalog!.putAlbum(
        id: 'album',
        name: '$marker album',
        hidden: true,
        members: ['one'],
      );
      catalog!.putRecord('jobs', 'job', {
        'id': 'job',
        'status': 'queued',
        'mediaId': 'one',
      });
      catalog!.putRecord('tracking', 'folder', {
        'observed': ['one'],
      });
    });
    catalog!.verifyIntegrity();
    catalog!.close();
    final id = session.vaultId;
    credentials.revoke();
    session = await credentials.unlock(password: password, expectedVaultId: id);
    catalog = LibraryCatalog.open(file, session);
    expect(catalog!.mediaCount, 1);
    expect(catalog!.media().single['fileName'], '$marker-one.jpg');
    expect(catalog!.sources().single['path'], 'C:/$marker');
    expect(catalog!.albums().single['hidden'], 1);
    expect(catalog!.albumMembers('album'), ['one']);
    expect(catalog!.record('jobs', 'job')!['status'], 'queued');
    final bytes = await file.readAsBytes();
    expect(latin1.decode(bytes), isNot(startsWith('SQLite format 3')));
    expect(latin1.decode(bytes), isNot(contains(marker)));
  });

  test('transaction failure rolls back a complete organization update', () {
    catalog!.putMedia(media('one'));
    catalog!.putAlbum(
      id: 'old',
      name: 'old album',
      hidden: false,
      members: ['one'],
    );
    expect(
      () => catalog!.transaction<void>(() {
        catalog!.deleteAlbum('old');
        catalog!.putAlbum(
          id: 'new',
          name: 'new album',
          hidden: true,
          members: ['one'],
        );
        catalog!.putRecord('tracking', 'source', {'generation': 2});
        throw const CatalogFailure(CatalogFailureCode.writeFailed);
      }),
      catalogFailure(CatalogFailureCode.writeFailed),
    );
    catalog!.close();
    catalog = LibraryCatalog.open(file, session);
    expect(catalog!.albums().single['id'], 'old');
    expect(catalog!.albumMembers('old'), ['one']);
    expect(catalog!.record('tracking', 'source'), isNull);
    expect(catalog!.mediaCount, 1);
  });

  test('invalid membership cannot half-save an album and deleting an album keeps media', () {
    expect(
      () => catalog!.putAlbum(
        id: 'invalid',
        name: 'invalid',
        hidden: true,
        members: ['missing-media'],
      ),
      catalogFailure(CatalogFailureCode.writeFailed),
    );
    expect(catalog!.albums(), isEmpty);
    catalog!.putMedia(media('one'));
    catalog!.putAlbum(
      id: 'valid',
      name: 'valid',
      hidden: false,
      members: ['one'],
    );
    catalog!.deleteAlbum('valid');
    expect(catalog!.albums(), isEmpty);
    expect(catalog!.mediaCount, 1);
  });

  test(
    'wrong key and missing key fail without replacing actual catalog bytes',
    () async {
      catalog!.putMedia(media('one'));
      catalog!.close();
      final before = await file.readAsBytes();
      final other = VaultCredentials(
        VaultBootstrapStore(File('${file.parent.path}/other.bootstrap')),
      );
      try {
        final wrong = await other.initialize(
          password: password,
          confirmation: password,
        );
        expect(
          () => LibraryCatalog.open(file, wrong),
          catalogFailure(CatalogFailureCode.unreadable),
        );
      } finally {
        other.revoke();
      }
      final raw = sqlite3.open(file.path, mode: OpenMode.readOnly);
      try {
        expect(
          () => raw.select('SELECT * FROM sqlite_master'),
          throwsA(isA<SqliteException>()),
        );
      } finally {
        raw.close();
      }
      expect(await file.readAsBytes(), before);
    },
  );

  test(
    'revoking the credential session closes the native catalog immediately',
    () {
      catalog!.putMedia(media('one'));
      credentials.revoke();
      expect(
        () => catalog!.mediaCount,
        catalogFailure(CatalogFailureCode.closed),
      );
      expect(
        () => catalog!.putMedia(media('two')),
        catalogFailure(CatalogFailureCode.closed),
      );
      final absent = File('${file.parent.path}/should-not-exist.db');
      expect(
        () => LibraryCatalog.create(absent, session),
        catalogFailure(CatalogFailureCode.closed),
      );
      expect(absent.existsSync(), isFalse);
    },
  );

  test(
    'unknown schema version is rejected without modifying the existing file',
    () async {
      catalog!.putMedia(media('one'));
      catalog!.close();
      final raw = sqlite3.open(file.path, mode: OpenMode.readWrite);
      try {
        session.configureCatalogConnection((key) {
          final hex = key
              .map((v) => v.toRadixString(16).padLeft(2, '0'))
              .join();
          raw.execute('PRAGMA key = "x\'$hex\'"');
        });
        raw.execute('PRAGMA user_version = 999');
      } finally {
        raw.close();
      }
      final before = await file.readAsBytes();
      expect(
        () => LibraryCatalog.open(file, session),
        catalogFailure(CatalogFailureCode.unsupportedVersion),
      );
      expect(await file.readAsBytes(), before);
    },
  );

  test(
    'modified encrypted page and partial database are preserved and refused',
    () async {
      catalog!.putMedia(media('one'));
      catalog!.close();
      final damaged = Uint8List.fromList(await file.readAsBytes())..[100] ^= 1;
      await file.writeAsBytes(damaged, flush: true);
      expect(
        () => LibraryCatalog.open(file, session),
        catalogFailure(CatalogFailureCode.unreadable),
      );
      expect(await file.readAsBytes(), damaged);
      final partial = File('${file.parent.path}/partial.db');
      await partial.create();
      expect(
        () => LibraryCatalog.open(partial, session),
        catalogFailure(CatalogFailureCode.unreadable),
      );
      expect(
        () => LibraryCatalog.create(partial, session),
        catalogFailure(CatalogFailureCode.alreadyExists),
      );
      expect(await partial.length(), 0);
    },
  );

  test(
    'rollback journal contains actual encrypted pages and no artificial marker',
    () {
      for (var i = 0; i < 40; i++) {
        catalog!.putMedia(media('media-$i'));
      }
      var observedJournal = false;
      catalog!.transaction(() {
        for (var i = 0; i < 40; i++) {
          catalog!.putMedia({...media('media-$i'), 'extra': marker * 40});
        }
        final journal = File('${file.path}-journal');
        expect(journal.existsSync(), isTrue);
        final bytes = journal.readAsBytesSync();
        expect(bytes.length, greaterThan(4096));
        expect(latin1.decode(bytes), isNot(contains(marker)));
        observedJournal = true;
      });
      expect(observedJournal, isTrue);
      catalog!.verifyIntegrity();
    },
  );

  Database rawOpen() {
    final db = sqlite3.open(file.path, mode: OpenMode.readWrite);
    session.configureCatalogConnection((key) {
      final hex = key.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
      db.execute('PRAGMA key = "x\'$hex\'"');
    });
    return db;
  }

  void observe(String path, {String epoch = 'scan', bool force = true}) {
    catalog!.observeImport(
      source: 'import-source',
      path: path,
      size: 68,
      modified: 1,
      epoch: epoch,
      now: 0,
      quietMilliseconds: 0,
      force: force,
    );
  }

  String commit(
    String path,
    String id, {
    String? native,
    int created = 12,
    String version = 'test-version',
  }) => catalog!.commitImport(
    source: 'import-source',
    path: path,
    newId: id,
    nativeId: native,
    created: created,
    observed: {...media(id), 'path': path, 'version': version, 'size': 68},
  );

  void source() => catalog!.putSource(
    id: 'import-source',
    path: 'C:/$marker',
    state: {'epoch': 'scan'},
  );

  test(
    'identity fallback reuses only the same path, creation and full version',
    () {
      source();
      final path = 'C:/$marker/fallback.png';
      observe(path);
      expect(commit(path, 'first'), 'first');
      observe(path);
      expect(commit(path, 'unused'), 'first');
      observe(path);
      expect(commit(path, 'changed', version: 'new-bytes'), 'changed');
      expect(catalog!.mediaById('first')!['local'], false);
      observe('$path-copy');
      expect(commit('$path-copy', 'copy', version: 'new-bytes'), 'copy');
      expect(catalog!.mediaCount, 3);
    },
  );

  test('explicitly missing identity never resurrects old organization', () {
    source();
    final path = 'C:/$marker/reappeared.png';
    observe(path);
    commit(path, 'old', native: 'native-file');
    catalog!.putAlbum(
      id: 'kept',
      name: 'kept',
      hidden: false,
      members: ['old'],
    );
    expect(catalog!.markMissingImportPage('import-source', 'empty'), 1);
    observe(path);
    expect(commit(path, 'new', native: 'native-file'), 'new');
    expect(catalog!.albumMembers('kept'), ['old']);
    expect(catalog!.mediaById('old')!['local'], false);
    expect(catalog!.mediaCount, 2);
  });

  test(
    'import candidate and media commit rollback together on database failure',
    () {
      source();
      final path = 'C:/$marker/atomic.png';
      observe(path);
      catalog!.close();
      final raw = rawOpen();
      raw.execute(
        "CREATE TRIGGER fail_import BEFORE UPDATE ON import_files WHEN NEW.status='ready' BEGIN SELECT RAISE(ABORT,'artificial fault'); END",
      );
      raw.close();
      catalog = LibraryCatalog.open(file, session);
      expect(
        () => commit(path, 'must-rollback', native: 'native'),
        catalogFailure(CatalogFailureCode.writeFailed),
      );
      catalog!.close();
      catalog = LibraryCatalog.open(file, session);
      expect(catalog!.mediaCount, 0);
      expect(catalog!.pendingImportCount, 1);
      catalog!.close();
      final repaired = rawOpen();
      repaired.execute('DROP TRIGGER fail_import');
      repaired.close();
      catalog = LibraryCatalog.open(file, session);
      expect(commit(path, 'retry', native: 'native'), 'retry');
      expect(catalog!.pendingImportCount, 0);
      catalog!.verifyIntegrity();
    },
  );

  test('persisted queue and media pages stay bounded without omissions', () {
    source();
    for (var i = 0; i < 257; i++) {
      observe('C:/$marker/$i.png');
    }
    expect(catalog!.pendingImportCount, 257);
    expect(catalog!.importCandidates(0).length, 128);
    while (catalog!.pendingImportCount > 0) {
      for (final row in catalog!.importCandidates(0)) {
        final path = row['path'] as String;
        commit(path, path);
      }
    }
    catalog!.close();
    catalog = LibraryCatalog.open(file, session);
    final first = catalog!.media();
    final second = catalog!.media(offset: 200);
    expect(first.length, 200);
    expect(second.length, 57);
    expect(
      {...first.map((m) => m['id']), ...second.map((m) => m['id'])}.length,
      257,
    );
    expect(catalog!.markMissingImportPage('import-source', 'empty'), 100);
    expect(catalog!.markMissingImportPage('import-source', 'empty'), 100);
    expect(catalog!.markMissingImportPage('import-source', 'empty'), 57);
    expect(catalog!.markMissingImportPage('import-source', 'empty'), 0);
    expect(catalog!.mediaCount, 257);
  });

  test('supported v1 catalog upgrades in encrypted transaction and preserves all existing records', () {
    catalog!.putMedia(media('one'));
    catalog!.putSource(id: 'source', path: 'C:/$marker');
    catalog!.putAlbum(
      id: 'album',
      name: marker,
      hidden: true,
      members: ['one'],
    );
    catalog!.close();
    final raw = rawOpen();
    try {
      raw.execute('ALTER TABLE sources DROP COLUMN state');
      raw.execute('DROP TABLE import_files');
      raw.execute('PRAGMA user_version = 1');
    } finally {
      raw.close();
    }
    catalog = LibraryCatalog.open(file, session);
    expect(catalog!.sources().single['state'], isEmpty);
    expect(catalog!.mediaCount, 1);
    expect(catalog!.albumMembers('album'), ['one']);
    catalog!.putSource(
      id: 'source',
      path: 'C:/$marker',
      state: {'lastScanCompleted': true},
    );
    catalog!.close();
    catalog = LibraryCatalog.open(file, session);
    expect(catalog!.sources().single['state'], {'lastScanCompleted': true});
    catalog!.verifyIntegrity();
  });

  test('actual v2 catalog upgrades to import schema without changing existing media', () {
    catalog!.putMedia(media('one'));
    catalog!.putSource(id: 'source', path: 'C:/$marker', state: {'kept': true});
    catalog!.close();
    final raw = rawOpen();
    try {
      raw.execute('DROP TABLE import_files');
      raw.execute('PRAGMA user_version=2');
    } finally {
      raw.close();
    }
    catalog = LibraryCatalog.open(file, session);
    expect(catalog!.mediaCount, 1);
    expect(catalog!.sources().single['state'], {'kept': true});
    expect(catalog!.pendingImportCount, 0);
    catalog!.verifyIntegrity();
  });

  test('inconsistent migration source fails without replacing the old database', () async {
    catalog!.putMedia(media('one'));
    catalog!.close();
    final raw = rawOpen();
    try {
      raw.execute('PRAGMA user_version = 1');
    } finally {
      raw.close();
    }
    // Deliberately inconsistent fixture: source claims v1 but already has v2's
    // column. The real ALTER must fail and preserve the prior encrypted bytes.
    final before = await file.readAsBytes();
    expect(
      () => LibraryCatalog.open(file, session),
      catalogFailure(CatalogFailureCode.unreadable),
    );
    expect(await file.readAsBytes(), before);
  });
}
