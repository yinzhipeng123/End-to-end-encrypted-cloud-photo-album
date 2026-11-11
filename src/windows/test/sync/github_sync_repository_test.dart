import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:encrypted_photo_app/repositories/github_api.dart';
import 'package:encrypted_photo_app/repositories/github_connection.dart';
import 'package:encrypted_photo_shared/security/vault_bootstrap_store.dart';
import 'package:encrypted_photo_shared/security/vault_credentials.dart';
import 'package:encrypted_photo_shared/security/vault_crypto.dart';
import 'package:encrypted_photo_app/security/windows_data_protection.dart';
import 'package:encrypted_photo_app/security/windows_protected_store.dart';
import 'package:encrypted_photo_app/storage/library_catalog.dart';
import 'package:encrypted_photo_app/services/import/windows_import_service.dart';
import 'package:encrypted_photo_app/services/import/windows_source_reader.dart';
import 'package:encrypted_photo_app/sync/github_sync_repository.dart';
import 'package:encrypted_photo_shared/sync/sync_format.dart';
import 'package:encrypted_photo_app/sync/sync_object_store.dart';
import 'package:encrypted_photo_app/sync/sync_resource_preparer.dart';
import 'package:encrypted_photo_app/sync/windows_sync_service.dart';
import 'package:encrypted_photo_shared/security/security_failure.dart';
import 'package:encrypted_photo_app/sync/sync_cipher_cache.dart';
import 'package:encrypted_photo_app/sync/repository_vault_recovery.dart';
import 'package:encrypted_photo_app/app/vault_controller.dart';
import 'package:encrypted_photo_shared/model/library_query.dart';

import '../support/git_database_transport.dart';
import '../services/windows_import_service_test.dart' show until;

