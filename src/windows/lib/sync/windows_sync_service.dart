import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:encrypted_photo_app/repositories/github_api.dart';
import 'package:encrypted_photo_app/repositories/github_connection.dart';
import 'package:encrypted_photo_shared/security/vault_credentials.dart';
import 'package:encrypted_photo_shared/security/vault_crypto.dart';
import 'package:encrypted_photo_app/services/import/windows_import_service.dart';
import 'package:encrypted_photo_app/services/import/windows_source_reader.dart';
import 'package:encrypted_photo_app/services/playback/loopback_media_source.dart';
import 'package:encrypted_photo_app/storage/library_catalog.dart';
import 'package:encrypted_photo_shared/model/library_query.dart';
import 'package:encrypted_photo_app/sync/github_sync_repository.dart';
import 'package:encrypted_photo_shared/sync/sync_format.dart';
import 'package:encrypted_photo_app/sync/sync_object_store.dart';
import 'package:encrypted_photo_app/sync/sync_resource_preparer.dart';
import 'package:encrypted_photo_app/sync/sync_cipher_cache.dart';

/// One background lifetime. Jobs, receipts, pause and retry reasons are encrypted
/// before acknowledgement; timer ticks trigger work, never synthetic progress.
final class WindowsSyncService extends ChangeNotifier {
  WindowsSyncService({
    required this.catalog,
    required this.session,
    required this.connection,
    required this.imports,
    required this.directory,
    this.onRepositoryPasswordChanged,
    this.acquireView,
  }) {
    _lastTarget = targetKey;
    imports.addListener(_wake);
    connection.addListener(_connectionChanged);
  }
  final LibraryCatalog Function() catalog;
  final VaultCredentialSession Function() session;
  final GitHubConnection connection;
  final WindowsImportService imports;
  final Directory directory;
  final void Function() Function()? acquireView;
  final Future<void> Function(String target, Uint8List recovery, String digest)?
  onRepositoryPasswordChanged;
  Timer? _timer;
  Future<void>? _work;
  bool _closed = false;
  SourceCancellation? _source;
  GitHubGitAccess? _access;
  int _epoch = 0;
  String? _lastTarget;
  String? issue;
  String phase = 'idle';
  int bytesDone = 0, bytesTotal = 0;
  final Set<Uint8List> _photoBuffers = {};
  final Set<Uint8List> _viewPieces = {};
  int _viewEpoch = 0;
  RepositoryOperation? _viewOperation;
  SourceCancellation? _playbackView;
  final Set<SourceCancellation> _thumbnailViews = {};
  bool get busy => _work != null;
  String? get targetKey => connection.selected == null
      ? null
      : 'github:${connection.selected!.id}:${SyncFormat.hex(session().vaultId)}';
  bool get paused =>
      catalog().record('preferences', 'sync-control')?['paused'] == true;
  bool get initialized =>
      targetKey != null &&
      catalog().record('preferences', 'sync:$targetKey')?['commit'] != null;
  String? get selectedName => connection.selected?.fullName;
  void check() {
    if (_closed) throw const SyncFailure(SyncFailureCode.cancelled);
    catalog();
    session();
  }

  void start() {
    _timer ??= Timer.periodic(const Duration(seconds: 10), (_) => _wake());
  }

