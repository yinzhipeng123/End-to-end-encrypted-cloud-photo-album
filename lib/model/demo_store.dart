import 'package:flutter/foundation.dart';

enum RepositoryProvider {
  github('GitHub'),
  gitee('Gitee');

  const RepositoryProvider(this.label);
  final String label;
}

enum SyncStage {
  queued('等待同步'),
  encrypting('模拟加密'),
  splitting('模拟分块'),
  uploading('模拟上传'),
  complete('已同步'),
  localOnly('仅保留本地');

  const SyncStage(this.label);
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

class DemoPhoto {
  DemoPhoto({
    required this.id,
    required this.title,
    required this.asset,
    required this.takenAt,
    required this.megabytes,
    this.favorite = false,
    this.local = true,
    this.remote = true,
    this.otherDevice = true,
    this.stage = SyncStage.complete,
    this.encrypted = true,
    this.uploadProgress = 1,
    Set<String>? albums,
  }) : albums = albums ?? <String>{};

  final String id;
  final String title;
  final String asset;
  final DateTime takenAt;
  final double megabytes;
  bool favorite;
  bool local;
  bool remote;
  bool otherDevice;
  bool encrypted;
  SyncStage stage;
  double uploadProgress;
  final Set<String> albums;

  bool get visible => local || remote;
  bool get pending => local && !remote && stage != SyncStage.localOnly;
  String get fileName => 'IMG_${id.padLeft(4, '0')}.jpg';
  // Illustrative only: neither a ciphertext format nor a production block size.
  int get demoChunks => (megabytes / 48).ceil();
}

/// Fictional in-memory session. This is NOT an encryption or authentication
/// implementation. It never reads originals, stores credentials, or uses APIs.
class DemoStore extends ChangeNotifier {
  DemoStore({DateTime Function()? clock}) : _clock = clock ?? DateTime.now {
    reset(notify: false);
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
  final List<String> albums = [];
  final List<String> events = [];
  int _nextId = 100;
  int accessEpoch = 0;

  DateTime get now => _clock().add(_offset);
  bool get verificationDue =>
      now.difference(lastVerified) >= const Duration(days: 3);
  bool get photoPasswordRequired => !vaultUnlocked || verificationDue;
  bool get canView => configured && !pinLocked && !photoPasswordRequired;
  List<DemoPhoto> get photos =>
      canView ? _photos.where((p) => p.visible).toList() : [];
  List<DemoPhoto> get pending => _photos.where((p) => p.pending).toList();
  int get syncedCount => _photos.where((p) => p.visible && p.remote).length;
  int get totalCount => _photos.where((p) => p.visible).length;
  int get favoriteCount => photos.where((p) => p.favorite).length;
  double get totalMegabytes =>
      _photos.where((p) => p.visible).fold(0, (n, p) => n + p.megabytes);
  Duration get verificationRemaining {
    final remaining = const Duration(days: 3) - now.difference(lastVerified);
    return remaining.isNegative ? Duration.zero : remaining;
  }

  String? get syncBlockReason {
    if (!configured) return '等待完成首次设置';
    if (photoPasswordRequired) return '等待照片解密密码验证';
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
    albums
      ..clear()
      ..addAll(['山野之间', '慢慢生活', '沿途所见']);
    events
      ..clear()
      ..add('演示照片库已准备好 · 不连接真实仓库');
    const titles = [
      '湖边的清晨',
      '山间来信',
      '海风经过',
      '走进森林',
      '远方的路',
      '向海而行',
      '林间光影',
      '日常片刻',
      '夏日散步',
      '山谷回声',
      '周末午后',
      '城市漫游',
      '旅行碎片',
      '留白时刻',
      '绿意生长',
      '路上的风景',
    ];
    _photos.clear();
    for (var i = 0; i < titles.length; i++) {
      final complete = i < 12;
      _photos.add(
        DemoPhoto(
          id: '${i + 1}',
          title: titles[i],
          asset:
              'assets/photos/photo_${(i + 1).toString().padLeft(2, '0')}.jpg',
          takenAt: DateTime(2026, 11, i < 8 ? 5 : 2, 10 + i % 8, 12),
          megabytes: i == 14 ? 112.8 : 3.2 + i * 0.47,
          favorite: [0, 3, 8, 11].contains(i),
          local: i != 2,
          remote: complete,
          otherDevice: complete,
          encrypted: complete,
          stage: complete ? SyncStage.complete : SyncStage.queued,
          uploadProgress: complete ? 1 : 0,
          albums: {albums[i % 3]},
        ),
      );
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
      for (final photo in _photos.where((p) => p.visible)) {
        // A repository selection must not falsely claim the previous backup exists there.
        photo.remote = false;
        if (photo.local) {
          photo.stage = SyncStage.queued;
          photo.encrypted = false;
          photo.uploadProgress = 0;
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
          photo.stage = SyncStage.complete;
          _event('${photo.title} · 模拟同步完成');
        }
      case SyncStage.complete:
      case SyncStage.localOnly:
        break;
    }
    notifyListeners();
  }

  void toggleFavorite(DemoPhoto photo) {
    if (!canView) return;
    photo.favorite = !photo.favorite;
    notifyListeners();
  }

  bool createAlbum(String name) {
    if (!canView || name.trim().isEmpty || albums.contains(name.trim()))
      return false;
    albums.add(name.trim());
    notifyListeners();
    return true;
  }

  void setAlbum(DemoPhoto photo, String album, bool included) {
    if (!canView || !albums.contains(album)) return;
    included ? photo.albums.add(album) : photo.albums.remove(album);
    notifyListeners();
  }

  int importSamples(int count) {
    if (!canView) return 0;
    for (var i = 0; i < count; i++) {
      final id = _nextId++;
      _photos.insert(
        0,
        DemoPhoto(
          id: '$id',
          title: '新的回忆 ${id - 99}',
          asset:
              'assets/photos/photo_${(id % 16 + 1).toString().padLeft(2, '0')}.jpg',
          takenAt: now,
          megabytes: 4.6 + i,
          remote: false,
          otherDevice: false,
          encrypted: false,
          stage: SyncStage.queued,
          uploadProgress: 0,
        ),
      );
    }
    _event('已导入 $count 张内置样片 · 自动加入模拟同步队列');
    notifyListeners();
    return count;
  }

  bool exportDemo(DemoPhoto photo) {
    if (!canView || !photo.visible) return false;
    _event('${photo.title} · 模拟导出完成（未写入文件）');
    notifyListeners();
    return true;
  }

  String? deletePhoto(DemoPhoto photo, DeleteScope scope) {
    if (!canView) return '请先解锁照片库';
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
    if (!photo.visible) photo.albums.clear();
    _event(
      '${photo.title} · ${switch (scope) {
        DeleteScope.local => '本机原图已模拟删除，仓库保留',
        DeleteScope.repository => '仓库副本已模拟删除，本地保留',
        DeleteScope.everywhere => '本机、另一演示设备和仓库已模拟删除',
      }}',
    );
    notifyListeners();
    return null;
  }
}
