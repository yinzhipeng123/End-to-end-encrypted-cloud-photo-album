import 'package:encrypted_photo_shared/model/album.dart';
import 'package:encrypted_photo_shared/model/library_query.dart';

import 'library_store.dart';

import 'package:encrypted_photo_shared/model/media_item.dart';

import '../services/media_sync_service.dart';

import 'package:encrypted_photo_shared/services/album_import_tracker.dart';

import 'local_preview_library.dart';

export 'package:encrypted_photo_shared/model/media_item.dart';

enum RepositoryProvider {
  github('GitHub'),
  gitee('Gitee');

  const RepositoryProvider(this.label);
  final String label;
}

enum SyncFault {
  none('正常'),
  offline('网络不可用'),
  permission('仓库权限失效'),
  capacity('仓库容量受限');

  const SyncFault(this.label);
  final String label;
}

enum DeleteScope { local, everywhere, repository }

typedef DemoPhoto = MediaItem;

/// Fictional in-memory session. This is NOT an encryption or authentication
/// implementation. It never reads originals, stores credentials, or uses APIs.
class DemoStore extends LibraryStore {
  DemoStore({DateTime Function()? clock}) : _clock = clock ?? DateTime.now {
    reset(notify: false);
    localPreview.addListener(notifyListeners);
  }

  static const defaultPassword = 'photo-demo-2026';
  static const defaultPin = '2468';
  final DateTime Function() _clock;
  Duration _offset = Duration.zero;
  late DateTime lastVerified;
  String demoPassword = defaultPassword;
  String demoPin = defaultPin;
  bool configured = true;
  bool pinLocked = false;
  bool vaultUnlocked = true;
  bool connected = true;
  bool manualPause = false;
  bool pauseOnPinLock = false;
  bool failNextDeletion = false;
  RepositoryProvider provider = RepositoryProvider.github;
  String repository = 'demo-user / private-memories';
  SyncFault fault = SyncFault.none;
  final List<DemoPhoto> _photos = [];
  final UploadPlanner uploadPlanner = UploadPlanner();
  late final LocalPreviewLibrary localPreview = LocalPreviewLibrary(
    mayScan: () => canView,
  );
  bool previewMode = false;
  @override
  List<Album> get albums => previewMode ? localPreview.albums : super.albums;
  @override
  AlbumImportTracker get albumTracker =>
      previewMode ? localPreview.albumTracker : super.albumTracker;
  final List<String> events = [];
  int _nextId = 100;
  int accessEpoch = 0;

  DateTime get now => _clock().add(_offset);
  bool get verificationDue =>
      now.difference(lastVerified) >= const Duration(days: 3);
  bool get photoPasswordRequired => !vaultUnlocked || verificationDue;
  @override
  bool get canView => configured && !pinLocked && !photoPasswordRequired;
  @override
  List<MediaItem> get mediaRecords =>
      previewMode ? localPreview.mediaRecords : List.unmodifiable(_photos);
  List<DemoPhoto> get pending =>
      previewMode ? [] : _photos.where((p) => p.pending).toList();
  int get syncedCount =>
      mediaRecords.where((p) => p.visible && p.remote).length;
  int get totalCount => mediaRecords.where((p) => p.visible).length;
  int get visibleCount => query().length;
  int get favoriteCount =>
      query(const LibraryQuery(favoritesOnly: true)).length;
  double get totalMegabytes =>
      mediaRecords.where((p) => p.visible).fold(0, (n, p) => n + p.megabytes);
  Duration get verificationRemaining {
    final remaining = const Duration(days: 3) - now.difference(lastVerified);
    return remaining.isNegative ? Duration.zero : remaining;
  }

  String? get syncBlockReason {
    if (!configured) return '等待完成首次设置';
    if (photoPasswordRequired) return '等待照片解密密码验证';
    if (previewMode) return '本机预览 · 真实加密同步尚未接入';
    if (!connected) return '尚未连接演示仓库';
    if (pinLocked && pauseOnPinLock) return '应用已锁定（演示策略）';
    if (fault != SyncFault.none) return fault.label;
    if (manualPause) return '已手动暂停';
    return null;
  }

  void _event(String message) {
    events.insert(0, message);
    if (events.length > 30) events.removeLast();
  }

