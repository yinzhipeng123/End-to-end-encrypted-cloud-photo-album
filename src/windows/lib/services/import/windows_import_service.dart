import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:encrypted_photo_shared/security/vault_crypto.dart';
import 'package:encrypted_photo_app/storage/library_catalog.dart';
import 'package:encrypted_photo_app/services/import/windows_source_reader.dart';
import 'package:encrypted_photo_app/services/import/windows_media_metadata.dart';

/// One background-vault lifetime. All durable work lives in SQLCipher; watcher
/// events are hints and never deletion instructions. No repository operations.
final class WindowsImportService extends ChangeNotifier {
  WindowsImportService({required this.catalog, this.acquireView}) {
    token = SourceCancellation(
      checkAccess: () {
        catalog();
      },
    );
  }
  final LibraryCatalog Function() catalog;
  final void Function() Function()? acquireView;
  late final SourceCancellation token;
  final _reader = WindowsSourceReader();
  final _watchers = <String, StreamSubscription<FileSystemEvent>>{};
  final _forceSources = <String>{};
  final _previewBuffers = <Uint8List>{};
  final _previewTokens = <SourceCancellation>{};
  Timer? _tick, _debounce, _maxDebounce, _periodic;
  Future<void>? _running;
  Future<void> _ioTail = Future<void>.value();
  bool _disposed = false, _scanRequested = false;
  bool scanning = false;
  int bytesRead = 0;
  String? issue;
  static const extensions = {
    'jpg',
    'jpeg',
    'png',
    'webp',
    'gif',
    'bmp',
    'heic',
    'heif',
    'tif',
    'tiff',
    'avif',
    'mp4',
    'mov',
    'm4v',
    'avi',
    'mkv',
    'webm',
    '3gp',
  };
  List<Map<String, Object?>> get sources => catalog().sources();
  List<Map<String, Object?>> get counts => catalog().sourceImportCounts();
  int get pending => catalog().pendingImportCount;
  int get mediaCount => catalog().mediaCount;
  List<Map<String, Object?>> page(int page) =>
      catalog().media(limit: 200, offset: page * 200);

  void start() {
    if (catalog().record('preferences', 'media-metadata-version')?['version'] !=
        1) {
      _forceSources.addAll(catalog().sources().map((s) => s['id'] as String));
    }
    _tick ??= Timer.periodic(const Duration(seconds: 1), (_) => _kick());
    requestScan();
  }

  Future<void> addFolder(String selected) async {
    final view = acquireView?.call();
    token.check();
    try {
      final path = WindowsSourceReader.validateDirectory(selected);
      if (path.toLowerCase().split('\\').contains('.epa-recycle')) {
        throw const SourceFailure(SourceFailureCode.unsafePath);
      }
      final crypto = await VaultCrypto.load();
      view?.call();
      token.check();
      final existing = catalog().sources().where((s) => s['path'] == path);
      if (existing.isEmpty) {
        catalog().putSource(
          id: _id(crypto),
          path: path,
          state: {'phase': 'waiting'},
        );
      }
      issue = null;
      requestScan();
    } on SourceFailure catch (e) {
      issue = describeSourceFailure(e);
      _notify();
    } on CatalogFailure {
      issue = '导入来源未能保存，请检查程序数据目录；已有记录已保留。';
      _notify();
    }
  }

  static String _id(VaultCrypto crypto) => crypto
      .randomBytes(16)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();

  void requestScan() {
    if (_disposed) return;
    _scanRequested = true;
    _kick();
  }

  void _changed(String source) {
    if (_disposed) return;
    _forceSources.add(source);
    _debounce?.cancel();
    void ready() {
      _debounce?.cancel();
      _maxDebounce?.cancel();
      _debounce = null;
      _maxDebounce = null;
      requestScan();
    }

    _debounce = Timer(const Duration(seconds: 1), ready);
    _maxDebounce ??= Timer(const Duration(seconds: 5), ready);
  }

  void _watch(String id, String path) {
    if (_watchers.containsKey(id)) return;
    try {
      _watchers[id] = Directory(path)
          .watch(recursive: true)
          .listen(
            (_) => _changed(id),
            onError: (Object _) {
              _watchers.remove(id)?.cancel();
              _changed(id);
            },
            onDone: () {
              _watchers.remove(id);
              _changed(id);
            },
          );
    } on FileSystemException {
      /* Periodic enumeration remains authoritative. */
    }
  }

