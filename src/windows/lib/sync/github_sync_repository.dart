import 'dart:convert';
import 'dart:typed_data';

import 'package:encrypted_photo_app/repositories/github_api.dart';
import 'package:encrypted_photo_app/repositories/github_connection.dart';
import 'package:encrypted_photo_shared/security/vault_credentials.dart';
import 'package:encrypted_photo_shared/security/vault_crypto.dart';
import 'package:encrypted_photo_shared/security/vault_recovery_record.dart';
import 'package:encrypted_photo_app/storage/library_catalog.dart';
import 'package:encrypted_photo_shared/sync/sync_format.dart';
import 'package:encrypted_photo_app/sync/sync_object_store.dart';
import 'package:encrypted_photo_app/sync/sync_resource_preparer.dart';
import 'package:encrypted_photo_app/sync/sync_cipher_cache.dart';

final class SyncSnapshot {
  const SyncSnapshot(
    this.commit,
    this.rootDigest,
    this.recoveryDigest,
    this.root,
    this.indexPrefix,
  );
  final String commit, rootDigest, recoveryDigest, indexPrefix;
  final Map<String, Object?> root;
}

/// Authenticated immutable descriptor. Only page references (never plaintext
/// blocks or keys) are retained between requests, with a bounded seek index.
final class RemoteMediaResource {
  RemoteMediaResource(this.descriptor) {
    cursors[0] = SyncFormat.map(descriptor['blocks']);
  }
  final Map<String, Object?> descriptor;
  final Map<int, Map<String, Object?>> cursors = {};
  int get length => SyncFormat.count(descriptor['length'], minimum: 1);
}

/// Real GitHub publication and verification. Call through the unlocked
/// connection capability; no transport fixture or original-file fallback.
final class GitHubSyncRepository {
  GitHubSyncRepository({
    required this.access,
    required this.catalog,
    required this.session,
    required this.objects,
    required this.crypto,
    this.onProgress,
    this.onRepositoryPasswordChanged,
    this.checkAccess,
    this.cache,
  });
  final GitHubGitAccess access;
  final LibraryCatalog Function() catalog;
  final VaultCredentialSession session;
  final SyncObjectStore objects;
  final VaultCrypto crypto;
  final void Function(String phase, int done, int total)? onProgress;
  final Future<void> Function(String target, Uint8List recovery, String digest)?
  onRepositoryPasswordChanged;
  final void Function()? checkAccess;
  final SyncCipherCache? cache;
  String get targetKey =>
      'github:${access.target.id}:${SyncFormat.hex(session.vaultId)}';
  String get stateKey => 'sync:$targetKey';
  void check() {
    checkAccess?.call();
    access.operation.check();
    catalog();
    if (session.isClosed) throw const SyncFailure(SyncFailureCode.cancelled);
  }

  Map<String, Object?> get state =>
      catalog().record('preferences', stateKey) ?? {};
  void saveState(Map<String, Object?> value) {
    check();
    catalog().putRecord('preferences', stateKey, {...state, ...value});
  }

  Future<T> _write<T>(Future<T> Function() action) async {
    check();
    final now = DateTime.now().millisecondsSinceEpoch;
    // Shared by target sessions and persisted before every actual write. A
    // failed/unknown request still spends this budget; no hidden rapid retry.
    final budgetKey = 'github-write-budget';
    var budget =
        catalog().record('preferences', budgetKey) ?? <String, Object?>{};
    var start = budget['start'] as int? ?? now;
    var count = budget['count'] as int? ?? 0;
    if (now - start >= 3600000) {
      start = now;
      count = 0;
    }
    if (now < start || count >= 400) {
      throw RepositoryFailure(
        RepositoryFailureCode.rateLimited,
        retryAt: DateTime.fromMillisecondsSinceEpoch(start + 3600000),
      );
    }
    final next = budget['next'] as int? ?? 0;
    if (next > now)
      await access.operation.wait(Duration(milliseconds: next - now));
    check();
    catalog().putRecord('preferences', budgetKey, {
      'start': start,
      'count': count + 1,
      'next': DateTime.now().millisecondsSinceEpoch + 1000,
    });
    final result = await action();
    check();
    return result;
  }