  void reset({bool notify = true}) {
    previewMode = false;
    _offset = Duration.zero;
    lastVerified = now;
    configured = vaultUnlocked = connected = true;
    pinLocked = manualPause = pauseOnPinLock = failNextDeletion = false;
    demoPassword = defaultPassword;
    demoPin = defaultPin;
    provider = RepositoryProvider.github;
    repository = 'demo-user / private-memories';
    fault = SyncFault.none;
    _nextId = 100;
    accessEpoch++;
    uploadPlanner.reset();
    albumTracker.reset();
    albums
      ..clear()
      ..addAll([
        Album(id: 'demo:1', name: '山野之间'),
        Album(id: 'demo:2', name: '慢慢生活'),
        Album(id: 'demo:3', name: '沿途所见'),
      ]);
    events
      ..clear()
      ..add('演示照片库已准备好 · 不连接真实仓库');
    _photos.clear();
    for (var i = 0; i < 16; i++) {
      final complete = i < 12;
      _photos.add(
        DemoPhoto(
          id: '${i + 1}',
          isDemo: true,
          resources: [
            MediaResource(
              role: ResourceRole.image,
              location:
                  'test/fixtures/legacy_photos/photo_${(i + 1).toString().padLeft(2, '0')}.jpg',
              fileName: 'IMG_${(i + 1).toString().padLeft(4, '0')}.jpg',
            ),
          ],
          takenAt: DateTime(2026, 11, i < 8 ? 5 : 2, 10 + i % 8, 12),
          megabytes: i == 14 ? 112.8 : 3.2 + i * 0.47,
          favorite: [0, 3, 8, 11].contains(i),
          local: i != 2,
          remote: complete,
          otherDevice: complete,
          encrypted: complete,
          stage: complete ? SyncStage.complete : SyncStage.queued,
          uploadProgress: complete ? 1 : 0,
          syncedTarget: complete ? uploadTarget : null,
          syncedVersion: complete ? '1' : null,
        ),
      );
      albums[i % 3].members.add('${i + 1}');
    }
    for (final photo in pending) {
      uploadPlanner.request(photo, uploadTarget);
    }
    if (notify) notifyListeners();
  }

  void lock() {
    pinLocked = true;
    accessEpoch++;
    notifyListeners();
  }

  bool unlockPin(String input) {
    if (input != demoPin) return false;
    pinLocked = false;
    notifyListeners();
    return true;
  }

  bool verifyPhotoPassword(String input) {
    if (input != demoPassword) return false;
    vaultUnlocked = true;
    lastVerified = now;
    _event('照片密码验证通过 · 新的 3 天周期已开始');
    notifyListeners();
    return true;
  }

  void advanceTime(Duration duration) {
    final wasDue = photoPasswordRequired;
    _offset += duration;
    if (!wasDue && photoPasswordRequired) accessEpoch++;
    notifyListeners();
  }

  void expireVerification() =>
      advanceTime(verificationRemaining + const Duration(seconds: 1));

  void beginNewDevice() {
    vaultUnlocked = false;
    accessEpoch++;
    _event('另一台演示设备已授权 · 仍需照片密码解锁');
    notifyListeners();
  }

  void beginSetup() {
    reset(notify: false);
    configured = connected = vaultUnlocked = false;
    notifyListeners();
  }

  bool completeSetup({
    required String password,
    required String pin,
    required RepositoryProvider selectedProvider,
    required String selectedRepository,
  }) {
    if (password.trim().isEmpty ||
        !RegExp(r'^\d{4}$').hasMatch(pin) ||
        password == pin ||
        selectedRepository.isEmpty)
      return false;
    demoPassword = password;
    demoPin = pin;
    provider = selectedProvider;
    repository = selectedRepository;
    configured = connected = vaultUnlocked = true;
    pinLocked = false;
    lastVerified = now;
    _event('首次演示设置完成 · 请牢记照片解密密码');
    notifyListeners();
    return true;
  }

  bool setPin(String input) {
    if (!canView ||
        !RegExp(r'^\d{4}$').hasMatch(input) ||
        input == demoPassword)
      return false;
    demoPin = input;
    notifyListeners();
    return true;
  }

  void connectRepository(RepositoryProvider value, String name) {
    if (name.isEmpty) return;
    final changed = provider != value || repository != name;
    provider = value;
    repository = name;
    connected = true;
    if (changed) {
      uploadPlanner.reset();
      for (final photo in _photos.where((p) => p.visible)) {
        // A repository selection must not falsely claim the previous backup exists there.
        photo.remote = false;
        if (photo.local) {
          photo.stage = SyncStage.queued;
          photo.encrypted = false;
          photo.uploadProgress = 0;
          uploadPlanner.request(photo, uploadTarget);
        }
      }
    }
    _event('${value.label} 演示授权成功 · $name');
    notifyListeners();
  }

  void setFault(SyncFault value) {
    fault = value;
    notifyListeners();
  }

  void togglePause() {
    manualPause = !manualPause;
    notifyListeners();
  }

  void setPauseOnLock(bool value) {
    pauseOnPinLock = value;
    notifyListeners();
  }

  void setDeletionFailure(bool value) {
    failNextDeletion = value;
    notifyListeners();
  }