void main() {
  if (!Platform.isWindows) return;
  WindowsSourceReader.setTestLibrary(
    File('build/source-reader/Release/epa_source_reader.dll').absolute.path,
  );
  late Directory scratch, vault, photos;
  late VaultCredentials credentials;
  late VaultCredentialSession session;
  late LibraryCatalog catalog;
  late WindowsImportService imports;
  late GitHubConnection connection;
  late GitDatabaseTransport wire;
  late VaultCrypto crypto;
  late SyncObjectStore objects;
  const password = 'isolated sync integration password';
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=',
  );
  GitHubSyncRepository repo(GitHubGitAccess access) => GitHubSyncRepository(
    access: access,
    catalog: () => catalog,
    session: session,
    objects: objects,
    crypto: crypto,
  );
  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('epa-sync-integration-');
    vault = Directory('${scratch.path}/vault');
    WindowsDataProtection().preparePrivateDirectory(vault.path);
    photos = await Directory('${scratch.path}/original').create();
    credentials = VaultCredentials(
      VaultBootstrapStore(
        File('${vault.path}/vault.bootstrap'),
        commitReplacement: WindowsDataProtection().replacePrivateFile,
      ),
    );
    session = await credentials.initialize(
      password: password,
      confirmation: password,
    );
    crypto = await VaultCrypto.load();
    catalog = LibraryCatalog.create(File('${vault.path}/catalog.db'), session);
    imports = WindowsImportService(catalog: () => catalog)..start();
    wire = GitDatabaseTransport();
    final protected = WindowsProtectedStore(vault, WindowsDataProtection());
    await protected.initialize();
    connection = GitHubConnection(
      catalog: () => catalog,
      protectedStore: protected,
      localBinding: Uint8List(32),
      api: GitHubApi(transport: wire),
    );
    await connection.authorize();
    expect(connection.repositories.length, 1, reason: connection.message);
    await connection.selectRepository(connection.repositories.single);
    objects = SyncObjectStore(vault, () {
      if (session.isClosed) throw StateError('closed');
    });
  });
  tearDown(() async {
    connection.dispose();
    imports.dispose();
    await imports.settled;
    catalog.close();
    credentials.revoke();
    await scratch.delete(recursive: true);
  });
  test('actual source -> encrypted spool/catalog -> Git protocol -> password-only independent restore; lost publish reply reconciles', () async {
    // The server is an HTTP fixture, not real GitHub platform acceptance.
    final original = await File('${photos.path}/PRIVATE_FILENAME.png')
        .writeAsBytes(png);
    await imports.addFolder(photos.path);
    await until(() => catalog.mediaCount == 1);
    final media = catalog.media().single;
    final task = SyncFormat.newId(crypto), revision = SyncFormat.newId(crypto);
    await connection.withRepository((a) => repo(a).initialize());
    expect(wire.refs.keys, containsAll(['main', 'epa-data-v1']));
    final mainTree =
        wire.trees[(wire.commits[wire.refs['main']]!['tree'] as Map)['sha']]!;
    expect(mainTree.keys, ['.encrypted-photo-app/initialized-v1.txt']);
    final prepared = await SyncResourcePreparer(
      catalog: () => catalog,
      session: () => session,
      imports: imports,
      objects: objects,
      checkAccess: () {},
    ).prepare(task, media, revision, SourceCancellation());
    expect(await original.readAsBytes(), png);
    expect(catalog.record('jobs', 'resource:$task'), isNotNull);
    // Reopen SQLCipher and retain actual checkpoints before any upload.
    imports.dispose();
    await imports.settled;
    catalog.close();
    catalog = LibraryCatalog.open(File('${vault.path}/catalog.db'), session);
    imports = WindowsImportService(catalog: () => catalog)..start();
    Map<String, Object?>? resourceRef;
    await connection.withRepository((a) async {
      resourceRef = await repo(a).uploadResource(task, prepared);
    });
    wire.loseNextPublishReply = true;
    await expectLater(
      connection.withRepository(
        (a) => repo(a).publishMedia(task, media, revision, resourceRef!),
      ),
      throwsA(isA<RepositoryFailure>()),
    );
    final commitsAfterLostReply = wire.commits.length;
    final result = await connection.withRepository(
      (a) => repo(a).publishMedia(task, media, revision, resourceRef!),
    );
    expect(result['revisionId'], revision);
    expect(
      wire.commits.length,
      commitsAfterLostReply,
      reason: 'No duplicate commit after unknown outcome',
    );
    final ref = SyncFormat.map(result['media']);
    // No source file or sender auxiliary/catalog copied to the new receiver.
    await original.delete();
    final recoveryBytes = await connection.withRepository((access) async {
      final head = (await access.head())!;
      final sha = (await access.fileSha(
        head,
        '${SyncFormat.directory}/recovery.bin',
      ))!;
      return access.blob(sha, maximum: 188);
    });
    final receiverVault = Directory('${scratch.path}/receiver');
    WindowsDataProtection().preparePrivateDirectory(receiverVault.path);
    final receiver = VaultCredentials(
      VaultBootstrapStore(
        File('${receiverVault.path}/vault.bootstrap'),
        commitReplacement: WindowsDataProtection().replacePrivateFile,
      ),
    );
    final recoveredSession = await receiver.restoreFromRepository(
      recovery: recoveryBytes,
      password: password,
      expectedVaultId: session.vaultId,
    );
    final receiverCatalog = LibraryCatalog.create(
      File('${receiverVault.path}/catalog.db'),
      recoveredSession,
    );
    final received = <int>[];
    try {
      await connection.withRepository((a) async {
        final reader = GitHubSyncRepository(
          access: a,
          catalog: () => receiverCatalog,
          session: recoveredSession,
          objects: SyncObjectStore(receiverVault, () {}),
          crypto: crypto,
        );
        final snapshot = await reader.snapshot();
        await reader.refreshMediaCatalog(snapshot!);
        expect(receiverCatalog.mediaCount, 1);
        expect(receiverCatalog.media().single['local'], false);
        expect(receiverCatalog.media().single['path'], isNull);
        await reader.recoverMedia(ref, (_, bytes) async {
          received.addAll(bytes);
        });
        expect(received, png);
        // Actual ciphertext modification must fail before releasing this block.
        final block = catalog.record(
          'jobs',
          SyncResourcePreparer.chunkKey(task, 0),
        )!;
        wire.blobs[block['sha']]![40] ^= 1;
        var consumed = false;
        await expectLater(
          reader.recoverMedia(ref, (_, bytes) async {
            consumed = true;
          }),
          throwsA(anything),
        );
        expect(consumed, false);
      });
    } finally {
      receiverCatalog.close();
      receiver.revoke();
    }
    // Exercise the production installer, fresh DPAPI/PIN and real controller.
    // The previous source was deleted; only remote manifests supply this index.
    final installed = Directory('${scratch.path}/installed');
    await connection.withRepository((access) async {
      final preview = await RepositoryVaultRecovery.inspect(access);
      await expectLater(
        RepositoryVaultRecovery.install(
          access: access,
          expected: preview,
          destination: installed,
          password: 'wrong password 1234',
          pin: '6789',
          check: () {},
        ),
        throwsA(isA<SecurityFailure>()),
      );
      expect(await installed.exists(), false);
      await RepositoryVaultRecovery.install(
        access: access,
        expected: preview,
        destination: installed,
        password: password,
        pin: '6789',
        check: () {},
      );
    });
    final controller = VaultController(installed, automaticCheck: false);
    try {
      await controller.start();
      expect(controller.screen, VaultScreen.pin, reason: controller.message);
      await controller.unlock('6789');
      expect(
        controller.screen,
        VaultScreen.library,
        reason: controller.message,
      );
      expect(controller.mediaCount, 1);
      expect(
        controller.github!.user,
        isNull,
        reason: 'Sender platform credential is not copied',
      );
      expect(controller.catalog.media().single['local'], false);
    } finally {
      await controller.close();
    }
    for (final bytes in wire.blobs.values) {
      expect(latin1.decode(bytes), isNot(contains('PRIVATE_FILENAME')));
      expect(latin1.decode(bytes), isNot(contains(password)));
    }
    expect(
      wire.writes
          .where((w) => w.path.contains('/git/refs/'))
          .every((w) => w.body['force'] == false),
      true,
    );
    catalog.verifyIntegrity();
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('password wrapping publication survives a lost reply; old device must authenticate remote password', () async {
    final initial = await connection.withRepository(
      (a) => repo(a).initialize(),
    );
    final oldRecovery = await connection.withRepository(
      (a) async => a.blob(
        (await a.fileSha(
          (await a.head())!,
          '${SyncFormat.directory}/recovery.bin',
        ))!,
        maximum: 188,
      ),
    );
    final receiverVault = Directory('${scratch.path}/password-receiver');
    WindowsDataProtection().preparePrivateDirectory(receiverVault.path);
    final receiver = VaultCredentials(
      VaultBootstrapStore(
        File('${receiverVault.path}/vault.bootstrap'),
        commitReplacement: WindowsDataProtection().replacePrivateFile,
      ),
    );
    var receiverSession = await receiver.restoreFromRepository(
      recovery: oldRecovery,
      password: password,
      expectedVaultId: session.vaultId,
    );
    var receiverCatalog = LibraryCatalog.create(
      File('${receiverVault.path}/catalog.db'),
      receiverSession,
    );
    addTearDown(() {
      receiverCatalog.close();
      receiver.revoke();
    });
    receiverCatalog.putRecord('preferences', 'kept', {
      'value': 'encrypted local record',
    });
    GitHubSyncRepository other(GitHubGitAccess a) => GitHubSyncRepository(
      access: a,
      catalog: () => receiverCatalog,
      session: receiverSession,
      objects: SyncObjectStore(receiverVault, () {}),
      crypto: crypto,
    );
    await connection.withRepository((a) => other(a).snapshot());
    final key =
        'sync:github:${connection.selected!.id}:${SyncFormat.hex(session.vaultId)}';
    catalog.putRecord('preferences', key, {
      ...catalog.record('preferences', key)!,
      'pendingPassword': {
        'baselineDigest': initial.recoveryDigest,
        'oldGeneration': session.generation,
        'taskId': SyncFormat.newId(crypto),
      },
    });
    final vaultId = session.vaultId;
    const newPassword = 'changed isolated GitHub password';
    session = await credentials.changePassword(
      oldPassword: password,
      newPassword: newPassword,
      confirmation: newPassword,
      expectedVaultId: vaultId,
    );
    catalog = LibraryCatalog.open(File('${vault.path}/catalog.db'), session);
    wire.loseNextPublishReply = true;
    await expectLater(
      connection.withRepository((a) => repo(a).publishPasswordChange()),
      throwsA(isA<RepositoryFailure>()),
    );
    final commits = wire.commits.length;
    await connection.withRepository((a) => repo(a).publishPasswordChange());
    expect(wire.commits.length, commits);
    expect(catalog.record('preferences', key)!['pendingPassword'], isNull);
    await expectLater(
      connection.withRepository((a) => other(a).snapshot()),
      throwsA(
        isA<SyncFailure>().having(
          (e) => e.code,
          'code',
          SyncFailureCode.repositoryPasswordRequired,
        ),
      ),
    );
    final freshRecovery = await connection.withRepository(
      (a) async => a.blob(
        (await a.fileSha(
          (await a.head())!,
          '${SyncFormat.directory}/recovery.bin',
        ))!,
        maximum: 188,
      ),
    );
    final priorBytes = await File('${receiverVault.path}/vault.bootstrap')
        .readAsBytes();
    await expectLater(
      receiver.adoptRepositoryPassword(
        recovery: freshRecovery,
        password: password,
        expectedVaultId: vaultId,
      ),
      throwsA(isA<SecurityFailure>()),
    );
    expect(
      await File('${receiverVault.path}/vault.bootstrap').readAsBytes(),
      priorBytes,
    );
    receiverSession = await receiver.adoptRepositoryPassword(
      recovery: freshRecovery,
      password: newPassword,
      expectedVaultId: vaultId,
    );
    receiverCatalog = LibraryCatalog.open(
      File('${receiverVault.path}/catalog.db'),
      receiverSession,
    );
    try {
      expect(
        receiverCatalog.record('preferences', 'kept')!['value'],
        'encrypted local record',
      );
      receiverCatalog.putRecord('preferences', key, {
        ...receiverCatalog.record('preferences', key)!,
        'acceptedRecoveryDigest': await SyncFormat.digest(
          crypto,
          freshRecovery,
        ),
        'localGeneration': receiverSession.generation,
      });
      await connection.withRepository((a) => other(a).snapshot());
    } finally {
      receiverCatalog.close();
      receiver.revoke();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('real encrypted queue survives restart and manual pause; explicit and automatic requests share one publication', () async {
    await File('${photos.path}/queued.png').writeAsBytes(png);
    await imports.addFolder(photos.path);
    await until(() => catalog.mediaCount == 1);
    await connection.withRepository((a) => repo(a).initialize());
    WindowsSyncService make() => WindowsSyncService(
      catalog: () => catalog,
      session: () => session,
      connection: connection,
      imports: imports,
      directory: vault,
    );
    var sync = make();
    sync.pause();
    final media = catalog.media().single;
    await sync.requestUpload([media['id'] as String]);
    await sync.requestUpload([media['id'] as String]);
    expect(sync.jobs.length, 1);
    final writes = wire.writes.length;
    await sync.settled;
    expect(wire.writes.length, writes);
    sync.dispose();
    catalog.close();
    catalog = LibraryCatalog.open(File('${vault.path}/catalog.db'), session);
    sync = make();
    expect(sync.paused, true);
    expect(sync.jobs.length, 1);
    sync.resume();
    await sync.settled;
    expect(sync.verified(media), true, reason: sync.issue);
    final commits = wire.commits.length;
    await sync.requestUpload([media['id'] as String]);
    await sync.settled;
    expect(wire.commits.length, commits);
    expect(sync.jobs.single['phase'], 'complete');
    sync.dispose();
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('lock revokes a late network reply without publishing success and keeps durable encrypted preparation', () async {
    await File('${photos.path}/cancelled.png').writeAsBytes(png);
    await imports.addFolder(photos.path);
    await until(() => catalog.mediaCount == 1);
    await connection.withRepository((a) => repo(a).initialize());
    final before = wire.refs['epa-data-v1'];
    final reached = Completer<void>(), release = Completer<void>();
    wire.beforeRequest = (uri, method) async {
      if (method == 'POST' &&
          uri.path.endsWith('/git/blobs') &&
          !reached.isCompleted) {
        reached.complete();
        await release.future;
      }
    };
    final sync = WindowsSyncService(
      catalog: () => catalog,
      session: () => session,
      connection: connection,
      imports: imports,
      directory: vault,
    );
    final media = catalog.media().single;
    try {
      await sync.requestUpload([media['id'] as String]);
      await reached.future.timeout(const Duration(seconds: 30));
      sync.dispose();
      release.complete();
      await sync.settled;
      expect(wire.refs['epa-data-v1'], before);
      final target =
          'github:${connection.selected!.id}:${SyncFormat.hex(session.vaultId)}';
      expect(
        catalog.record('replicas', 'receipt:$target:${media['id']}'),
        isNull,
      );
      final jobs = catalog.recordPage('jobs', 'upload:$target:');
      expect(jobs.length, 1);
      final job = SyncFormat.map(jobs.single['body']);
      expect(job['phase'], isNot('complete'));
      expect(catalog.record('jobs', 'resource:${job['taskId']}'), isNotNull);
    } finally {
      if (!release.isCompleted) release.complete();
      sync.dispose();
      await sync.settled;
      wire.beforeRequest = null;
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('ciphertext demand cache evicts least recently used, rejects tampering and preserves bound across reopen', () async {
    final cache = SyncCipherCache(
      vault,
      () => catalog,
      crypto,
      () {},
      budget: 512,
    );
    final records = <Map<String, Object?>>[];
    final blocks = <Uint8List>[];
    for (var i = 0; i < 4; i++) {
      final id = SyncFormat.newId(crypto);
      final bytes = SyncFormat.encryptMetadata(session, 'media', id, {
        'format': '1',
        'privateName': 'PRIVATE_CACHE_FILENAME_$i',
        'padding': 'x' * 80,
      });
      final ref = {
        'objectId': id,
        'digest': await SyncFormat.digest(crypto, bytes),
        'length': '${bytes.length}',
      };
      records.add(ref);
      blocks.add(bytes);
      await cache.write(ref, bytes);
      expect(catalog.cipherCacheBytes, lessThanOrEqualTo(512));
    }
    expect(await cache.read(records.first), isNull);
    expect(await cache.read(records.last), blocks.last);
    for (final file in cache.directory.listSync().whereType<File>()) {
      expect(
        latin1.decode(await file.readAsBytes()),
        isNot(contains('PRIVATE_CACHE_FILENAME')),
      );
    }
    final tampered = File(
      '${cache.directory.path}/${records.last['digest']}.bin',
    );
    final bad = await tampered.readAsBytes();
    bad[36] ^= 1;
    await tampered.writeAsBytes(bad);
    expect(await cache.read(records.last), isNull);
    expect(await tampered.exists(), false);
    final reopened = SyncCipherCache(
      vault,
      () => catalog,
      crypto,
      () {},
      budget: 512,
    );
    await reopened.write(records.last, blocks.last);
    expect(await reopened.read(records.last), blocks.last);
    expect(catalog.cipherCacheBytes, lessThanOrEqualTo(512));
  });

  test('library filters require exact repository and source version receipts', () async {
    await File('${photos.path}/filtered.png').writeAsBytes(png);
    await imports.addFolder(photos.path);
    await until(() => catalog.mediaCount == 1);
    final media = catalog.media().single;
    final key =
        'receipt:github:${connection.selected!.id}:${SyncFormat.hex(session.vaultId)}:${media['id']}';
    expect(
      catalog.queryCount(const LibraryQuery(filter: LibraryFilter.synced)),
      0,
    );
    catalog.putRecord('replicas', key, {
      'status': 'verified',
      'sourceVersion': 'old',
    });
    expect(
      catalog.queryCount(const LibraryQuery(filter: LibraryFilter.synced)),
      0,
    );
    catalog.putRecord('replicas', key, {
      'status': 'verified',
      'sourceVersion': media['version'],
    });
    expect(
      catalog.queryCount(const LibraryQuery(filter: LibraryFilter.synced)),
      1,
    );
    expect(
      catalog.queryCount(const LibraryQuery(filter: LibraryFilter.pending)),
      0,
    );
    expect(
      catalog.queryCount(const LibraryQuery(filter: LibraryFilter.localOnly)),
      0,
    );
    catalog.putMedia({...media, 'local': false});
    expect(
      catalog.queryCount(const LibraryQuery(filter: LibraryFilter.remoteOnly)),
      1,
    );
    final connectionRecord = catalog.record(
      'preferences',
      'github-connection',
    )!;
    final repository = SyncFormat.map(connectionRecord['repository']);
    catalog.putRecord('preferences', 'github-connection', {
      ...connectionRecord,
      'repository': {...repository, 'id': (repository['id'] as int) + 1},
    });
    expect(
      catalog.queryCount(const LibraryQuery(filter: LibraryFilter.synced)),
      0,
    );
    expect(
      catalog.queryCount(const LibraryQuery(filter: LibraryFilter.remoteOnly)),
      0,
    );
  });

  test('capability revoked at callback exit and public target refused before writes', () async {
    GitHubGitAccess? saved;
    await connection.withRepository((a) async {
      saved = a;
      await a.verifyTarget();
    });
    await expectLater(saved!.head(), throwsA(isA<RepositoryFailure>()));
    wire.private = false;
    await expectLater(
      connection.withRepository((a) => repo(a).initialize()),
      throwsA(isA<RepositoryFailure>()),
    );
    expect(wire.writes, isEmpty);
  });
}