  static void validateReference(Map<String, Object?> ref) {
    SyncFormat.id(ref['objectId'] as String);
    GitHubGitAccess.sha(ref['sha']);
    SyncFormat.count(
      ref['length'],
      minimum: 48,
      maximum: SyncFormat.chunkBytes + 48,
    );
    if (ref['digest'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(ref['digest'] as String))
      SyncFormat.invalid();
  }

  Future<Uint8List> readObject(
    Map<String, Object?> ref, {
    bool allowCache = false,
  }) async {
    check();
    validateReference(ref);
    final expected = SyncFormat.count(ref['length']);
    if (allowCache && cache != null) {
      final cached = await cache!.read(ref);
      check();
      if (cached != null) return cached;
    }
    final bytes = await access.blob(ref['sha'] as String, maximum: expected);
    check();
    if (bytes.length != expected ||
        await SyncFormat.digest(crypto, bytes) != ref['digest']) {
      throw const SyncFailure(SyncFailureCode.integrity);
    }
    check();
    if (allowCache) await cache?.write(ref, bytes);
    return bytes;
  }

  Future<Map<String, Object?>> readMetadata(
    String kind,
    Map<String, Object?> ref, {
    bool allowCache = false,
  }) async {
    final bytes = await readObject(ref, allowCache: allowCache);
    final value = SyncFormat.decryptMetadata(
      session,
      kind,
      ref['objectId'] as String,
      bytes,
    );
    if (value['format'] != '1') SyncFormat.invalid();
    final fields = switch (kind) {
      'index' || 'page' => {'format', 'entries', 'next'},
      'resource' => {
        'format',
        'mediaId',
        'revisionId',
        'resourceId',
        'role',
        'length',
        'digest',
        'blockCount',
        'keyNonce',
        'keyCipher',
        'pages',
        'blocks',
      },
      'media' => {
        'format',
        'mediaId',
        'revisionId',
        'parentRevision',
        'sourceVersion',
        'kind',
        'fileName',
        'length',
        'takenAt',
        'duration',
        'resources',
        'pairing',
      },
      _ => <String>{},
    };
    SyncFormat.fields(value, fields);
    return value;
  }

  Future<void> requireActiveMedia(
    String id,
    Map<String, Object?> expected,
  ) async {
    final latest = await snapshot();
    if (latest == null) throw const SyncFailure(SyncFailureCode.notInitialized);
    final entry = catalog().record('replicas', '${latest.indexPrefix}$id');
    final versions = entry?['versions'];
    if (versions is! List ||
        versions.length != 1 ||
        SyncFormat.map(versions.single)['sha'] != expected['sha']) {
      throw const SyncFailure(SyncFailureCode.conflict);
    }
  }

  Future<SyncSnapshot?> snapshot() async {
    check();
    await access.verifyTarget();
    final head = await access.head();
    if (head == null) return null;
    final cached = state;
    if (cached['commit'] == head &&
        cached['root'] is Map &&
        cached['indexPrefix'] is String) {
      return SyncSnapshot(
        head,
        cached['rootDigest'] as String,
        cached['recoveryDigest'] as String,
        SyncFormat.map(cached['root']),
        cached['indexPrefix'] as String,
      );
    }
    await access.validateNamespace(head);
    final headSha = await access.fileSha(
      head,
      '${SyncFormat.directory}/head.bin',
    );
    final recoverySha = await access.fileSha(
      head,
      '${SyncFormat.directory}/recovery.bin',
    );
    if (headSha == null || recoverySha == null) {
      if (await access.hasDataDirectory(head))
        throw const SyncFailure(SyncFailureCode.format);
      return null;
    }
    final recovery = await access.blob(
      recoverySha,
      maximum: VaultRecoveryRecord.byteLength,
    );
    final projected = VaultRecoveryRecord.parse(recovery);
    if (!crypto.sameBytes(projected.vaultId, session.vaultId))
      throw const SyncFailure(SyncFailureCode.wrongVault);
    final recoveryDigest = await SyncFormat.digest(crypto, recovery);
    final rootBytes = await access.blob(
      headSha,
      maximum: SyncFormat.metadataBytes + 48,
    );
    final root = SyncFormat.decryptMetadata(
      session,
      'root',
      SyncFormat.zeroId,
      rootBytes,
    );
    SyncFormat.fields(root, {
      'format',
      'vaultId',
      'sequence',
      'previous',
      'recoveryDigest',
      'mediaCount',
      'pageCount',
      'index',
    });
    if (root['format'] != '1' ||
        root['vaultId'] != SyncFormat.hex(session.vaultId) ||
        root['recoveryDigest'] != recoveryDigest)
      SyncFormat.invalid();
    SyncFormat.count(root['sequence'], minimum: 1);
    final trusted = state;
    final known = trusted['commit'] as String?;
    if (known != null && !await access.containsCommit(known, head))
      throw const SyncFailure(SyncFailureCode.conflict);
    if (trusted['recoveryDigest'] != null &&
        trusted['recoveryDigest'] != recoveryDigest) {
      final pending = trusted['pendingPassword'];
      final ownPublished =
          pending is Map && pending['newDigest'] == recoveryDigest;
      final authenticated = trusted['acceptedRecoveryDigest'] == recoveryDigest;
      if (!ownPublished && !authenticated) {
        // Persist the new authenticated recovery projection and revoke the App
        // session. A PIN or an old local photo password cannot acknowledge it.
        await onRepositoryPasswordChanged?.call(
          targetKey,
          recovery,
          recoveryDigest,
        );
        throw const SyncFailure(SyncFailureCode.repositoryPasswordRequired);
      }
    }
    final sequence = SyncFormat.count(root['sequence'], minimum: 1);
    final priorSequence = trusted['sequence'] as int?;
    if (known != null &&
        priorSequence != null &&
        (sequence < priorSequence ||
            (head != known && sequence <= priorSequence))) {
      throw const SyncFailure(SyncFailureCode.conflict);
    }
    if (known != null && head != known && priorSequence != null) {
      var cursor = head, childRoot = root;
      while (cursor != known) {
        check();
        final childSequence = SyncFormat.count(
          childRoot['sequence'],
          minimum: 1,
        );
        if (childSequence <= priorSequence)
          throw const SyncFailure(SyncFailureCode.conflict);
        final parents = (await access.commit(cursor))['parents'];
        if (parents is! List || parents.length != 1) SyncFormat.invalid();
        final parent = GitHubGitAccess.sha(
          SyncFormat.map(parents.single)['sha'],
        );
        final parentSha = await access.fileSha(
          parent,
          '${SyncFormat.directory}/head.bin',
        );
        if (parentSha == null)
          throw const SyncFailure(SyncFailureCode.conflict);
        final parentBytes = await access.blob(
          parentSha,
          maximum: SyncFormat.metadataBytes + 48,
        );
        final parentDigest = await SyncFormat.digest(crypto, parentBytes);
        if (childRoot['previous'] != parentDigest ||
            (parent == known && parentDigest != trusted['rootDigest'])) {
          throw const SyncFailure(SyncFailureCode.conflict);
        }
        final parentRoot = SyncFormat.decryptMetadata(
          session,
          'root',
          SyncFormat.zeroId,
          parentBytes,
        );
        if (parentRoot['format'] != '1' ||
            parentRoot['vaultId'] != root['vaultId'] ||
            SyncFormat.count(parentRoot['sequence'], minimum: 1) !=
                childSequence - 1) {
          throw const SyncFailure(SyncFailureCode.conflict);
        }
        cursor = parent;
        childRoot = parentRoot;
      }
    }
    if (known == head &&
        trusted['root'] is Map &&
        trusted['indexPrefix'] is String) {
      return SyncSnapshot(
        head,
        trusted['rootDigest'] as String,
        recoveryDigest,
        root,
        trusted['indexPrefix'] as String,
      );
    }
    final prefix = 'index:$targetKey:${SyncFormat.newId(crypto)}:';
    final pages = SyncFormat.count(root['pageCount']);
    final expectedCount = SyncFormat.count(root['mediaCount']);
    var next = root['index'];
    var seenPages = 0, seenMedia = 0;
    String previousId = '';
    // The SQLCipher visited markers avoid retaining an unbounded set in RAM.
    catalog().deleteRecordPrefix('replicas', 'visit:$targetKey:$head:');
    while (next != null) {
      check();
      if (++seenPages > pages) SyncFormat.invalid();
      final ref = SyncFormat.map(next);
      validateReference(ref);
      final visit = 'visit:$targetKey:$head:${ref['objectId']}';
      if (catalog().record('replicas', visit) != null) SyncFormat.invalid();
      catalog().putRecord('replicas', visit, {'seen': true});
      final page = await readMetadata('index', ref);
      final entries = page['entries'];
      if (entries is! List || entries.isEmpty || entries.length > 256)
        SyncFormat.invalid();
      catalog().transaction(() {
        for (final value in entries) {
          final entry = SyncFormat.map(value);
          final id = entry['mediaId'] as String;
          SyncFormat.id(id);
          if (id.compareTo(previousId) <= 0) SyncFormat.invalid();
          previousId = id;
          final versions = entry['versions'];
          if (versions is! List || versions.length > 256) SyncFormat.invalid();
          if (versions.isEmpty) {
            final deletion = SyncFormat.map(entry['deletion']);
            SyncFormat.id(deletion['operationId'] as String);
            if (!{'repository', 'all'}.contains(deletion['scope']) ||
                deletion['sourceVersion'] is! String ||
                deletion['revisionId'] is! String)
              SyncFormat.invalid();
          } else if (entry['deletion'] != null)
            SyncFormat.invalid();
          for (final version in versions) {
            validateReference(SyncFormat.map(version));
          }
          catalog().putRecord('replicas', '$prefix$id', entry);
          if (++seenMedia > expectedCount) SyncFormat.invalid();
        }
      });
      next = page['next'];
    }
    if (seenPages != pages || seenMedia != expectedCount) SyncFormat.invalid();
    final digest = await SyncFormat.digest(crypto, rootBytes);
    check();
    saveState({
      'commit': head,
      'rootDigest': digest,
      'recoveryDigest': recoveryDigest,
      'localGeneration': trusted['localGeneration'] ?? session.generation,
      'indexPrefix': prefix,
      'sequence': sequence,
      'root': root,
    });
    // Only retire the previously committed index after the new full chain has
    // passed authentication and count checks. Failed scans never destroy it.
    catalog().pruneRecordPrefix('replicas', 'index:$targetKey:', prefix);
    catalog().deleteRecordPrefix('replicas', 'visit:$targetKey:$head:');
    return SyncSnapshot(head, digest, recoveryDigest, root, prefix);
  }

  /// Resumes a local password change without retaining the password. The
  /// encrypted intention was committed before replacing the local bootstrap.
  Future<void> publishPasswordChange() async {
    check();
    final pendingValue = state['pendingPassword'];
    if (pendingValue == null) return;
    final pending = SyncFormat.map(pendingValue);
    if (pending['oldGeneration'] == session.generation) {
      saveState({
        'pendingPassword': null,
      }); // Local replacement never committed.
      return;
    }
    final recovery = session.recoveryMaterial();
    final digest = await SyncFormat.digest(crypto, recovery);
    check();
    saveState({
      'pendingPassword': {...pending, 'newDigest': digest},
    });
    final before = await snapshot();
    if (before == null) throw const SyncFailure(SyncFailureCode.notInitialized);
    if (before.recoveryDigest == digest) {
      saveState({
        'pendingPassword': null,
        'localGeneration': session.generation,
      });
      return; // A previous publish completed but its reply was lost.
    }
    if (before.recoveryDigest != pending['baselineDigest']) {
      throw const SyncFailure(SyncFailureCode.conflict);
    }
    final taskId = pending['taskId'] as String;
    final recoveryRef = await _uploadBytes(
      taskId,
      SyncFormat.newId(crypto),
      recovery,
    );
    final root = {
      ...before.root,
      'sequence': '${SyncFormat.count(before.root['sequence']) + 1}',
      'previous': before.rootDigest,
      'recoveryDigest': digest,
    };
    final rootRef = await _uploadBytes(
      taskId,
      SyncFormat.newId(crypto),
      SyncFormat.encryptMetadata(session, 'root', SyncFormat.zeroId, root),
    );
    await _publish(taskId, before.commit, {
      '${SyncFormat.directory}/recovery.bin': recoveryRef['sha'] as String,
      '${SyncFormat.directory}/head.bin': rootRef['sha'] as String,
    });
    final after = await snapshot();
    if (after?.recoveryDigest != digest) {
      throw const SyncFailure(SyncFailureCode.conflict);
    }
    saveState({'pendingPassword': null, 'localGeneration': session.generation});
  }

  /// Import authenticated manifests only. Resource bytes remain demand-loaded;
  /// a listed remote version is not represented as a locally verified backup.
  Future<void> refreshMediaCatalog(SyncSnapshot snapshot) async {
    if (state['catalogCommit'] == snapshot.commit) return;
    var after = '';
    while (true) {
      check();
      final page = catalog().recordPage(
        'replicas',
        snapshot.indexPrefix,
        after: after,
      );
      if (page.isEmpty) break;
      after = page.last['recordId'] as String;
      for (final row in page) {
        final entry = SyncFormat.map(row['body']);
        final versions = entry['versions'] as List;
        if (versions.isEmpty) {
          final id = entry['mediaId'] as String;
          final deletion = SyncFormat.map(entry['deletion']);
          catalog().transaction(() {
            catalog().deleteRecordPrefix('replicas', 'receipt:$targetKey:$id');
            catalog().putRecord('replicas', 'deleted:$targetKey:$id', deletion);
            if (deletion['scope'] == 'all' && deletion['components'] is List) {
              final components = deletion['components'] as List;
              if (components.length != 2) SyncFormat.invalid();
              for (final value in components) {
                final part = SyncFormat.map(value);
                final componentId = part['sourceMediaId'] as String;
                SyncFormat.id(componentId);
                final component = catalog().mediaById(componentId);
                if (component != null &&
                    catalog().record(
                          'jobs',
                          'remote-delete:${deletion['operationId']}:$componentId',
                        )?['phase'] !=
                        'complete')
                  catalog().putMedia({
                    ...component,
                    'autoUploadSuppressed': true,
                    'pendingRemoteDeletion': {
                      'operationId': deletion['operationId'],
                      'scope': 'all',
                      'sourceVersion': part['version'],
                      'revisionId': deletion['revisionId'],
                    },
                  });
              }
            }
            final prior = catalog().mediaById(id);
            if (prior != null) {
              catalog().putMedia({
                ...prior,
                'autoUploadSuppressed': true,
                'deletedFromLibrary': prior['local'] != true,
                if (deletion['scope'] == 'all' &&
                    catalog().record(
                          'jobs',
                          'remote-delete:${deletion['operationId']}:$id',
                        )?['phase'] !=
                        'complete')
                  'pendingRemoteDeletion': deletion,
              });
            }
          });
          continue;
        }
        if (versions.length != 1) {
          catalog().putRecord(
            'replicas',
            'conflict:$targetKey:${entry['mediaId']}',
            entry,
          );
          continue;
        }
        final ref = SyncFormat.map(versions.single);
        final media = await readMetadata('media', ref);
        final id = media['mediaId'] as String;
        if (id != entry['mediaId'] ||
            media['fileName'] is! String ||
            (media['fileName'] as String).length > 32768 ||
            media['sourceVersion'] is! String ||
            !{'photo', 'video', 'livePhoto'}.contains(media['kind']))
          SyncFormat.invalid();
        SyncFormat.id(id);
        SyncFormat.id(media['revisionId'] as String);
        final size = SyncFormat.count(media['length'], minimum: 1);
        check();
        catalog().transaction(() {
          if (media['kind'] == 'livePhoto') {
            final pairing = SyncFormat.map(media['pairing']);
            for (final key in ['imageMediaId', 'videoMediaId']) {
              final componentId = pairing[key] as String;
              SyncFormat.id(componentId);
              if (componentId == id) SyncFormat.invalid();
              catalog().putRecord(
                'tracking',
                'component:$targetKey:$componentId',
                {'parent': id},
              );
              final component = catalog().mediaById(componentId);
              if (component != null)
                catalog().putMedia({
                  ...component,
                  'pairedComponentOf': id,
                  'pendingRemoteDeletion': null,
                });
            }
          }
          var prior = catalog().mediaById(id);
          if (prior == null) {
            catalog().putMedia({
              'id': id,
              'observedAt': DateTime.now().millisecondsSinceEpoch,
              'kind': media['kind'],
              'fileName': media['fileName'],
              'path': null,
              'size': size,
              'version': media['sourceVersion'],
              'format': '仓库原始资源',
              'local': false,
              'remoteOrigin': targetKey,
              'sourceMissing': false,
              if (catalog().record('tracking', 'component:$targetKey:$id')
                  case final component?)
                'pairedComponentOf': component['parent'],
            });
          }
          if (prior != null &&
              prior['local'] != true &&
              prior['remoteOrigin'] == targetKey &&
              prior['version'] != media['sourceVersion']) {
            // A remote-only item must follow the authenticated current revision.
            // Preserve album/favorite identity, but never reuse old-version
            // properties or thumbnails. Local originals are not overwritten.
            prior = {
              ...prior,
              'kind': media['kind'],
              'fileName': media['fileName'],
              'size': size,
              'version': media['sourceVersion'],
              'format': '仓库原始资源',
              'viewMetadata': null,
              'sourceMetadata': null,
            };
            catalog().putMedia(prior);
          }
          if (prior != null &&
              (prior['deletedFromLibrary'] == true ||
                  prior['pendingRemoteDeletion'] != null)) {
            catalog().putMedia({
              ...prior,
              'deletedFromLibrary': false,
              'pendingRemoteDeletion': null,
            });
          }
          catalog().deleteRecordPrefix('replicas', 'deleted:$targetKey:$id');
          final key = 'receipt:$targetKey:$id';
          final receipt = catalog().record('replicas', key);
          if (receipt?['media'] is! Map ||
              SyncFormat.map(receipt!['media'])['sha'] != ref['sha']) {
            catalog().putRecord('replicas', key, {
              'media': ref,
              'commit': snapshot.commit,
              'revisionId': media['revisionId'],
              'sourceVersion': media['sourceVersion'],
              'target': targetKey,
              'status': 'listed',
            });
          }
        });
      }
    }
    saveState({'catalogCommit': snapshot.commit});
  }

  Future<Map<String, Object?>> _uploadBytes(
    String taskId,
    String objectId,
    Uint8List bytes,
  ) async {
    check();
    final digest = await SyncFormat.digest(crypto, bytes);
    final ref = <String, Object?>{
      'objectId': objectId,
      'length': '${bytes.length}',
      'digest': digest,
    };
    final sha = await _write(() => access.createBlob(bytes));
    ref['sha'] = sha;
    final returned = await readObject(ref);
    if (!crypto.sameBytes(returned, bytes))
      throw const SyncFailure(SyncFailureCode.integrity);
    check();
    catalog().putRecord('jobs', 'path:$taskId:$objectId', ref);
    return ref;
  }

  Future<Map<String, Object?>> _uploadMetadata(
    String taskId,
    String kind,
    Map<String, Object?> value,
  ) async {
    final id = SyncFormat.newId(crypto);
    return _uploadBytes(
      taskId,
      id,
      SyncFormat.encryptMetadata(session, kind, id, value),
    );
  }

  Future<String> _treeWithPaths(
    String parentTree,
    String taskId,
    Map<String, String> fixed,
  ) async {
    var tree = parentTree, after = '';
    while (true) {
      final page = catalog().recordPage(
        'jobs',
        'path:$taskId:',
        after: after,
        limit: 256,
      );
      if (page.isEmpty) break;
      after = page.last['recordId'] as String;
      final paths = <String, String>{};
      for (final item in page) {
        final ref = SyncFormat.map(item['body']);
        paths[SyncFormat.objectPath(ref['objectId'] as String)] =
            ref['sha'] as String;
      }
      tree = await _write(() => access.createTree(tree, paths));
    }
    after = '';
    while (true) {
      final page = catalog().recordPage(
        'jobs',
        'remove-path:$taskId:',
        after: after,
        limit: 256,
      );
      if (page.isEmpty) break;
      after = page.last['recordId'] as String;
      final paths = <String, String?>{};
      for (final item in page) {
        final body = SyncFormat.map(item['body']);
        paths[SyncFormat.objectPath(body['objectId'] as String)] = null;
      }
      tree = await _write(() => access.createTree(tree, paths));
    }
    return _write(() => access.createTree(tree, fixed));
  }

  Future<String> _publish(
    String taskId,
    String parent,
    Map<String, String> fixed,
  ) async {
    final parentTree = GitHubGitAccess.sha(
      SyncFormat.map((await access.commit(parent))['tree'])['sha'],
    );
    final tree = await _treeWithPaths(parentTree, taskId, fixed);
    final candidate = await _write(() => access.createCommit(tree, parent));
    check();
    catalog().putRecord('jobs', 'publication:$taskId', {
      'candidate': candidate,
      'tree': tree,
      'parent': parent,
      'fixed': fixed,
    });
    await _write(() => access.publish(candidate));
    final head = await access.head();
    if (head == null || !await access.containsCommit(candidate, head))
      throw const SyncFailure(SyncFailureCode.conflict);
    final actual = await access.commit(candidate);
    if (SyncFormat.map(actual['tree'])['sha'] != tree)
      throw const SyncFailure(SyncFailureCode.integrity);
    for (final entry in fixed.entries) {
      if (await access.fileSha(candidate, entry.key) != entry.value)
        throw const SyncFailure(SyncFailureCode.integrity);
    }
    return candidate;
  }

  Future<SyncSnapshot> initialize() async {
    final existing = await snapshot();
    if (existing != null) return existing;
    final info = await access.verifyTarget();
    final taskId =
        state['initializationTask'] as String? ?? SyncFormat.newId(crypto);
    saveState({'initializationTask': taskId});
    var dataHead = await access.head();
    if (dataHead == null) {
      final defaultBranch = githubString(
        info['default_branch'],
        maxLength: 255,
      );
      var base = await access.head(defaultBranch);
      base ??= await _write(access.createInitializationMarker);
      await access.validateNamespace(base!);
      if (await access.hasDataDirectory(base))
        throw const SyncFailure(SyncFailureCode.format);
      await _write(() => access.createDataBranch(base!));
      dataHead = await access.head();
    }
    if (dataHead == null || await access.hasDataDirectory(dataHead))
      throw const SyncFailure(SyncFailureCode.conflict);
    final recovery = session.recoveryMaterial();
    final recoveryRef = await _uploadBytes(
      taskId,
      SyncFormat.newId(crypto),
      recovery,
    );
    final root = <String, Object?>{
      'format': '1',
      'vaultId': SyncFormat.hex(session.vaultId),
      'sequence': '1',
      'previous': null,
      'recoveryDigest': recoveryRef['digest'],
      'mediaCount': '0',
      'pageCount': '0',
      'index': null,
    };
    final rootBytes = SyncFormat.encryptMetadata(
      session,
      'root',
      SyncFormat.zeroId,
      root,
    );
    final rootRef = await _uploadBytes(
      taskId,
      SyncFormat.newId(crypto),
      rootBytes,
    );
    await _publish(taskId, dataHead, {
      '${SyncFormat.directory}/recovery.bin': recoveryRef['sha'] as String,
      '${SyncFormat.directory}/head.bin': rootRef['sha'] as String,
    });
    return (await snapshot()) ??
        (throw const SyncFailure(SyncFailureCode.notInitialized));
  }

  Future<Map<String, Object?>> uploadResource(
    String taskId,
    Map<String, Object?> descriptor,
  ) async {
    final total = SyncFormat.count(descriptor['length'], minimum: 1);
    final count = SyncFormat.count(descriptor['blockCount'], minimum: 1);
    if (count != (total + SyncFormat.chunkBytes - 1) ~/ SyncFormat.chunkBytes)
      SyncFormat.invalid();
    final resource = session.openResource(
      SyncFormat.resourceContext(
        descriptor['mediaId'] as String,
        descriptor['revisionId'] as String,
        descriptor['resourceId'] as String,
      ),
      VaultCiphertext(
        nonce: base64Decode(descriptor['keyNonce'] as String),
        ciphertext: base64Decode(descriptor['keyCipher'] as String),
      ),
    );
    final hash = crypto.contentHasher();
    var closedHash = false;
    try {
      for (var i = 0; i < count; i++) {
        check();
        final key = SyncResourcePreparer.chunkKey(taskId, i);
        final record = catalog().record('jobs', key);
        if (record == null) SyncFormat.invalid();
        var ref = record;
        Uint8List verified;
        if (ref['sha'] == null) {
          final ciphertext = await objects.read(
            taskId,
            ref['objectId'] as String,
            SyncFormat.count(ref['length']),
          );
          if (await SyncFormat.digest(crypto, ciphertext) != ref['digest'])
            throw const SyncFailure(SyncFailureCode.integrity);
          final uploaded = await _uploadBytes(
            taskId,
            ref['objectId'] as String,
            ciphertext,
          );
          ref = {...ref, ...uploaded};
          // GET on the real service, then AEAD, not a local cache for verification.
          verified = await readObject(ref);
        } else {
          verified = await readObject(ref);
          catalog().putRecord('jobs', 'path:$taskId:${ref['objectId']}', ref);
        }
        final clear = decryptResourceBlock(
          resource,
          verified,
          index: i,
          totalBytes: total,
        );
        try {
          hash.add(clear);
        } finally {
          clear.fillRange(0, clear.length, 0);
        }
        check();
        catalog().putRecord('jobs', key, {...ref, 'verified': true});
        onProgress?.call(
          'verifying',
          (i + 1) * SyncFormat.chunkBytes > total
              ? total
              : (i + 1) * SyncFormat.chunkBytes,
          total,
        );
      }
      final digest = SyncFormat.hex(await hash.close());
      closedHash = true;
      if (digest != descriptor['digest'])
        throw const SyncFailure(SyncFailureCode.integrity);
      Map<String, Object?>? next;
      var end = count, pages = 0;
      while (end > 0) {
        final start = end > 256 ? end - 256 : 0;
        final entries = <Map<String, Object?>>[];
        for (var i = start; i < end; i++) {
          final row = catalog().record(
            'jobs',
            SyncResourcePreparer.chunkKey(taskId, i),
          );
          if (row == null || row['verified'] != true)
            throw const SyncFailure(SyncFailureCode.integrity);
          entries.add({
            for (final key in [
              'objectId',
              'sha',
              'length',
              'digest',
              'index',
              'clearLength',
            ])
              key: row[key],
          });
        }
        next = await _uploadMetadata(taskId, 'page', {
          'format': '1',
          'entries': entries,
          'next': next,
        });
        pages++;
        end = start;
      }
      return await _uploadMetadata(taskId, 'resource', {
        ...descriptor,
        'pages': '$pages',
        'blocks': next,
      });
    } finally {
      if (!closedHash) await hash.close();
      resource.close();
    }
  }

  Future<Map<String, Object?>> publishMedia(
    String taskId,
    Map<String, Object?> media,
    String revisionId,
    Map<String, Object?> resourceRef, {
    List<Map<String, Object?>> additionalResources = const [],
  }) async {
    final snapshotBefore = await snapshot();
    if (snapshotBefore == null)
      throw const SyncFailure(SyncFailureCode.notInitialized);
    final mediaId = media['id'] as String;
    final oldEntry = catalog().record(
      'replicas',
      '${snapshotBefore.indexPrefix}$mediaId',
    );
    final oldVersions = oldEntry == null
        ? <Object?>[]
        : List<Object?>.from(oldEntry['versions'] as List);
    // Lost reply recovery: find this exact immutable revision before rebuilding.
    for (final version in oldVersions) {
      final ref = SyncFormat.map(version);
      final descriptor = await readMetadata('media', ref);
      if (descriptor['revisionId'] == revisionId) {
        if (descriptor['sourceVersion'] != media['version'])
          throw const SyncFailure(SyncFailureCode.conflict);
        return {
          'commit': snapshotBefore.commit,
          'media': ref,
          'revisionId': revisionId,
          'conflict': oldVersions.length > 1,
        };
      }
    }
    final previous = catalog().record(
      'replicas',
      'receipt:$targetKey:$mediaId',
    );
    final parentRevision = previous?['revisionId'];
    final descriptor = <String, Object?>{
      'format': '1',
      'mediaId': mediaId,
      'revisionId': revisionId,
      'parentRevision': parentRevision,
      'sourceVersion': media['version'],
      'kind': media['kind'],
      'fileName': media['fileName'],
      'length': '${media['size']}',
      'takenAt': null,
      'duration': null,
      'resources': [resourceRef, ...additionalResources],
      'pairing': media['kind'] == 'livePhoto' ? media['pairing'] : null,
    };
    final mediaRef = await _uploadMetadata(taskId, 'media', descriptor);
    final retained = <Map<String, Object?>>[];
    for (final old in oldVersions) {
      final ref = SyncFormat.map(old);
      final oldMedia = await readMetadata('media', ref);
      if (oldMedia['revisionId'] != parentRevision) retained.add(ref);
    }
    retained.add(mediaRef);
    if (retained.length > 256)
      throw const SyncFailure(SyncFailureCode.conflict);
    final entry = {'mediaId': mediaId, 'versions': retained};
    final candidate = await _publishEntry(
      taskId,
      snapshotBefore,
      mediaId,
      entry,
      oldEntry == null,
    );
    final latest = await snapshot();
    if (latest == null) throw const SyncFailure(SyncFailureCode.integrity);
    final finalEntry = catalog().record(
      'replicas',
      '${latest.indexPrefix}$mediaId',
    );
    if (finalEntry == null ||
        !(finalEntry['versions'] as List).any(
          (v) => SyncFormat.map(v)['sha'] == mediaRef['sha'],
        )) {
      throw const SyncFailure(SyncFailureCode.conflict);
    }
    return {
      'commit': candidate,
      'media': mediaRef,
      'revisionId': revisionId,
      'conflict': retained.length > 1,
    };
  }

  Future<String> _publishEntry(
    String taskId,
    SyncSnapshot before,
    String mediaId,
    Map<String, Object?> entry,
    bool isNew,
  ) async {
    // Temporary snapshot is encrypted and keyed by candidate operation. The
    // authenticated remote snapshot remains available on failure.
    final buildPrefix = 'build-index:$taskId:';
    catalog().deleteRecordPrefix('jobs', buildPrefix);
    String after = '';
    var mediaCount = 0;
    while (true) {
      final page = catalog().recordPage(
        'replicas',
        before.indexPrefix,
        after: after,
      );
      if (page.isEmpty) break;
      after = page.last['recordId'] as String;
      catalog().transaction(() {
        for (final item in page) {
          final body = SyncFormat.map(item['body']);
          catalog().putRecord('jobs', '$buildPrefix${body['mediaId']}', body);
          mediaCount++;
        }
      });
    }
    if (isNew) mediaCount++;
    catalog().putRecord('jobs', '$buildPrefix$mediaId', entry);
    after = '';
    Map<String, Object?>? index;
    var pages = 0;
    while (true) {
      final page = catalog().recordPage(
        'jobs',
        buildPrefix,
        after: after,
        limit: 256,
        descending: true,
      );
      if (page.isEmpty) break;
      after = page.last['recordId'] as String;
      index = await _uploadMetadata(taskId, 'index', {
        'format': '1',
        'entries': page.reversed.map((r) => r['body']).toList(),
        'next': index,
      });
      pages++;
    }
    final root = <String, Object?>{
      'format': '1',
      'vaultId': SyncFormat.hex(session.vaultId),
      'sequence':
          '${SyncFormat.count(before.root['sequence'], minimum: 1) + 1}',
      'previous': before.rootDigest,
      'recoveryDigest': before.recoveryDigest,
      'mediaCount': '$mediaCount',
      'pageCount': '$pages',
      'index': index,
    };
    final rootRef = await _uploadBytes(
      taskId,
      SyncFormat.newId(crypto),
      SyncFormat.encryptMetadata(session, 'root', SyncFormat.zeroId, root),
    );
    return _publish(taskId, before.commit, {
      '${SyncFormat.directory}/head.bin': rootRef['sha'] as String,
    });
  }

  Future<RemoteMediaResource> openPlaybackResource(
    Map<String, Object?> mediaRef, {
    required String mediaId,
    required String revision,
    bool stillImage = false,
  }) async {
    final media = await readMetadata('media', mediaRef);
    if (media['mediaId'] != mediaId || media['revisionId'] != revision) {
      SyncFormat.invalid();
    }
    final refs = media['resources'];
    if (refs is! List || refs.isEmpty || refs.length > 16) SyncFormat.invalid();
    final roles = <String>{};
    Map<String, Object?>? selected;
    var length = 0;
    for (final ref in refs) {
      final resource = await readMetadata('resource', SyncFormat.map(ref));
      final role = resource['role'];
      if (resource['mediaId'] != mediaId ||
          resource['revisionId'] != revision ||
          role is! String ||
          !{'image', 'video', 'pairedVideo'}.contains(role) ||
          !roles.add(role))
        SyncFormat.invalid();
      SyncFormat.id(resource['resourceId'] as String);
      final size = SyncFormat.count(resource['length'], minimum: 1);
      final count = SyncFormat.count(resource['blockCount'], minimum: 1);
      if (count !=
              (size + SyncFormat.chunkBytes - 1) ~/ SyncFormat.chunkBytes ||
          SyncFormat.count(resource['pages'], minimum: 1) !=
              (count + 255) ~/ 256) {
        SyncFormat.invalid();
      }
      length += size;
      if (role == 'video' ||
          (role == 'pairedVideo' && !stillImage) ||
          (role == 'image' && stillImage) ||
          (role == 'image' && media['kind'] == 'photo'))
        selected = resource;
    }
    if (length != SyncFormat.count(media['length'], minimum: 1) ||
        selected == null ||
        (media['kind'] == 'video' &&
            (roles.length != 1 || !roles.contains('video'))) ||
        (media['kind'] == 'livePhoto' &&
            (roles.length != 2 ||
                !roles.containsAll({'image', 'pairedVideo'}) ||
                media['pairing'] == null)) ||
        (media['kind'] == 'photo' &&
            (roles.length != 1 || !roles.contains('image'))) ||
        !{'photo', 'video', 'livePhoto'}.contains(media['kind']))
      SyncFormat.invalid();
    if (media['kind'] == 'livePhoto' && !stillImage) {
      await recoverCoverImage(mediaRef, (_, __) async {}, maximum: null);
    }
    return RemoteMediaResource(selected);
  }

  Future<void> recoverCoverImage(
    Map<String, Object?> mediaRef,
    Future<void> Function(Map<String, Object?> resource, Uint8List bytes)
    consume, {
    int? maximum = 32 * 1024 * 1024,
  }) async {
    final media = await readMetadata('media', mediaRef);
    if (!{'photo', 'livePhoto'}.contains(media['kind'])) SyncFormat.invalid();
    final refs = media['resources'];
    if (refs is! List || refs.isEmpty || refs.length > 16) SyncFormat.invalid();
    Map<String, Object?>? image;
    for (final ref in refs) {
      final resource = await readMetadata('resource', SyncFormat.map(ref));
      if (resource['mediaId'] != media['mediaId'] ||
          resource['revisionId'] != media['revisionId'])
        SyncFormat.invalid();
      if (resource['role'] == 'image') {
        if (image != null) SyncFormat.invalid();
        image = resource;
      }
    }
    if (image == null) SyncFormat.invalid();
    final source = RemoteMediaResource(image);
    if (maximum != null && source.length > maximum)
      throw const SyncFailure(SyncFailureCode.space);
    final count = SyncFormat.count(image['blockCount'], minimum: 1);
    if (count !=
        (source.length + SyncFormat.chunkBytes - 1) ~/ SyncFormat.chunkBytes)
      SyncFormat.invalid();
    final hash = crypto.contentHasher();
    var closed = false;
    try {
      for (var i = 0; i < count; i++) {
        final bytes = await readPlaybackBlock(source, i);
        try {
          hash.add(bytes);
          check();
          await consume(image, bytes);
          check();
        } finally {
          bytes.fillRange(0, bytes.length, 0);
        }
      }
      final digest = SyncFormat.hex(await hash.close());
      closed = true;
      if (digest != image['digest'])
        throw const SyncFailure(SyncFailureCode.integrity);
    } finally {
      if (!closed) await hash.close();
    }
  }

  Future<Map<String, Object?>> deleteMedia(
    String taskId,
    String mediaId,
    String sourceVersion,
    String scope,
  ) async {
    if (!{'repository', 'all'}.contains(scope)) SyncFormat.invalid();
    SyncFormat.id(taskId);
    final before = await snapshot();
    if (before == null) throw const SyncFailure(SyncFailureCode.notInitialized);
    final entry = catalog().record('replicas', '${before.indexPrefix}$mediaId');
    if (entry == null) {
      final deletion = <String, Object?>{
        'operationId': taskId,
        'scope': scope,
        'sourceVersion': sourceVersion,
        'revisionId': SyncFormat.zeroId,
      };
      await _publishEntry(taskId, before, mediaId, {
        'mediaId': mediaId,
        'versions': <Object?>[],
        'deletion': deletion,
      }, true);
      final after = await snapshot();
      if (after == null ||
          SyncFormat.map(
                catalog().record(
                  'replicas',
                  '${after.indexPrefix}$mediaId',
                )?['deletion'],
              )['operationId'] !=
              taskId) {
        throw const SyncFailure(SyncFailureCode.conflict);
      }
      await refreshMediaCatalog(after);
      return deletion;
    }
    final versions = entry['versions'] as List;
    if (versions.isEmpty) {
      final deletion = SyncFormat.map(entry['deletion']);
      if (deletion['operationId'] == taskId) return deletion;
      if (deletion['sourceVersion'] != sourceVersion)
        throw const SyncFailure(SyncFailureCode.conflict);
      // The user can request synchronized local deletion after previously
      // removing just the remote copy, or delete a restored same-version file.
      final next = {...deletion, 'operationId': taskId, 'scope': scope};
      await _publishEntry(taskId, before, mediaId, {
        'mediaId': mediaId,
        'versions': <Object?>[],
        'deletion': next,
      }, false);
      final latest = await snapshot();
      if (latest == null ||
          SyncFormat.map(
                catalog().record(
                  'replicas',
                  '${latest.indexPrefix}$mediaId',
                )?['deletion'],
              )['operationId'] !=
              taskId) {
        throw const SyncFailure(SyncFailureCode.conflict);
      }
      await refreshMediaCatalog(latest);
      return next;
    }
    if (versions.length != 1) throw const SyncFailure(SyncFailureCode.conflict);
    final mediaRef = SyncFormat.map(versions.single);
    final media = await readMetadata('media', mediaRef);
    if (media['mediaId'] != mediaId ||
        media['sourceVersion'] != sourceVersion) {
      throw const SyncFailure(SyncFailureCode.conflict);
    }
    final partsKey = 'delete-parts:$taskId';
    if (media['kind'] == 'livePhoto' &&
        catalog().record('jobs', partsKey)?['complete'] != true) {
      var plan = catalog().record('jobs', partsKey);
      if (plan == null) {
        final pairing = SyncFormat.map(media['pairing']);
        final components = <Map<String, Object?>>[];
        for (final resourceRef in media['resources'] as List) {
          final resource = await readMetadata(
            'resource',
            SyncFormat.map(resourceRef),
          );
          final componentId =
              pairing[resource['role'] == 'image'
                      ? 'imageMediaId'
                      : 'videoMediaId']
                  as String;
          SyncFormat.id(componentId);
          if (componentId == mediaId) SyncFormat.invalid();
          final expectedVersion =
              'blake2b-256:${resource['length']}:${resource['digest']}';
          final previous = catalog().record(
            'replicas',
            '${before.indexPrefix}$componentId',
          );
          var removePrevious = false;
          if (previous != null && (previous['versions'] as List).isNotEmpty) {
            final oldVersions = previous['versions'] as List;
            if (oldVersions.length != 1)
              throw const SyncFailure(SyncFailureCode.conflict);
            final original = await readMetadata(
              'media',
              SyncFormat.map(oldVersions.single),
            );
            if (original['kind'] == 'livePhoto' ||
                original['sourceVersion'] != expectedVersion) {
              throw const SyncFailure(SyncFailureCode.conflict);
            }
            removePrevious = true;
          }
          components.add({
            'sourceMediaId': componentId,
            'version': expectedVersion,
            'taskId': SyncFormat.newId(crypto),
            'removePrevious': removePrevious,
          });
        }
        plan = {'complete': false, 'components': components};
        catalog().putRecord('jobs', partsKey, plan);
      }
      for (final value in plan['components'] as List) {
        final component = SyncFormat.map(value);
        if (component['removePrevious'] == true) {
          await deleteMedia(
            component['taskId'] as String,
            component['sourceMediaId'] as String,
            component['version'] as String,
            'repository',
          );
        }
      }
      catalog().putRecord('jobs', partsKey, {...plan, 'complete': true});
      // Child publications changed the repository head; obtain a fresh base.
      return deleteMedia(taskId, mediaId, sourceVersion, scope);
    }
    void remove(Map<String, Object?> ref) {
      validateReference(ref);
      catalog().putRecord(
        'jobs',
        'remove-path:$taskId:${ref['objectId']}',
        ref,
      );
    }

    remove(mediaRef);
    for (final value in media['resources'] as List) {
      final ref = SyncFormat.map(value);
      final resource = await readMetadata('resource', ref);
      if (resource['mediaId'] != mediaId ||
          resource['revisionId'] != media['revisionId'])
        SyncFormat.invalid();
      remove(ref);
      Object? next = resource['blocks'];
      var pages = 0, blocks = 0;
      final count = SyncFormat.count(resource['blockCount'], minimum: 1);
      final expectedPages = SyncFormat.count(resource['pages'], minimum: 1);
      while (next != null) {
        if (++pages > expectedPages) SyncFormat.invalid();
        final pageRef = SyncFormat.map(next);
        final page = await readMetadata('page', pageRef);
        remove(pageRef);
        final entries = page['entries'];
        if (entries is! List || entries.isEmpty || entries.length > 256)
          SyncFormat.invalid();
        for (final value in entries) {
          final block = SyncFormat.map(value);
          if (SyncFormat.count(block['index']) != blocks++)
            SyncFormat.invalid();
          remove(block);
        }
        next = page['next'];
      }
      if (pages != expectedPages || blocks != count) SyncFormat.invalid();
    }
    final deletion = <String, Object?>{
      'operationId': taskId,
      'scope': scope,
      'sourceVersion': sourceVersion,
      'revisionId': media['revisionId'],
      if (media['kind'] == 'livePhoto')
        'components':
            (catalog().record('jobs', partsKey)!['components'] as List).map((
              value,
            ) {
              final part = SyncFormat.map(value);
              return {
                'sourceMediaId': part['sourceMediaId'],
                'version': part['version'],
              };
            }).toList(),
    };
    final candidate = await _publishEntry(taskId, before, mediaId, {
      'mediaId': mediaId,
      'versions': <Object?>[],
      'deletion': deletion,
    }, false);
    final latest = await snapshot();
    final actual = latest == null
        ? null
        : catalog().record('replicas', '${latest.indexPrefix}$mediaId');
    if (actual?['deletion'] is! Map ||
        SyncFormat.map(actual!['deletion'])['operationId'] != taskId ||
        await access.fileSha(
              candidate,
              SyncFormat.objectPath(mediaRef['objectId'] as String),
            ) !=
            null) {
      throw const SyncFailure(SyncFailureCode.conflict);
    }
    await refreshMediaCatalog(latest!);
    return deletion;
  }

  /// Random reads prove the requested block only. No full digest/receipt update.
  Future<Uint8List> readPlaybackBlock(
    RemoteMediaResource source,
    int index,
  ) async {
    check();
    final resource = source.descriptor;
    final count = SyncFormat.count(resource['blockCount'], minimum: 1);
    if (index < 0 || index >= count) SyncFormat.invalid();
    var start = source.cursors.keys
        .where((i) => i <= index)
        .reduce((a, b) => a > b ? a : b);
    var next = source.cursors[start]!;
    while (true) {
      final page = await readMetadata('page', next, allowCache: true);
      final entries = page['entries'];
      if (entries is! List ||
          entries.isEmpty ||
          entries.length > 256 ||
          start + entries.length > count)
        SyncFormat.invalid();
      for (var n = 0; n < entries.length; n++) {
        final block = SyncFormat.map(entries[n]);
        validateReference(block);
        if (SyncFormat.count(block['index']) != start + n) SyncFormat.invalid();
      }
      final end = start + entries.length;
      if ((end == count) != (page['next'] == null)) SyncFormat.invalid();
      if (index < end) {
        final block = SyncFormat.map(entries[index - start]);
        final ciphertext = await readObject(block, allowCache: true);
        check();
        final opened = session.openResource(
          SyncFormat.resourceContext(
            resource['mediaId'] as String,
            resource['revisionId'] as String,
            resource['resourceId'] as String,
          ),
          VaultCiphertext(
            nonce: base64Decode(resource['keyNonce'] as String),
            ciphertext: base64Decode(resource['keyCipher'] as String),
          ),
        );
        try {
          final clear = decryptResourceBlock(
            opened,
            ciphertext,
            index: index,
            totalBytes: source.length,
          );
          try {
            check();
            if (clear.length != SyncFormat.count(block['clearLength']))
              SyncFormat.invalid();
            return clear;
          } catch (_) {
            clear.fillRange(0, clear.length, 0);
            rethrow;
          }
        } finally {
          opened.close();
        }
      }
      start = end;
      next = SyncFormat.map(page['next']);
      if (source.cursors.length >= 64) {
        source.cursors.remove(
          source.cursors.keys.firstWhere((key) => key != 0),
        );
      }
      source.cursors[start] = next;
    }
  }

  /// Download from authenticated remote references only. Every output chunk is
  /// authenticated first; caller reports full success only after this returns.
  Future<void> recoverMedia(
    Map<String, Object?> mediaRef,
    Future<void> Function(
      Map<String, Object?> resource,
      Uint8List authenticatedBytes,
    )
    consume,
  ) async {
    final media = await readMetadata('media', mediaRef);
    final mediaId = media['mediaId'] as String,
        revision = media['revisionId'] as String;
    SyncFormat.id(mediaId);
    SyncFormat.id(revision);
    final refs = media['resources'];
    if (refs is! List || refs.isEmpty || refs.length > 16) SyncFormat.invalid();
    final roles = <String>{};
    var mediaLength = 0;
    for (final value in refs) {
      final resource = await readMetadata('resource', SyncFormat.map(value));
      if (resource['mediaId'] != mediaId || resource['revisionId'] != revision)
        SyncFormat.invalid();
      final role = resource['role'] as String;
      if (!{'image', 'video', 'pairedVideo'}.contains(role) || !roles.add(role))
        SyncFormat.invalid();
      final total = SyncFormat.count(resource['length'], minimum: 1);
      final count = SyncFormat.count(resource['blockCount'], minimum: 1);
      final pages = SyncFormat.count(resource['pages'], minimum: 1);
      if (count !=
              (total + SyncFormat.chunkBytes - 1) ~/ SyncFormat.chunkBytes ||
          pages != (count + 255) ~/ 256)
        SyncFormat.invalid();
      final opened = session.openResource(
        SyncFormat.resourceContext(
          mediaId,
          revision,
          resource['resourceId'] as String,
        ),
        VaultCiphertext(
          nonce: base64Decode(resource['keyNonce'] as String),
          ciphertext: base64Decode(resource['keyCipher'] as String),
        ),
      );
      final hash = crypto.contentHasher();
      var hashClosed = false, index = 0, seenPages = 0, received = 0;
      Object? next = resource['blocks'];
      try {
        while (next != null) {
          check();
          if (++seenPages > pages) SyncFormat.invalid();
          final page = await readMetadata('page', SyncFormat.map(next));
          final entries = page['entries'];
          if (entries is! List || entries.isEmpty || entries.length > 256)
            SyncFormat.invalid();
          for (final item in entries) {
            final block = SyncFormat.map(item);
            if (SyncFormat.count(block['index']) != index) SyncFormat.invalid();
            final bytes = await readObject(block, allowCache: true);
            final clear = decryptResourceBlock(
              opened,
              bytes,
              index: index,
              totalBytes: total,
            );
            try {
              if (clear.length != SyncFormat.count(block['clearLength']))
                SyncFormat.invalid();
              hash.add(clear);
              received += clear.length;
              check();
              final pairing = media['pairing'];
              await consume({
                ...resource,
                'fileName': pairing is Map
                    ? pairing[role == 'image'
                          ? 'imageFileName'
                          : 'videoFileName']
                    : media['fileName'],
              }, clear);
              check();
            } finally {
              clear.fillRange(0, clear.length, 0);
            }
            index++;
          }
          next = page['next'];
        }
        final digest = SyncFormat.hex(await hash.close());
        hashClosed = true;
        if (index != count ||
            seenPages != pages ||
            received != total ||
            digest != resource['digest'])
          throw const SyncFailure(SyncFailureCode.integrity);
        mediaLength += total;
      } finally {
        if (!hashClosed) await hash.close();
        opened.close();
      }
    }
    if (mediaLength != SyncFormat.count(media['length'], minimum: 1) ||
        (media['kind'] == 'photo' &&
            (roles.length != 1 || !roles.contains('image'))) ||
        (media['kind'] == 'video' &&
            (roles.length != 1 || !roles.contains('video'))) ||
        (media['kind'] == 'livePhoto' &&
            (!roles.containsAll({'image', 'pairedVideo'}) ||
                media['pairing'] == null)) ||
        !{'photo', 'video', 'livePhoto'}.contains(media['kind']))
      SyncFormat.invalid();
  }
}