  void _connectionChanged() {
    if (_closed) return;
    final current = targetKey;
    if (_lastTarget != current) {
      _lastTarget = current;
      _epoch++;
      _source?.cancel();
      _access?.operation.cancel();
      revokeViewing();
    }
    _notify();
    _wake();
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  void _progress(String step, int done, int total) {
    check();
    phase = step;
    bytesDone = done;
    bytesTotal = total;
    _notify();
  }

  List<Map<String, Object?>> get jobs {
    final target = targetKey;
    if (target == null) return const [];
    return catalog()
        .recordPage('jobs', 'upload:$target:', limit: 100)
        .map((r) => SyncFormat.map(r['body']))
        .toList();
  }

  List<Map<String, Object?>> jobPage({String after = '', Set<String>? phases}) {
    final target = targetKey;
    if (target == null) return const [];
    return catalog()
        .recordPage(
          'jobs',
          'upload:$target:',
          after: after,
          limit: 50,
          phases: phases,
        )
        .map(
          (row) => {
            ...SyncFormat.map(row['body']),
            'recordKey': row['recordId'],
          },
        )
        .toList();
  }

  Map<String, int> get jobCounts => targetKey == null
      ? const {}
      : catalog().recordPhaseCounts('jobs', 'upload:$targetKey:');

  void retryUploadJob(String key) {
    acquireView?.call();
    check();
    try {
      final target = targetKey;
      if (target == null || !key.startsWith('upload:$target:'))
        throw const SyncFailure(SyncFailureCode.cancelled);
      final job = catalog().record('jobs', key);
      if (job == null || !{'failed', 'retry'}.contains(job['phase']))
        throw const SyncFailure(SyncFailureCode.conflict);
      final media = catalog().mediaById(job['mediaId'] as String);
      if (media == null ||
          media['local'] != true ||
          media['version'] != job['sourceVersion'] ||
          media['pairedComponentOf'] != null ||
          media['autoUploadSuppressed'] == true) {
        throw const SyncFailure(SyncFailureCode.sourceChanged);
      }
      // Keep the same immutable revision/chunks. Retrying is not republishing
      // a different version, overriding conflicts, or clearing an intentional
      // remote deletion. Preserve an existing server/backoff wait.
      final wait = job['phase'] == 'retry' ? job['retryAt'] : null;
      catalog().putRecord('jobs', key, {
        ...job,
        'phase': wait == null ? 'queued' : 'retry',
        'retryAt': wait,
        'failure': null,
      });
      issue = paused ? '重试请求已保存，恢复同步后继续。' : '重试请求已保存；如有平台限流或退避，将在等待结束后继续。';
      _notify();
      _wake();
    } catch (e) {
      issue = describe(e);
      _notify();
    }
  }

  void synchronizeNow() {
    acquireView?.call();
    check();
    if (paused || busy || connection.busy || !initialized) return;
    final retryKey = 'sync-retry:$targetKey';
    final retry = catalog().record('preferences', retryKey);
    if (retry?['blocked'] != true &&
        ((retry?['retryAt'] as int?) ?? 0) >
            DateTime.now().millisecondsSinceEpoch) {
      issue = '正在等待网络退避或平台限流结束，之后会自动重试。';
      _notify();
      return;
    }
    catalog().putRecord('preferences', retryKey, {});
    issue = null;
    _wake();
  }

  Map<String, Object?>? receipt(String mediaId) {
    final target = targetKey;
    return target == null
        ? null
        : catalog().record('replicas', 'receipt:$target:$mediaId');
  }

  Future<void> restoreLocalOriginal(
    String recordKey,
    SourceCancellation view,
  ) async {
    final access = acquireView?.call();
    void current() {
      check();
      view.check();
      access?.call();
    }

    while (_work != null) {
      await _work;
      current();
    }
    current();
    // Share the scheduler slot with remote deletion replay so restoring and
    // replaying an older deletion cannot act on one original concurrently.
    final done = Completer<void>();
    final waiting = done.future;
    _work = waiting;
    _notify();
    try {
      await imports.restoreOriginal(recordKey, view);
    } finally {
      done.complete();
      if (identical(_work, waiting)) _work = null;
      _notify();
    }
  }

  bool verified(Map<String, Object?> media) {
    final result = receipt(media['id'] as String);
    return result?['status'] == 'verified' &&
        result?['sourceVersion'] == media['version'];
  }

  Future<void> requestUpload(
    Iterable<String> ids, {
    LibraryQuery? scope,
    bool Function()? stillCurrent,
  }) async {
    final view = acquireView?.call();
    check();
    try {
      final requestedTarget = targetKey, requestedEpoch = _epoch;
      if (targetKey == null || !initialized)
        throw const SyncFailure(SyncFailureCode.notInitialized);
      final crypto = await VaultCrypto.load();
      view?.call();
      check();
      if (requestedTarget != targetKey || requestedEpoch != _epoch)
        throw const SyncFailure(SyncFailureCode.cancelled);
      if (stillCurrent != null && !stillCurrent()) return;
      final requested = scope == null
          ? ids.toSet()
          : catalog().queryIds(scope, within: ids).toSet();
      var queued = 0, skipped = 0, missing = 0;
      for (final id in requested) {
        check();
        final item = catalog().mediaById(id);
        if (item == null || item['local'] != true) {
          missing++;
          continue;
        }
        if (verified(item)) {
          skipped++;
          continue;
        }
        if (item['autoUploadSuppressed'] == true) {
          catalog().putMedia({
            ...item,
            'autoUploadSuppressed': false,
            'pendingRemoteDeletion': null,
          });
          final key = 'upload:$targetKey:$id:${item['version']}';
          final prior = catalog().record('jobs', key);
          if (prior != null)
            catalog().putRecord('jobs', key, {...prior, 'phase': 'deleted'});
        }
        _enqueue(item, crypto, explicit: true);
        queued++;
      }
      issue =
          '已提交 $queued 项上传请求，$skipped 项已有当前版本副本，$missing 项缺少本地资源。入队不代表备份完成。';
      _notify();
      _wake();
    } catch (e) {
      issue = describe(e);
      _notify();
    }
  }

  void _enqueue(
    Map<String, Object?> item,
    VaultCrypto crypto, {
    bool explicit = false,
  }) {
    final id = item['id'] as String;
    final key = 'upload:$targetKey:$id:${item['version']}';
    final old = catalog().record('jobs', key);
    if (old != null && !(explicit && old['phase'] == 'deleted')) {
      if (explicit && old['phase'] == 'failed')
        catalog().putRecord('jobs', key, {
          ...old,
          'phase': 'queued',
          'retryAt': null,
          'failure': null,
        });
      return;
    }
    catalog().putRecord('jobs', key, {
      'recordKey': key,
      'taskId': SyncFormat.newId(crypto),
      'mediaId': id,
      'revisionId': SyncFormat.newId(crypto),
      'sourceVersion': item['version'],
      'phase': 'queued',
      'attempts': 0,
      'retryAt': null,
      'failure': null,
    });
  }

  void pause() {
    acquireView?.call();
    check();
    catalog().putRecord('preferences', 'sync-control', {'paused': true});
    _source?.cancel();
    _access?.operation.cancel();
    revokeViewing();
    phase = 'paused';
    _notify();
  }

  void resume() {
    acquireView?.call();
    check();
    catalog().putRecord('preferences', 'sync-control', {'paused': false});
    if (targetKey != null)
      catalog().putRecord('preferences', 'sync-retry:$targetKey', {});
    issue = null;
    _notify();
    _wake();
  }

  void _wake() {
    if (_closed || _work != null || connection.busy) return;
    try {
      if (targetKey == null || !initialized || paused) return;
      final retry = catalog().record('preferences', 'sync-retry:$targetKey');
      if (retry?['blocked'] == true ||
          ((retry?['retryAt'] as int?) ?? 0) >
              DateTime.now().millisecondsSinceEpoch)
        return;
    } catch (_) {
      return;
    }
    _work = _cycle().whenComplete(() {
      _work = null;
      _notify();
    });
    _notify();
  }

  Future<void> initializeRepository() async {
    acquireView?.call();
    if (_closed || busy || connection.busy) return;
    _work = _initialize();
    _notify();
    try {
      await _work;
    } finally {
      _work = null;
      _notify();
      _wake();
    }
  }

  GitHubSyncRepository _repository(GitHubGitAccess access, VaultCrypto crypto) {
    _access = access;
    return GitHubSyncRepository(
      access: access,
      catalog: catalog,
      session: session(),
      objects: SyncObjectStore(directory, check),
      crypto: crypto,
      onProgress: _progress,
      cache: SyncCipherCache(directory, catalog, crypto, check),
      onRepositoryPasswordChanged: onRepositoryPasswordChanged,
      checkAccess: () {
        check();
        if (paused || connection.selected?.id != access.target.id)
          throw const SyncFailure(SyncFailureCode.cancelled);
      },
    );
  }

  Future<void> _initialize() async {
    try {
      phase = 'initializing';
      issue = null;
      _notify();
      final crypto = await VaultCrypto.load();
      check();
      await connection.withRepository(
        (access) => _repository(access, crypto).initialize(),
      );
      check();
      issue = '仓库加密入口已发布并读回验证，开始处理待同步媒体。';
    } catch (e) {
      if (!_closed) issue = describe(e);
    } finally {
      _access = null;
      if (!_closed) {
        phase = 'idle';
        _notify();
      }
    }
  }

  Future<void> _cycle() async {
    Map<String, Object?>? job;
    try {
      check();
      final cycleTarget = targetKey, cycleEpoch = _epoch;
      void cycleCurrent() {
        check();
        if (cycleTarget != targetKey || cycleEpoch != _epoch)
          throw const SyncFailure(SyncFailureCode.cancelled);
      }

      if (paused) return;
      final crypto = await VaultCrypto.load();
      cycleCurrent();
      await connection.withRepository((access) async {
        final repository = _repository(access, crypto);
        await repository.publishPasswordChange();
        final snapshot = await repository.snapshot();
        if (snapshot != null) {
          await repository.refreshMediaCatalog(snapshot);
          await _resumeDeletionIntents(repository, cycleCurrent);
        }
      });
      cycleCurrent();
      if (paused) return;
      // Finish discovery/pairing before creating independent photo/video jobs.
      // Existing jobs are also checked for component membership below.
      if (imports.scanning || imports.pending > 0) return;
      // Pagination is a work/memory limit, never a total-media quota.
      for (var offset = 0; ; offset += 100) {
        cycleCurrent();
        if (paused) return;
        final page = catalog().media(limit: 100, offset: offset);
        if (page.isEmpty) break;
        catalog().transaction(() {
          for (final item in page) {
            if (item['local'] == true &&
                item['pairedComponentOf'] == null &&
                item['autoUploadSuppressed'] != true &&
                !verified(item))
              _enqueue(item, crypto);
          }
        });
        await Future<void>.delayed(Duration.zero);
      }
      final target = targetKey!;
      var after = '';
      while (job == null) {
        final page = catalog().recordPage(
          'jobs',
          'upload:$target:',
          after: after,
        );
        if (page.isEmpty) return;
        after = page.last['recordId'] as String;
        for (final row in page) {
          final candidate = SyncFormat.map(row['body']);
          if (!{
                'complete',
                'failed',
                'conflict',
                'deleted',
              }.contains(candidate['phase']) &&
              ((candidate['retryAt'] as int?) ?? 0) <=
                  DateTime.now().millisecondsSinceEpoch) {
            job = candidate;
            break;
          }
        }
      }
      final selectedJob = job;
      final key = selectedJob['recordKey'] as String;
      final taskId = selectedJob['taskId'] as String;
      final media = catalog().mediaById(selectedJob['mediaId'] as String);
      if (media == null ||
          media['pairedComponentOf'] != null ||
          media['version'] != selectedJob['sourceVersion'] ||
          media['autoUploadSuppressed'] == true) {
        throw const SyncFailure(SyncFailureCode.sourceChanged);
      }
      _source = SourceCancellation(checkAccess: check);
      final epoch = _epoch;
      void current() {
        check();
        _source!.check();
        if (paused || epoch != _epoch || targetKey != target)
          throw const SyncFailure(SyncFailureCode.cancelled);
      }

      if (media['kind'] == 'livePhoto') {
        await _uploadLivePhoto(selectedJob, media, crypto, current);
        issue = catalog().record('jobs', key)?['phase'] == 'conflict'
            ? '实况照片的两份版本已保留，存在冲突，未自动覆盖。'
            : '实况照片的图片与动态资源已上传、读回认证并共同发布。';
        return;
      }
      var prepared = catalog().record('jobs', 'resource:$taskId');
      final objects = SyncObjectStore(directory, current);
      if (prepared == null) {
        // Interrupted preparation is not reusable as a complete source version.
        await objects.removeTask(taskId);
        catalog().deleteRecordPrefix('jobs', 'chunk:$taskId:');
        _progress('encrypting', 0, media['size'] as int);
        catalog().putRecord('jobs', key, {
          ...selectedJob,
          'phase': 'preparing',
        });
        prepared = await SyncResourcePreparer(
          catalog: catalog,
          session: session,
          imports: imports,
          objects: objects,
          checkAccess: current,
          onProgress: (done, total) => _progress('encrypting', done, total),
        ).prepare(taskId, media, selectedJob['revisionId'] as String, _source!);
        current();
        catalog().putRecord('jobs', key, {...selectedJob, 'phase': 'prepared'});
      }
      current();
      await connection.withRepository((access) async {
        final repository = _repository(access, crypto);
        final snap = await repository.snapshot();
        if (snap == null)
          throw const SyncFailure(SyncFailureCode.notInitialized);
        current();
        catalog().putRecord('jobs', key, {
          ...selectedJob,
          'phase': 'uploading',
        });
        _progress('uploading', 0, media['size'] as int);
        var resourceRef = catalog().record('jobs', 'uploaded-resource:$taskId');
        resourceRef ??= await repository.uploadResource(taskId, prepared!);
        current();
        catalog().putRecord('jobs', 'uploaded-resource:$taskId', resourceRef);
        _progress('publishing', media['size'] as int, media['size'] as int);
        final result = await repository.publishMedia(
          taskId,
          media,
          selectedJob['revisionId'] as String,
          resourceRef,
        );
        current();
        catalog().transaction(() {
          catalog().putRecord('replicas', 'receipt:$target:${media['id']}', {
            ...result,
            'status': result['conflict'] == true ? 'conflict' : 'verified',
            'sourceVersion': media['version'],
            'target': target,
            'confirmedAt': DateTime.now().millisecondsSinceEpoch,
          });
          catalog().putRecord('jobs', key, {
            ...selectedJob,
            'phase': result['conflict'] == true ? 'conflict' : 'complete',
            'retryAt': null,
            'failure': null,
          });
        });
      });
      current();
      await objects.removeTask(taskId);
      issue = catalog().record('jobs', key)?['phase'] == 'conflict'
          ? '两份媒体版本均已保留在仓库，存在冲突，未自动选择或覆盖。'
          : '已从 GitHub 读回校验并发布当前媒体版本。';
    } catch (e) {
      if (!_closed) {
        try {
          check();
          if (job != null) {
            final prior =
                catalog().record('jobs', job['recordKey'] as String) ?? job;
            if (!{'complete', 'conflict'}.contains(prior['phase'])) {
              final attempts = (job['attempts'] as int? ?? 0) + 1;
              final retryable =
                  e is RepositoryFailure &&
                      {
                        RepositoryFailureCode.network,
                        RepositoryFailureCode.rateLimited,
                        RepositoryFailureCode.conflict,
                        RepositoryFailureCode.cancelled,
                      }.contains(e.code) ||
                  e is SyncFailure && e.code == SyncFailureCode.cancelled ||
                  e is SourceFailure &&
                      {
                        SourceFailureCode.busy,
                        SourceFailureCode.cancelled,
                      }.contains(e.code);
              final delay = [5, 15, 60, 300][min(attempts - 1, 3)];
              var retry = DateTime.now().add(
                Duration(
                  milliseconds:
                      (delay * 1000 * (1 + Random.secure().nextDouble() * .2))
                          .ceil(),
                ),
              );
              if (e is RepositoryFailure &&
                  e.retryAt != null &&
                  e.retryAt!.isAfter(retry))
                retry = e.retryAt!;
              catalog().putRecord('jobs', job['recordKey'] as String, {
                ...prior,
                'phase': retryable ? 'retry' : 'failed',
                'attempts': attempts,
                'retryAt': retryable ? retry.millisecondsSinceEpoch : null,
                'failure': describe(e),
              });
            }
          }
          issue = describe(e);
          if (job == null) {
            final retryable =
                e is RepositoryFailure &&
                    {
                      RepositoryFailureCode.network,
                      RepositoryFailureCode.rateLimited,
                      RepositoryFailureCode.conflict,
                      RepositoryFailureCode.cancelled,
                    }.contains(e.code) ||
                e is SyncFailure && e.code == SyncFailureCode.cancelled;
            final retryKey = 'sync-retry:$targetKey';
            final attempts =
                (catalog().record('preferences', retryKey)?['attempts']
                        as int? ??
                    0) +
                1;
            var retry = DateTime.now().add(
              Duration(
                milliseconds:
                    ([5, 15, 60, 300][min(attempts - 1, 3)] *
                            1000 *
                            (1 + Random.secure().nextDouble() * .2))
                        .ceil(),
              ),
            );
            if (e is RepositoryFailure &&
                e.retryAt != null &&
                e.retryAt!.isAfter(retry))
              retry = e.retryAt!;
            catalog().putRecord('preferences', retryKey, {
              'attempts': attempts,
              'retryAt': retry.millisecondsSinceEpoch,
              'blocked': !retryable,
              'failure': issue,
            });
          }
        } catch (_) {
          /* Revocation may have already closed the encrypted catalog. */
        }
      }
    } finally {
      _source?.cancel();
      _source = null;
      _access = null;
      if (!_closed) {
        phase = 'idle';
        _notify();
      }
    }
  }

  Future<void> verifyRemote(String mediaId) async {
    acquireView?.call();
    if (_closed || busy || connection.busy) return;
    final expectedTarget = targetKey;
    _work = (() async {
      try {
        final result = receipt(mediaId);
        if (result == null)
          throw const SyncFailure(SyncFailureCode.notInitialized);
        final crypto = await VaultCrypto.load();
        check();
        if (targetKey != expectedTarget)
          throw const SyncFailure(SyncFailureCode.cancelled);
        _progress('downloading', 0, 0);
        await connection.withRepository((access) async {
          final repository = _repository(access, crypto);
          await repository.requireActiveMedia(
            mediaId,
            SyncFormat.map(result['media']),
          );
          await repository.recoverMedia(SyncFormat.map(result['media']), (
            resource,
            bytes,
          ) async {
            _progress(
              'downloading',
              bytesDone + bytes.length,
              SyncFormat.count(resource['length']),
            );
          });
        });
        check();
        final current = receipt(mediaId);
        if (current?['revisionId'] == result['revisionId']) {
          catalog().putRecord('replicas', 'receipt:$targetKey:$mediaId', {
            ...result,
            'status': 'verified',
            'confirmedAt': DateTime.now().millisecondsSinceEpoch,
          });
        }
        issue = '仓库原始资源已实际下载、认证解密并通过完整摘要校验。';
      } catch (e) {
        if (!_closed) issue = describe(e);
      } finally {
        _access = null;
        if (!_closed) phase = 'idle';
      }
    })();
    _notify();
    try {
      await _work;
    } finally {
      _work = null;
      _notify();
    }
  }

  Future<void> _uploadLivePhoto(
    Map<String, Object?> job,
    Map<String, Object?> media,
    VaultCrypto crypto,
    void Function() current,
  ) async {
    final taskId = job['taskId'] as String;
    final mediaId = media['id'] as String;
    final refs = media['resources'];
    if (refs is! List || refs.length != 2 || media['pairing'] is! Map)
      SyncFormat.invalid();
    final objects = SyncObjectStore(directory, current);
    final planKey = 'live-plan:$taskId';
    var plan = catalog().record('jobs', planKey);
    plan ??= {
      'tasks': [SyncFormat.newId(crypto), SyncFormat.newId(crypto)],
    };
    catalog().putRecord('jobs', planKey, plan);
    final tasks = List<String>.from(plan['tasks'] as List);
    final descriptors = <Map<String, Object?>>[];
    for (var i = 0; i < refs.length; i++) {
      current();
      final ref = SyncFormat.map(refs[i]);
      final original = catalog().mediaById(ref['sourceMediaId'] as String);
      if (original == null ||
          original['local'] != true ||
          original['version'] != ref['version']) {
        throw const SyncFailure(SyncFailureCode.sourceChanged);
      }
      var descriptor = catalog().record('jobs', 'resource:${tasks[i]}');
      if (descriptor == null) {
        await objects.removeTask(tasks[i]);
        catalog().deleteRecordPrefix('jobs', 'chunk:${tasks[i]}:');
        descriptor =
            await SyncResourcePreparer(
              catalog: catalog,
              session: session,
              imports: imports,
              objects: objects,
              checkAccess: current,
              onProgress: (done, total) => _progress('encrypting', done, total),
            ).prepare(
              tasks[i],
              {
                ...original,
                'id': mediaId,
                'sourceMediaId': original['id'],
                'role': ref['role'],
              },
              job['revisionId'] as String,
              _source!,
            );
      }
      descriptors.add(descriptor);
    }
    await connection.withRepository((access) async {
      final repository = _repository(access, crypto);
      final snapshot = await repository.snapshot();
      if (snapshot == null)
        throw const SyncFailure(SyncFailureCode.notInitialized);
      final resources = <Map<String, Object?>>[];
      for (var i = 0; i < tasks.length; i++) {
        current();
        var resource = catalog().record(
          'jobs',
          'uploaded-resource:${tasks[i]}',
        );
        resource ??= await repository.uploadResource(tasks[i], descriptors[i]);
        current();
        catalog().putRecord('jobs', 'uploaded-resource:${tasks[i]}', resource);
        resources.add(resource);
        var after = '';
        while (true) {
          final paths = catalog().recordPage(
            'jobs',
            'path:${tasks[i]}:',
            after: after,
          );
          if (paths.isEmpty) break;
          after = paths.last['recordId'] as String;
          for (final row in paths) {
            final value = SyncFormat.map(row['body']);
            catalog().putRecord(
              'jobs',
              'path:$taskId:${value['objectId']}',
              value,
            );
          }
        }
      }
      current();
      final result = await repository.publishMedia(
        taskId,
        media,
        job['revisionId'] as String,
        resources.first,
        additionalResources: resources.skip(1).toList(),
      );
      current();
      catalog().transaction(() {
        catalog().putRecord('replicas', 'receipt:$targetKey:$mediaId', {
          ...result,
          'status': result['conflict'] == true ? 'conflict' : 'verified',
          'sourceVersion': media['version'],
          'target': targetKey,
          'confirmedAt': DateTime.now().millisecondsSinceEpoch,
        });
        catalog().putRecord('jobs', job['recordKey'] as String, {
          ...job,
          'phase': result['conflict'] == true ? 'conflict' : 'complete',
        });
      });
    });
    for (final task in tasks) {
      await objects.removeTask(task);
    }
  }

  Future<void> _resumeDeletionIntents(
    GitHubSyncRepository repository,
    void Function() current,
  ) async {
    // A started intention survives process termination. Explicit failures stay
    // visible for a user retry; they are not retried destructively every tick.
    var after = '';
    while (true) {
      final rows = catalog().recordPage('jobs', 'delete-intent:', after: after);
      if (rows.isEmpty) break;
      after = rows.last['recordId'] as String;
      for (final row in rows) {
        current();
        var job = SyncFormat.map(row['body']);
        if (job['target'] != targetKey ||
            !{'prepared', 'local-removed', 'publishing'}.contains(job['phase']))
          continue;
        final id = job['mediaId'] as String, version = job['version'] as String;
        final key = row['recordId'] as String;
        final media = catalog().mediaById(id);
        final token = SourceCancellation(checkAccess: current);
        void save(Map<String, Object?> updates) {
          job = {...job, ...updates};
          catalog().putRecord('jobs', key, job);
        }

        try {
          if (media == null || media['version'] != version)
            throw const SyncFailure(SyncFailureCode.conflict);
          if (job['scope'] == 'local') {
            final remote = receipt(id);
            if (remote == null || remote['sourceVersion'] != version)
              throw const SyncFailure(SyncFailureCode.sourceChanged);
            await repository.requireActiveMedia(
              id,
              SyncFormat.map(remote['media']),
            );
            await repository.recoverMedia(SyncFormat.map(remote['media']), (
              _,
              __,
            ) async {
              current();
            });
          } else if (job['scope'] == 'repository') {
            await imports.readLocalOriginal(id, version, token, (_) async {
              current();
            });
          }
          if (job['scope'] != 'repository' && job['localDone'] != true) {
            await imports.recycleOriginal(
              id,
              version,
              job['operationId'] as String,
              token,
            );
            current();
            save({'localDone': true, 'phase': 'local-removed'});
          }
          if (job['scope'] != 'local' && job['remoteDone'] != true) {
            save({'phase': 'publishing'});
            if (job['scope'] == 'repository') {
              await imports.withVerifiedOriginals(
                id,
                version,
                token,
                () => repository.deleteMedia(
                  job['operationId'] as String,
                  id,
                  version,
                  'repository',
                ),
              );
            } else {
              await repository.deleteMedia(
                job['operationId'] as String,
                id,
                version,
                'all',
              );
            }
            current();
            save({'remoteDone': true});
          }
          save({'phase': 'complete', 'failure': null});
        } catch (_) {
          current();
          save({'phase': 'incomplete', 'failure': '删除尚未全部完成；请解锁后检查源文件／仓库并重试。'});
        } finally {
          token.cancel();
        }
      }
    }
    for (var offset = 0; ; offset += 100) {
      final rows = catalog().media(limit: 100, offset: offset);
      if (rows.isEmpty) break;
      for (final record in rows) {
        current();
        if (record['pendingRemoteDeletion'] is! Map) continue;
        final deletion = SyncFormat.map(record['pendingRemoteDeletion']);
        final id = record['id'] as String;
        if (record['version'] != deletion['sourceVersion']) {
          catalog().putRecord(
            'jobs',
            'remote-delete:${deletion['operationId']}:$id',
            {
              'phase': 'conflict',
              'mediaId': id,
              'failure': '仓库已删除旧版本，本地内容已改变，保留原文件。',
            },
          );
          continue;
        }
        final token = SourceCancellation(checkAccess: current);
        try {
          if (record['local'] == true)
            await imports.recycleOriginal(
              id,
              record['version'] as String,
              deletion['operationId'] as String,
              token,
            );
          current();
          catalog().transaction(() {
            final latest = catalog().mediaById(id)!;
            catalog().putMedia({
              ...latest,
              'pendingRemoteDeletion': null,
              'autoUploadSuppressed': true,
              'deletedFromLibrary': latest['local'] != true,
            });
            catalog().putRecord(
              'jobs',
              'remote-delete:${deletion['operationId']}:$id',
              {'phase': 'complete', 'mediaId': id},
            );
          });
        } catch (_) {
          current();
          catalog().putRecord(
            'jobs',
            'remote-delete:${deletion['operationId']}:$id',
            {
              'phase': 'incomplete',
              'mediaId': id,
              'failure': '待解锁或原文件恢复可读后接续本机删除。',
            },
          );
        } finally {
          token.cancel();
        }
      }
    }
  }

  Future<void> deleteRemoteOriginal(
    String id,
    String version,
    String taskId,
    String scope,
    SourceCancellation view,
  ) async {
    final accessView = acquireView?.call();
    final target = targetKey;
    final epoch = _viewEpoch;
    void current() {
      check();
      view.check();
      accessView?.call();
      if (target == null ||
          target != targetKey ||
          epoch != _viewEpoch ||
          paused) {
        throw const SyncFailure(SyncFailureCode.cancelled);
      }
    }

    while (_work != null) {
      await _work;
      current();
    }
    current();
    if (connection.busy) throw const SyncFailure(SyncFailureCode.cancelled);
    void Function()? remove;
    final operation = (() async {
      final crypto = await VaultCrypto.load();
      current();
      await connection.withRepository(
        (access) async {
          final repository = _repository(access, crypto);
          if (scope == 'repository') {
            await imports.withVerifiedOriginals(
              id,
              version,
              view,
              () => repository.deleteMedia(taskId, id, version, scope),
            );
          } else {
            await repository.deleteMedia(taskId, id, version, scope);
          }
          current();
          final snapshot = await repository.snapshot();
          if (snapshot != null) await repository.refreshMediaCatalog(snapshot);
        },
        onOperation: (op) {
          _viewOperation = op;
          remove = view.onCancel(op.cancel);
          current();
        },
      );
      current();
      catalog().transaction(() {
        final record = catalog().mediaById(id);
        if (record != null)
          catalog().putMedia({
            ...record,
            'autoUploadSuppressed': true,
            'deletedFromLibrary': record['local'] != true,
          });
        final key = 'upload:$target:$id:$version';
        final upload = catalog().record('jobs', key);
        if (upload != null)
          catalog().putRecord('jobs', key, {...upload, 'phase': 'deleted'});
      });
    })();
    final waiting = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    _work = waiting;
    try {
      await operation;
    } finally {
      remove?.call();
      _viewOperation = null;
      _access = null;
      if (identical(_work, waiting)) _work = null;
      _notify();
    }
  }

  Future<void> readRemoteOriginal(
    String id,
    String version,
    SourceCancellation view,
    Future<void> Function(Map<String, Object?> resource, Uint8List bytes)
    consume,
  ) async {
    final accessView = acquireView?.call();
    final target = targetKey;
    final epoch = _viewEpoch;
    void current() {
      check();
      view.check();
      accessView?.call();
      if (epoch != _viewEpoch ||
          target != targetKey ||
          paused ||
          catalog().mediaById(id)?['version'] != version) {
        throw const SyncFailure(SyncFailureCode.cancelled);
      }
    }

    while (_work != null) {
      await _work;
      current();
    }
    current();
    if (connection.busy) throw const SyncFailure(SyncFailureCode.cancelled);
    void Function()? remove;
    final operation = (() async {
      final crypto = await VaultCrypto.load();
      current();
      await connection.withRepository(
        (access) async {
          final repository = _repository(access, crypto);
          await repository.snapshot();
          final result = receipt(id);
          if (result == null || result['sourceVersion'] != version) {
            throw const SyncFailure(SyncFailureCode.sourceChanged);
          }
          await repository.requireActiveMedia(
            id,
            SyncFormat.map(result['media']),
          );
          await repository.recoverMedia(SyncFormat.map(result['media']), (
            resource,
            bytes,
          ) async {
            current();
            await consume(resource, bytes);
            current();
          });
        },
        onOperation: (op) {
          _viewOperation = op;
          remove = view.onCancel(op.cancel);
          current();
        },
      );
      current();
    })();
    final waiting = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    _work = waiting;
    try {
      await operation;
    } finally {
      remove?.call();
      _viewOperation = null;
      _access = null;
      if (identical(_work, waiting)) _work = null;
      _notify();
    }
  }

  SourceCancellation beginThumbnail(SourceCancellation parent) {
    final access = acquireView?.call();
    final epoch = _viewEpoch;
    final target = targetKey;
    final token = SourceCancellation(
      checkAccess: () {
        check();
        parent.check();
        access?.call();
        if (epoch != _viewEpoch ||
            target != targetKey ||
            paused ||
            _playbackView?.cancelled == false) {
          throw const SourceFailure(SourceFailureCode.cancelled);
        }
      },
    );
    token.check();
    _thumbnailViews.add(token);
    final removeParent = parent.onCancel(token.cancel);
    token.onCancel(() {
      removeParent();
      _thumbnailViews.remove(token);
    });
    return token;
  }

  Future<LoopbackMediaSource> openRemotePlayback(
    String mediaId,
    String version,
    SourceCancellation view,
    void Function() onFailure, {
    bool thumbnail = false,
    bool stillImage = false,
  }) async {
    if (thumbnail) {
      view.check();
      if (!_thumbnailViews.contains(view) || _playbackView?.cancelled == false)
        throw const SourceFailure(SourceFailureCode.cancelled);
    } else {
      revokeViewing();
      _playbackView = view;
    }
    final accessView = acquireView?.call();
    final epoch = _viewEpoch;
    final target = targetKey;
    void current() {
      view.check();
      check();
      accessView?.call();
      if (epoch != _viewEpoch ||
          target == null ||
          targetKey != target ||
          paused ||
          catalog().mediaById(mediaId)?['version'] != version) {
        throw const SyncFailure(SyncFailureCode.cancelled);
      }
    }

    Future<T> read<T>(
      SourceCancellation token,
      Future<T> Function(GitHubSyncRepository repository) action,
    ) async {
      while (_work != null) {
        await _work;
        token.check();
        current();
      }
      current();
      token.check();
      if (connection.busy) throw const SyncFailure(SyncFailureCode.cancelled);
      void Function()? remove;
      final operation = (() async {
        final crypto = await VaultCrypto.load();
        current();
        return connection.withRepository(
          (access) async {
            current();
            final repository = _repository(access, crypto);
            final result = await action(repository);
            try {
              token.check();
              current();
              return result;
            } catch (_) {
              if (result is Uint8List) result.fillRange(0, result.length, 0);
              rethrow;
            }
          },
          onOperation: (op) {
            _viewOperation = op;
            remove = token.onCancel(op.cancel);
            current();
          },
        );
      })();
      final waiting = operation.then<void>(
        (_) {},
        onError: (Object _, StackTrace __) {},
      );
      _work = waiting;
      try {
        return await operation;
      } finally {
        remove?.call();
        _viewOperation = null;
        _access = null;
        if (identical(_work, waiting)) _work = null;
      }
    }

    final result = receipt(mediaId);
    if (result == null) throw const SyncFailure(SyncFailureCode.notInitialized);
    final resource = await read(view, (repository) async {
      await repository.requireActiveMedia(
        mediaId,
        SyncFormat.map(result['media']),
      );
      current();
      final latest = receipt(mediaId);
      if (latest?['revisionId'] != result['revisionId']) {
        throw const SyncFailure(SyncFailureCode.conflict);
      }
      return repository.openPlaybackResource(
        SyncFormat.map(result['media']),
        mediaId: mediaId,
        revision: result['revisionId'] as String,
        stillImage: stillImage,
      );
    });
    current();
    var thumbnailBytes = 0;
    return LoopbackMediaSource.open(
      length: resource.length,
      view: view,
      read: (index, token) => read(token, (repository) async {
        await repository.requireActiveMedia(
          mediaId,
          SyncFormat.map(result['media']),
        );
        if (thumbnail && thumbnailBytes >= 64 * 1024 * 1024)
          throw const SyncFailure(SyncFailureCode.space);
        final bytes = await repository.readPlaybackBlock(resource, index);
        if (thumbnail) thumbnailBytes += bytes.length;
        return bytes;
      }),
      onFailure: onFailure,
    );
  }

  Future<Uint8List> readRemotePhoto(String mediaId) async {
    final view = acquireView?.call();
    final epoch = _viewEpoch;
    void viewCurrent() {
      check();
      if (epoch != _viewEpoch) {
        throw const SyncFailure(SyncFailureCode.cancelled);
      }
      view?.call();
    }

    final expectedTarget = targetKey;
    await _work;
    viewCurrent();
    if (targetKey != expectedTarget)
      throw const SyncFailure(SyncFailureCode.cancelled);
    if (paused || busy || connection.busy)
      throw const SyncFailure(SyncFailureCode.cancelled);
    final media = catalog().mediaById(mediaId);
    if (!{'photo', 'livePhoto'}.contains(media?['kind']) ||
        (media?['kind'] == 'photo' &&
            (media?['size'] as int? ?? 0) > 32 * 1024 * 1024))
      throw const SyncFailure(SyncFailureCode.sourceChanged);
    final result = receipt(mediaId);
    if (result == null) throw const SyncFailure(SyncFailureCode.notInitialized);
    final pieces = <Uint8List>[];
    final operation = (() async {
      try {
        final crypto = await VaultCrypto.load();
        viewCurrent();
        if (targetKey != expectedTarget)
          throw const SyncFailure(SyncFailureCode.cancelled);
        var length = 0;
        await connection.withRepository(
          (access) async {
            viewCurrent();
            final repository = _repository(access, crypto);
            await repository.requireActiveMedia(
              mediaId,
              SyncFormat.map(result['media']),
            );
            await repository.recoverCoverImage(
              SyncFormat.map(result['media']),
              (resource, bytes) async {
                viewCurrent();
                if (resource['role'] != 'image' ||
                    length + bytes.length > 32 * 1024 * 1024)
                  throw const SyncFailure(SyncFailureCode.format);
                final piece = Uint8List.fromList(bytes);
                pieces.add(piece);
                _viewPieces.add(piece);
                length += bytes.length;
              },
            );
          },
          onOperation: (op) {
            _viewOperation = op;
            viewCurrent();
          },
        );
        viewCurrent();
        final output = Uint8List(length);
        var offset = 0;
        for (final piece in pieces) {
          output.setRange(offset, offset + piece.length, piece);
          offset += piece.length;
        }
        _photoBuffers.add(output);
        return output;
      } finally {
        for (final piece in pieces) {
          piece.fillRange(0, piece.length, 0);
          _viewPieces.remove(piece);
        }
        _viewOperation = null;
        _access = null;
      }
    })();
    _work = operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _notify();
    try {
      return await operation;
    } finally {
      _work = null;
      _notify();
    }
  }

  void releasePhoto(Uint8List? bytes) {
    if (bytes == null) return;
    bytes.fillRange(0, bytes.length, 0);
    _photoBuffers.remove(bytes);
  }

  void revokeViewing() {
    _viewEpoch++;
    for (final token in _thumbnailViews.toList()) {
      token.cancel();
    }
    _thumbnailViews.clear();
    _playbackView?.cancel();
    _playbackView = null;
    _viewOperation?.cancel();
    for (final bytes in [..._photoBuffers, ..._viewPieces]) {
      bytes.fillRange(0, bytes.length, 0);
    }
    _photoBuffers.clear();
    _viewPieces.clear();
  }

  Future<void> get settled async {
    await _work;
  }

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    _epoch++;
    _timer?.cancel();
    imports.removeListener(_wake);
    connection.removeListener(_connectionChanged);
    _source?.cancel();
    _access?.operation.cancel();
    revokeViewing();
    super.dispose();
  }

  static String describe(Object error) {
    if (error is RepositoryFailure) return GitHubConnection.describe(error);
    if (error is SourceFailure) return describeSourceFailure(error);
    if (error is SyncFailure)
      return switch (error.code) {
        SyncFailureCode.notInitialized => '请先选择私有仓库并明确初始化加密入口。',
        SyncFailureCode.space => '程序数据盘空间不足，未修改原文件；释放空间后可重试。',
        SyncFailureCode.sourceChanged => '本地来源缺失、版本已改变或必要资源不完整，未报告备份成功。',
        SyncFailureCode.cancelled => '同步已暂停，解锁并满足其它运行条件后核对接续。',
        SyncFailureCode.conflict => '仓库版本、密码包装或提交历史发生冲突，已停止自动覆盖。',
        SyncFailureCode.wrongVault => '仓库属于另一个加密照片库，不能覆盖或自动合并。',
        SyncFailureCode.repositoryPasswordRequired =>
          '仓库照片密码已变化，须正确验证当前仓库照片密码后继续。',
        _ => '仓库格式或完整性校验失败，已保留原文件和未完成记录。',
      };
    return '同步未完成，请检查网络和程序数据目录；原文件及已提交记录已保留。';
  }
}