  void _kick() {
    if (_disposed || _running != null) return;
    _running = _work().whenComplete(() {
      _running = null;
      if (!_disposed && _scanRequested) _kick();
    });
  }

  Future<T> _read<T>(Future<T> Function() action) {
    final next = _ioTail.then((_) {
      token.check();
      return action();
    });
    _ioTail = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  /// Shares the approved single-reader budget with import and previews.
  Future<T> withContentRead<T>(Future<T> Function() action) => _read(action);

  Future<void> _work() async {
    var didWork = false;
    try {
      token.check();
      if (_scanRequested) {
        didWork = true;
        _scanRequested = false;
        scanning = true;
        _notify();
        final crypto = await VaultCrypto.load();
        token.check();
        for (final source in catalog().sources()) {
          token.check();
          final id = source['id'] as String, path = source['path'] as String;
          final force = _forceSources.remove(id);
          _watch(id, path);
          final epoch = _id(crypto);
          var complete = true;
          String? scanIssue;
          var batch = 0;
          Future<void> walk(String directory) async {
            try {
              await WindowsSourceReader.withDirectory(directory, token, (
                canonical,
              ) async {
                await for (final entry in Directory(
                  canonical,
                ).list(followLinks: false)) {
                  token.check();
                  if (entry is Link) {
                    complete = false;
                    scanIssue = '部分链接未遍历，未判定缺失文件';
                    continue;
                  }
                  if (entry is Directory) {
                    if (entry.path
                            .replaceAll('\\', '/')
                            .split('/')
                            .last
                            .toLowerCase() ==
                        '.epa-recycle')
                      continue;
                    await walk(entry.path);
                    continue;
                  }
                  if (entry is! File ||
                      !extensions.contains(
                        entry.path.split('.').last.toLowerCase(),
                      ))
                    continue;
                  try {
                    final stat = await entry.stat();
                    token.check();
                    if (stat.type != FileSystemEntityType.file) {
                      complete = false;
                      continue;
                    }
                    catalog().observeImport(
                      source: id,
                      path: WindowsSourceReader.absolute(entry.path),
                      size: stat.size,
                      modified: stat.modified.microsecondsSinceEpoch,
                      epoch: epoch,
                      now: DateTime.now().millisecondsSinceEpoch,
                      quietMilliseconds: 2000,
                      force: force,
                    );
                    if (++batch % 100 == 0) {
                      _notify();
                      await Future<void>.delayed(Duration.zero);
                    }
                  } on FileSystemException {
                    complete = false;
                    scanIssue = '部分文件无法读取，未判定缺失文件';
                  }
                }
              });
            } on FileSystemException {
              complete = false;
              scanIssue = '目录暂不可访问，已有记录保留';
            } on SourceFailure {
              token.check();
              complete = false;
              scanIssue = '部分目录不可访问或包含链接，已有记录保留';
            }
          }

          await walk(path);
          token.check();
          catalog().putSource(
            id: id,
            path: path,
            state: {
              'phase': complete ? 'checking' : 'incomplete',
              'epoch': epoch,
              'complete': complete,
              'issue': scanIssue,
              'enumeratedAt': DateTime.now().millisecondsSinceEpoch,
            },
          );
        }
        scanning = false;
        _periodic?.cancel();
        _periodic = Timer(const Duration(seconds: 60), requestScan);
      }
      while (!_disposed) {
        final candidates = catalog().importCandidates(
          DateTime.now().millisecondsSinceEpoch,
        );
        if (candidates.isEmpty) break;
        didWork = true;
        for (final candidate in candidates) {
          token.check();
          final source = candidate['source_id'] as String;
          final path = candidate['path'] as String;
          try {
            final stat = await File(path).stat();
            token.check();
            if (stat.size != candidate['size'] ||
                stat.modified.microsecondsSinceEpoch != candidate['modified']) {
              catalog().observeImport(
                source: source,
                path: path,
                size: stat.size,
                modified: stat.modified.microsecondsSinceEpoch,
                epoch: candidate['epoch'] as String,
                now: DateTime.now().millisecondsSinceEpoch,
                quietMilliseconds: 2000,
                force: true,
              );
              continue;
            }
            await _read(
              () => _reader.withSnapshot(
                path,
                candidate['root'] as String,
                token,
                (snapshot) async {
                  final metadata = await WindowsMediaMetadata.read(
                    snapshot.path,
                    token,
                  );
                  final crypto = await VaultCrypto.load();
                  token.check();
                  // The handle is still held during this real encrypted transaction.
                  catalog().commitImport(
                    source: source,
                    path: path,
                    newId: _id(crypto),
                    nativeId: snapshot.identity,
                    created: snapshot.created,
                    observed: {
                      'kind': snapshot.kind,
                      'format': snapshot.format,
                      'fileName': snapshot.fileName,
                      'path': snapshot.path,
                      'size': snapshot.size,
                      'version': snapshot.version,
                      'observedAt': DateTime.now().millisecondsSinceEpoch,
                      'verifiedAt': DateTime.now().millisecondsSinceEpoch,
                      'modifiedAt':
                          (snapshot.modified ~/ 10) - 11644473600000000,
                      'takenAt': null,
                      'duration': null,
                      'decodeStatus': 'unverified',
                      'identityReliable': snapshot.identity != null,
                      'sourceMetadata': metadata,
                    },
                  );
                },
                onProgress: (n) {
                  bytesRead = n;
                },
              ),
            );
          } on SourceFailure catch (e) {
            if (e.code == SourceFailureCode.cancelled) rethrow;
            token.check();
            catalog().retryImport(
              source,
              path,
              DateTime.now().millisecondsSinceEpoch,
              describeSourceFailure(e),
              unsupported:
                  e.code == SourceFailureCode.unsupported ||
                  e.code == SourceFailureCode.unsafePath,
            );
          } on FileSystemException {
            token.check();
            catalog().retryImport(
              source,
              path,
              DateTime.now().millisecondsSinceEpoch,
              '原文件暂不可读取',
            );
          }
          _notify();
        }
      }
      token.check();
      // Resolve moves before sweeping stale paths, so organization follows the
      // native identity even when an old-path delete event arrived first.
      final counts = catalog().sourceImportCounts();
      for (final source in catalog().sources()) {
        final id = source['id'] as String;
        final state = Map<String, Object?>.from(source['state'] as Map);
        if (state['complete'] != true ||
            state['phase'] == 'complete' ||
            counts.any(
              (c) =>
                  c['source_id'] == id &&
                  c['epoch'] == state['epoch'] &&
                  (c['status'] == 'pending' || c['status'] == 'unsupported'),
            ))
          continue;
        while (catalog().markMissingImportPage(id, state['epoch'] as String) >
            0) {
          await Future<void>.delayed(Duration.zero);
          token.check();
        }
        catalog().putSource(
          id: id,
          path: source['path'] as String,
          state: {...state, 'phase': 'complete'},
        );
      }
      if (catalog().pendingImportCount == 0) {
        await _pairLivePhotos();
        if (WindowsMediaMetadata.available)
          catalog().putRecord('preferences', 'media-metadata-version', {
            'version': 1,
          });
      }
    } catch (e) {
      if (!_disposed)
        issue = e is CatalogFailure
            ? '加密保存失败，已提交记录保留；请检查程序数据目录。'
            : '本次导入未完成，已有记录保留。';
    } finally {
      scanning = false;
      if (didWork) _notify();
    }
  }

  Future<void> _pairLivePhotos() async {
    final crypto = await VaultCrypto.load();
    token.check();
    var after = '';
    while (true) {
      final candidates = catalog().livePhotoCandidates(after);
      if (candidates.isEmpty) break;
      after = candidates.last['pairing'] as String;
      for (final candidate in candidates) {
        token.check();
        final pairing = candidate['pairing'] as String;
        final parts = catalog().livePhotoComponents(pairing);
        if (parts.length != 2 ||
            parts.where((r) => r['kind'] == 'photo').length != 1 ||
            parts.where((r) => r['kind'] == 'video').length != 1)
          continue;
        final image = parts.firstWhere((r) => r['kind'] == 'photo');
        final video = parts.firstWhere((r) => r['kind'] == 'video');
        final binding = catalog().record('tracking', 'live:$pairing');
        if (binding != null &&
            (binding['image'] != image['id'] ||
                binding['video'] != video['id']))
          continue;
        final id = binding?['id'] as String? ?? _id(crypto);
        final hash = crypto.contentHasher();
        hash.add(
          Uint8List.fromList(
            utf8.encode('EPA/live/v1:${image['version']}:${video['version']}'),
          ),
        );
        final digest = (await hash.close())
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        token.check();
        final old = catalog().mediaById(id);
        final version = 'live-v1:$digest';
        catalog().transaction(() {
          catalog().saveLivePhoto({
            ...?old,
            'id': id,
            'kind': 'livePhoto',
            'format': 'Live Photo',
            'fileName': image['fileName'],
            'path': image['path'],
            'observedAt': old?['observedAt'] ?? image['observedAt'],
            'version': version,
            'size': (image['size'] as int) + (video['size'] as int),
            'local': true,
            'sourceMissing': false,
            'deletedFromLibrary': false,
            'sourceMetadata': image['sourceMetadata'],
            'pairing': {
              'appleContentIdentifier': pairing,
              'imageMediaId': image['id'],
              'videoMediaId': video['id'],
              'imageFileName': image['fileName'],
              'videoFileName': video['fileName'],
            },
            'resources': [
              {
                'sourceMediaId': image['id'],
                'role': 'image',
                'version': image['version'],
              },
              {
                'sourceMediaId': video['id'],
                'role': 'pairedVideo',
                'version': video['version'],
              },
            ],
          }, parts);
          catalog().putRecord('tracking', 'live:$pairing', {
            'id': id,
            'image': image['id'],
            'video': video['id'],
          });
        });
      }
    }
    // Existing pairs remain one library item when a component disappears.
    // Availability requires both exact resources; never advertise a partial pair
    // as a complete local copy or silently bind it to another independent file.
    after = '';
    while (true) {
      final bindings = catalog().recordPage('tracking', 'live:', after: after);
      if (bindings.isEmpty) break;
      after = bindings.last['recordId'] as String;
      for (final row in bindings) {
        token.check();
        final binding = row['body'] as Map;
        final composite = catalog().mediaById(binding['id'] as String);
        if (composite == null || composite['resources'] is! List) continue;
        final resources = (composite['resources'] as List)
            .whereType<Map>()
            .toList();
        final available =
            resources.length == 2 &&
            resources.every((part) {
              final original = catalog().mediaById(
                part['sourceMediaId'] as String,
              );
              return original?['local'] == true &&
                  original?['version'] == part['version'];
            });
        if (composite['local'] != available)
          catalog().putMedia({
            ...composite,
            'local': available,
            'sourceMissing': !available,
          });
      }
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Bounded in-memory preview. Large or unsupported files remain imported;
  /// no unprotected thumbnail cache is created as a substitute.
  Future<Uint8List?> preview(String id) async {
    final original = catalog().mediaById(id);
    if (original?['kind'] == 'livePhoto' && original?['resources'] is List) {
      final resources = original!['resources'] as List;
      final image = resources
          .whereType<Map>()
          .where((r) => r['role'] == 'image')
          .firstOrNull;
      if (image == null || image['sourceMediaId'] is! String) return null;
      final component = catalog().mediaById(image['sourceMediaId'] as String);
      if (component?['version'] != image['version']) return null;
      return preview(image['sourceMediaId'] as String);
    }
    final view = acquireView?.call();
    final reading = SourceCancellation(
      checkAccess: () {
        token.check();
        view?.call();
      },
    );
    _previewTokens.add(reading);
    try {
      return await _read(() async {
        reading.check();
        token.check();
        final record = catalog().mediaById(id);
        if (record == null ||
            record['kind'] != 'photo' ||
            record['local'] != true ||
            (record['size'] as int) > 16 * 1024 * 1024)
          return null;
        final path = record['path'] as String;
        final root = catalog().mediaRoot(id, path);
        if (root == null) return null;
        return _reader.withSnapshot(path, root, reading, (s) {
          reading.check();
          if (s.version != record['version']) {
            for (final source in catalog().sources()) {
              if (source['path'] == root)
                _forceSources.add(source['id'] as String);
            }
            requestScan();
            return null;
          }
          final bytes = s.previewBytes;
          if (bytes != null) _previewBuffers.add(bytes);
          return bytes;
        }, captureLimit: 16 * 1024 * 1024);
      });
    } finally {
      reading.cancel();
      _previewTokens.remove(reading);
    }
  }

  void revokePreviews() {
    for (final token in _previewTokens) {
      token.cancel();
    }
    for (final bytes in _previewBuffers) {
      bytes.fillRange(0, bytes.length, 0);
    }
    _previewBuffers.clear();
  }

  /// Uses the same stable, version-checked file handle and single-reader budget
  /// as importing. The callback must finish only after its decoder is closed.
  /// No plaintext copy is made; a path-only decoder may reopen the guarded file.
  Future<void> withLocalPlayback(
    String id,
    String version,
    SourceCancellation viewing,
    Future<void> Function(SourceSnapshot snapshot) consume,
  ) async {
    final view = acquireView?.call();
    final reading = SourceCancellation(
      checkAccess: () {
        token.check();
        view?.call();
        viewing.check();
      },
    );
    final removeCancel = viewing.onCancel(reading.cancel);
    final removeRevoke = reading.onCancel(viewing.cancel);
    _previewTokens.add(reading);
    try {
      await _read(() async {
        reading.check();
        var record = catalog().mediaById(id);
        if (record == null ||
            record['local'] != true ||
            record['version'] != version ||
            !{'photo', 'video', 'livePhoto'}.contains(record['kind'])) {
          throw const SourceFailure(SourceFailureCode.unavailable);
        }
        final original = record;
        var expectedVersion = version;
        var expectedKind = record['kind'];
        var sourceId = id;
        if (record['kind'] == 'livePhoto') {
          final video = (record['resources'] as List)
              .whereType<Map>()
              .firstWhere((r) => r['role'] == 'pairedVideo');
          sourceId = video['sourceMediaId'] as String;
          expectedVersion = video['version'] as String;
          expectedKind = 'video';
          record = catalog().mediaById(sourceId);
          if (record == null || record['version'] != expectedVersion)
            throw const SourceFailure(SourceFailureCode.changed);
        }
        final path = record['path'] as String;
        final root = catalog().mediaRoot(sourceId, path);
        if (root == null)
          throw const SourceFailure(SourceFailureCode.unsafePath);
        Future<void> openResource() async {
          await _reader.withSnapshot(path, root, reading, (snapshot) async {
            reading.check();
            if (snapshot.version != expectedVersion ||
                snapshot.kind != expectedKind) {
              for (final source in catalog().sources()) {
                if (source['path'] == root)
                  _forceSources.add(source['id'] as String);
              }
              requestScan();
              throw const SourceFailure(SourceFailureCode.changed);
            }
            await consume(snapshot);
          });
        }

        if (original['kind'] == 'livePhoto') {
          final image = (original['resources'] as List)
              .whereType<Map>()
              .firstWhere((r) => r['role'] == 'image');
          final imageId = image['sourceMediaId'] as String;
          final still = catalog().mediaById(imageId);
          if (still == null ||
              still['local'] != true ||
              still['version'] != image['version']) {
            throw const SourceFailure(SourceFailureCode.changed);
          }
          final stillRoot = catalog().mediaRoot(
            imageId,
            still['path'] as String,
          );
          if (stillRoot == null)
            throw const SourceFailure(SourceFailureCode.unavailable);
          await _reader.withSnapshot(
            still['path'] as String,
            stillRoot,
            reading,
            (snapshot) async {
              if (snapshot.version != image['version'] ||
                  snapshot.kind != 'photo')
                throw const SourceFailure(SourceFailureCode.changed);
              await openResource();
            },
          );
        } else {
          await openResource();
        }
      });
    } finally {
      removeCancel();
      removeRevoke();
      reading.cancel();
      _previewTokens.remove(reading);
    }
  }

  /// Decoded properties describe this exact version, not a filename inference.
  Future<void> recycleOriginal(
    String id,
    String version,
    String operationId,
    SourceCancellation cancellation,
  ) async {
    final composite = catalog().mediaById(id);
    if (composite?['kind'] == 'livePhoto') {
      if (composite!['version'] != version)
        throw const SourceFailure(SourceFailureCode.changed);
      for (final part in (composite['resources'] as List).whereType<Map>()) {
        await recycleOriginal(
          part['sourceMediaId'] as String,
          part['version'] as String,
          operationId,
          cancellation,
        );
      }
      cancellation.check();
      final current = catalog().mediaById(id)!;
      catalog().putMedia({...current, 'local': false, 'sourceMissing': true});
      _notify();
      return;
    }
    final access = acquireView?.call();
    void current() {
      token.check();
      cancellation.check();
      access?.call();
    }

    await _read(() async {
      current();
      final db = catalog();
      final record = db.mediaById(id);
      if (record == null || record['version'] != version) {
        throw const SourceFailure(SourceFailureCode.changed);
      }
      final key = 'recycle:$operationId:$id:${record['path']}';
      var job = db.record('jobs', key);
      if (job?['phase'] == 'complete') return;
      if (job == null) {
        if (record['local'] != true || record['path'] is! String) {
          throw const SourceFailure(SourceFailureCode.unavailable);
        }
        final path = record['path'] as String;
        final root = db.mediaRoot(id, path);
        if (root == null)
          throw const SourceFailure(SourceFailureCode.unsafePath);
        if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(operationId)) {
          throw const SourceFailure(SourceFailureCode.unsafePath);
        }
        final crypto = await VaultCrypto.load();
        current();
        job = {
          'mediaId': id,
          'version': version,
          'path': path,
          'root': root,
          'destination': '$root\\.epa-recycle\\$operationId-$id-${_id(crypto)}',
          'phase': 'prepared',
        };
        db.putRecord('jobs', key, job);
      }
      final path = job['path'] as String;
      final root = job['root'] as String;
      final destination = job['destination'] as String;
      final recycling = SourceCancellation(checkAccess: current);
      final remove = cancellation.onCancel(recycling.cancel);
      _previewTokens.add(recycling);
      try {
        await WindowsSourceReader.withDirectory(root, recycling, (_) async {
          final folder = Directory('$root\\.epa-recycle');
          if (!await folder.exists()) await folder.create();
          await WindowsSourceReader.withDirectory(folder.path, recycling, (
            _,
          ) async {
            if (await File(destination).exists()) {
              if (await File(path).exists())
                throw const SourceFailure(SourceFailureCode.changed);
              await _reader.withSnapshot(destination, folder.path, recycling, (
                snapshot,
              ) {
                if (snapshot.version != version)
                  throw const SourceFailure(SourceFailureCode.changed);
              });
            } else {
              await _reader.withSnapshot(path, root, recycling, (snapshot) {
                if (snapshot.version != version)
                  throw const SourceFailure(SourceFailureCode.changed);
                current();
              }, moveTo: destination);
            }
            current();
            db.transaction(() {
              db.markOriginalRemoved(id, path);
              db.putRecord('jobs', key, {...job!, 'phase': 'complete'});
            });
          });
        });
      } finally {
        remove();
        recycling.cancel();
        _previewTokens.remove(recycling);
      }
    });
    if (catalog().mediaById(id)?['local'] == true) {
      await recycleOriginal(id, version, operationId, cancellation);
    }
    _notify();
    requestScan();
  }

  /// Decoded properties describe this exact version, not a filename inference.
  Future<void> readLocalOriginal(
    String id,
    String version,
    SourceCancellation view,
    Future<void> Function(Uint8List bytes) consume,
  ) async {
    final composite = catalog().mediaById(id);
    if (composite?['kind'] == 'livePhoto') {
      if (composite!['version'] != version)
        throw const SourceFailure(SourceFailureCode.changed);
      for (final part in (composite['resources'] as List).whereType<Map>()) {
        await readLocalOriginal(
          part['sourceMediaId'] as String,
          part['version'] as String,
          view,
          consume,
        );
      }
      return;
    }
    final access = acquireView?.call();
    final reading = SourceCancellation(
      checkAccess: () {
        token.check();
        view.check();
        access?.call();
        if (catalog().mediaById(id)?['version'] != version) {
          throw const SourceFailure(SourceFailureCode.changed);
        }
      },
    );
    _previewTokens.add(reading);
    final remove = view.onCancel(reading.cancel);
    try {
      await _read(() async {
        reading.check();
        final media = catalog().mediaById(id);
        if (media?['local'] != true || media?['path'] is! String)
          throw const SourceFailure(SourceFailureCode.unavailable);
        final root = catalog().mediaRoot(id, media!['path'] as String);
        if (root == null)
          throw const SourceFailure(SourceFailureCode.unsafePath);
        await _reader.withSnapshot(media['path'] as String, root, reading, (
          snapshot,
        ) {
          reading.check();
          if (snapshot.version != version)
            throw const SourceFailure(SourceFailureCode.changed);
        }, onBlock: consume);
      });
    } finally {
      remove();
      reading.cancel();
      _previewTokens.remove(reading);
    }
  }

  Future<T> withVerifiedOriginals<T>(
    String id,
    String version,
    SourceCancellation view,
    Future<T> Function() action,
  ) async {
    final access = acquireView?.call();
    final reading = SourceCancellation(
      checkAccess: () {
        token.check();
        view.check();
        access?.call();
        if (catalog().mediaById(id)?['version'] != version)
          throw const SourceFailure(SourceFailureCode.changed);
      },
    );
    _previewTokens.add(reading);
    final remove = view.onCancel(reading.cancel);
    try {
      return await _read(() async {
        reading.check();
        final media = catalog().mediaById(id);
        if (media == null || media['local'] != true)
          throw const SourceFailure(SourceFailureCode.unavailable);
        final parts = media['kind'] == 'livePhoto'
            ? List<Map>.from(media['resources'] as List)
            : <Map>[
                {'sourceMediaId': id, 'version': version},
              ];
        Future<T> open(int index) async {
          reading.check();
          if (index == parts.length) return action();
          final part = parts[index];
          final sourceId = part['sourceMediaId'] as String;
          final original = catalog().mediaById(sourceId);
          if (original == null ||
              original['local'] != true ||
              original['version'] != part['version']) {
            throw const SourceFailure(SourceFailureCode.changed);
          }
          final path = original['path'] as String;
          final root = catalog().mediaRoot(sourceId, path);
          if (root == null)
            throw const SourceFailure(SourceFailureCode.unsafePath);
          return _reader.withSnapshot(path, root, reading, (snapshot) {
            reading.check();
            if (snapshot.version != part['version'])
              throw const SourceFailure(SourceFailureCode.changed);
            return open(index + 1);
          });
        }

        return open(0);
      });
    } finally {
      remove();
      reading.cancel();
      _previewTokens.remove(reading);
    }
  }

  List<Map<String, Object?>> recoveryFiles({String after = ''}) =>
      catalog().recordPage(
        'jobs',
        'recycle:',
        after: after,
        limit: 50,
        phases: {'prepared', 'complete', 'restoring'},
      );

  Future<void> restoreOriginal(
    String recordKey,
    SourceCancellation viewing,
  ) async {
    final access = acquireView?.call();
    final reading = SourceCancellation(
      checkAccess: () {
        token.check();
        viewing.check();
        access?.call();
      },
    );
    final remove = viewing.onCancel(reading.cancel);
    _previewTokens.add(reading);
    try {
      await _read(() async {
        reading.check();
        if (!recordKey.startsWith('recycle:'))
          throw const SourceFailure(SourceFailureCode.unsafePath);
        final job = catalog().record('jobs', recordKey);
        if (job == null ||
            !{'prepared', 'complete', 'restoring'}.contains(job['phase']))
          throw const SourceFailure(SourceFailureCode.unavailable);
        final destination = job['destination'] as String,
            path = job['path'] as String;
        final id = job['mediaId'] as String;
        final op = recordKey.split(':')[1];
        if (await File(destination).exists()) {
          await _reader.withSnapshot(
            destination,
            Directory(destination).parent.path,
            reading,
            (snapshot) {
              if (snapshot.version != job['version'])
                throw const SourceFailure(SourceFailureCode.changed);
              catalog().putRecord('jobs', recordKey, {
                ...job,
                'phase': 'restoring',
              });
            },
            moveTo: path,
          );
        } else if (job['phase'] == 'restoring' || job['phase'] == 'prepared') {
          // A previous process may have completed the rename before committing
          // the encrypted index. Verify the actual restored bytes before repair.
          await _reader.withSnapshot(path, job['root'] as String, reading, (
            snapshot,
          ) {
            if (snapshot.version != job['version'])
              throw const SourceFailure(SourceFailureCode.changed);
          });
        } else {
          throw const SourceFailure(SourceFailureCode.unavailable);
        }
        reading.check();
        catalog().transaction(() {
          catalog().markOriginalRestored(id, path);
          catalog().putRecord('jobs', recordKey, {...job, 'phase': 'restored'});
          catalog().putRecord('jobs', 'remote-delete:$op:$id', {
            'phase': 'complete',
            'restored': true,
          });
          final parentId = catalog().mediaById(id)?['pairedComponentOf'];
          if (parentId is String) {
            final parent = catalog().mediaById(parentId);
            if (parent != null)
              catalog().putMedia({
                ...parent,
                'pendingRemoteDeletion': null,
                'autoUploadSuppressed': true,
              });
            catalog().putRecord('jobs', 'remote-delete:$op:$parentId', {
              'phase': 'complete',
              'restored': true,
            });
          }
          var after = '';
          while (true) {
            final rows = catalog().recordPage(
              'jobs',
              'delete-intent:',
              after: after,
            );
            if (rows.isEmpty) break;
            after = rows.last['recordId'] as String;
            for (final row in rows) {
              final body = Map<String, Object?>.from(row['body'] as Map);
              if (body['operationId'] != op) continue;
              catalog().putRecord('jobs', row['recordId'] as String, {
                ...body,
                'phase': 'cancelled',
              });
              final parentId = body['mediaId'] as String;
              final parent = catalog().mediaById(parentId);
              if (parent != null)
                catalog().putMedia({
                  ...parent,
                  'pendingRemoteDeletion': null,
                  'autoUploadSuppressed': true,
                });
              catalog().putRecord('jobs', 'remote-delete:$op:$parentId', {
                'phase': 'complete',
                'restored': true,
              });
            }
          }
        });
      });
      await _pairLivePhotos();
      _notify();
      requestScan();
    } finally {
      remove();
      reading.cancel();
      _previewTokens.remove(reading);
    }
  }

  /// Decoded properties describe this exact version, not a filename inference.
  /// Persist only through SQLCipher and never extend the view's access lifetime.
  void saveViewMetadata(
    String id,
    String version, {
    required int width,
    required int height,
    int? durationMs,
    Uint8List? thumbnail,
  }) {
    final view = acquireView?.call();
    token.check();
    view?.call();
    if (width <= 0 ||
        height <= 0 ||
        width > 100000 ||
        height > 100000 ||
        (durationMs != null && durationMs <= 0))
      return;
    final db = catalog();
    db.transaction(() {
      view?.call();
      final record = db.mediaById(id);
      if (record == null || record['version'] != version) return;
      db.putMedia({
        ...record,
        'viewMetadata': {
          if (record['viewMetadata'] is Map &&
              (record['viewMetadata'] as Map)['version'] == version)
            ...Map<String, Object?>.from(record['viewMetadata'] as Map),
          'version': version,
          'width': width,
          'height': height,
          if (durationMs != null) 'durationMs': durationMs,
          if (thumbnail != null && thumbnail.length <= 256 * 1024)
            'thumbnail': base64Encode(thumbnail),
        },
      });
    });
    _notify();
  }

  Uint8List? readVideoCover(String id) {
    final view = acquireView?.call();
    view?.call();
    token.check();
    final record = catalog().mediaById(id);
    final metadata = record?['viewMetadata'];
    if (metadata is! Map || metadata['version'] != record?['version'])
      return null;
    final encoded = metadata['thumbnail'];
    if (encoded is! String || encoded.length > 350000) return null;
    try {
      final bytes = base64Decode(encoded);
      if (bytes.length > 256 * 1024) {
        bytes.fillRange(0, bytes.length, 0);
        return null;
      }
      _previewBuffers.add(bytes);
      return bytes;
    } on FormatException {
      return null;
    }
  }

  void releasePreview(Uint8List? bytes) {
    if (bytes == null) return;
    _previewBuffers.remove(bytes);
    bytes.fillRange(0, bytes.length, 0);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> get settled async {
    await _running;
    await _ioTail;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    token.cancel();
    revokePreviews();
    _tick?.cancel();
    _debounce?.cancel();
    _maxDebounce?.cancel();
    _periodic?.cancel();
    for (final w in _watchers.values) {
      unawaited(w.cancel());
    }
    _watchers.clear();
    _forceSources.clear();
    super.dispose();
  }
}

String describeSourceFailure(SourceFailure error) => switch (error.code) {
  SourceFailureCode.busy => '文件正在被使用，稍后重试',
  SourceFailureCode.changed => '文件仍在变化，稍后重试',
  SourceFailureCode.unsupported => '无法识别媒体内容，未报告导入成功',
  SourceFailureCode.unsafePath => '来源包含链接、脱机内容或不支持的路径，未读取',
  SourceFailureCode.cancelled => '访问已锁定，导入暂停',
  SourceFailureCode.unavailable => '原文件暂不可读取，稍后重试',
};