  void tick() {
    if (syncBlockReason != null) {
      notifyListeners();
      return;
    }
    if (pending.isEmpty) return;
    final photo = pending.first;
    switch (photo.stage) {
      case SyncStage.queued:
        photo.stage = SyncStage.encrypting;
      case SyncStage.encrypting:
        photo.encrypted = true;
        photo.stage = SyncStage.splitting;
      case SyncStage.splitting:
        if (!photo.encrypted)
          throw StateError('Plaintext must never reach upload.');
        photo.stage = SyncStage.uploading;
      case SyncStage.uploading:
        if (!photo.encrypted)
          throw StateError('Plaintext must never reach upload.');
        photo.uploadProgress = (photo.uploadProgress + 0.34).clamp(0, 1);
        if (photo.uploadProgress >= 1) {
          photo.remote = true;
          photo.syncedTarget = uploadTarget;
          photo.syncedVersion = photo.version;
          photo.stage = SyncStage.complete;
          uploadPlanner.forget(photo, uploadTarget);
          _event('1 项${photo.kindLabel} · 模拟同步完成');
        }
      case SyncStage.complete:
      case SyncStage.localOnly:
        break;
    }
    notifyListeners();
  }

  String get uploadTarget => '${provider.name}:$repository';

  List<UploadResult> requestUpload(Iterable<MediaItem> items) {
    final results = <UploadResult>[];
    for (final item in items.toList()) {
      final blocked = !canView
          ? '请先解锁照片库'
          : !containsItem(item)
          ? '项目已不在当前媒体库中'
          : !item.isDemo
          ? '真实加密与仓库服务尚未接入，未上传'
          : syncBlockReason;
      final result = uploadPlanner.request(
        item,
        uploadTarget,
        blocked: blocked,
      );
      results.add(result);
      if (result.disposition == UploadDisposition.queued) {
        item.stage = SyncStage.queued;
        item.encrypted = false;
        item.uploadProgress = 0;
      }
    }
    final queued = results
        .where((r) => r.disposition == UploadDisposition.queued)
        .length;
    if (queued > 0) _event('$queued 项媒体已加入模拟上传队列 · 尚未完成备份');
    notifyListeners();
    return results;
  }

  int importSamples(int count) {
    if (!canView) return 0;
    previewMode = false;
    for (var i = 0; i < count; i++) {
      final id = _nextId++;
      _photos.insert(
        0,
        DemoPhoto(
          id: '$id',
          isDemo: true,
          resources: [
            MediaResource(
              role: ResourceRole.image,
              location:
                  'test/fixtures/legacy_photos/photo_${(id % 16 + 1).toString().padLeft(2, '0')}.jpg',
              fileName: 'IMG_${id.toString().padLeft(4, '0')}.jpg',
            ),
          ],
          takenAt: now,
          megabytes: 4.6 + i,
          remote: false,
          otherDevice: false,
          encrypted: false,
          stage: SyncStage.queued,
          uploadProgress: 0,
        ),
      );
      uploadPlanner.request(_photos.first, uploadTarget);
    }
    _event('已导入 $count 张内置样片 · 自动加入模拟同步队列');
    notifyListeners();
    return count;
  }

  bool exportDemo(DemoPhoto photo) {
    if (!canView || !containsItem(photo) || !photo.isDemo) return false;
    _event('1 项${photo.kindLabel} · 模拟导出完成（未写入文件）');
    notifyListeners();
    return true;
  }

  String? deletePhoto(DemoPhoto photo, DeleteScope scope) {
    if (!canView) return '请先解锁照片库';
    if (!containsItem(photo)) return '项目已不在当前媒体库中';
    if (!photo.isDemo) return '真实资源删除尚未接入，未删除任何文件';
    if (scope != DeleteScope.local && (!connected || fault != SyncFault.none))
      return '仓库暂不可用，未改变任何副本';
    if (failNextDeletion) {
      failNextDeletion = false;
      notifyListeners();
      return '模拟删除失败：原照片与仓库副本均未改变，请重试';
    }
    switch (scope) {
      case DeleteScope.local:
        photo.local = false;
      case DeleteScope.repository:
        photo.remote = false;
      case DeleteScope.everywhere:
        photo.local = photo.remote = photo.otherDevice = false;
    }
    photo.stage = photo.remote ? SyncStage.complete : SyncStage.localOnly;
    uploadPlanner.forget(photo, uploadTarget);
    if (!photo.visible) {
      for (final album in albums) {
        album.members.remove(photo.id);
      }
    }
    _event(
      '1 项${photo.kindLabel} · ${switch (scope) {
        DeleteScope.local => '本机原图已模拟删除，仓库保留',
        DeleteScope.repository => '仓库副本已模拟删除，本地保留',
        DeleteScope.everywhere => '本机、另一演示设备和仓库已模拟删除',
      }}',
    );
    notifyListeners();
    return null;
  }

  void showLocalPreview(bool value) {
    if (!canView) return;
    previewMode = value;
    accessEpoch++;
    notifyListeners();
  }

  Future<void> importFolder(String path) async {
    if (!canView) return;
    await localPreview.addFolder(path);
    if (!canView) return;
    previewMode = true;
    accessEpoch++;
    notifyListeners();
  }

  @override
  void dispose() {
    localPreview.removeListener(notifyListeners);
    localPreview.dispose();
    super.dispose();
  }
}
