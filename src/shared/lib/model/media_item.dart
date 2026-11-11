enum MediaKind { photo, video, livePhoto }

enum ResourceRole { image, video, pairedVideo }

enum ResourceAvailability { available, missing, inaccessible }

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

/// 原文件引用。文件名用于详情和搜索，不能用来推断实况配对。
class MediaResource {
  const MediaResource({
    required this.role,
    required this.location,
    required this.fileName,
    this.availability = ResourceAvailability.available,
    this.codec,
  });

  final ResourceRole role;
  final String location;
  final String fileName;
  final ResourceAvailability availability;
  final String? codec;
}

/// 照片、视频及实况照片共用一个管理项目；不包含凭据或解密材料。
class MediaItem {
  MediaItem({
    required this.id,
    required this.resources,
    required this.takenAt,
    required this.megabytes,
    this.kind = MediaKind.photo,
    this.pairingIdentifier,
    this.duration,
    this.previewLocation,
    this.isDemo = false,
    this.version = '1',
    this.favorite = false,
    this.local = true,
    this.remote = false,
    this.otherDevice = false,
    this.stage = SyncStage.queued,
    this.encrypted = false,
    this.uploadProgress = 0,
    this.syncedTarget,
    this.syncedVersion,
    this.sourceMissing = false,
  });

  final String id;
  final List<MediaResource> resources;
  final MediaKind kind;
  final String? pairingIdentifier;
  final DateTime takenAt;
  final double megabytes;
  final Duration? duration;
  final String? previewLocation;
  final bool isDemo;
  final String version;
  bool favorite;
  bool local;
  bool remote;
  bool otherDevice;
  bool encrypted;
  SyncStage stage;
  double uploadProgress;
  String? syncedTarget;
  String? syncedVersion;
  bool sourceMissing;

  String get kindLabel => switch (kind) {
    MediaKind.photo => '照片',
    MediaKind.video => '视频',
    MediaKind.livePhoto => '实况照片',
  };
  String get fileName => resources.isEmpty ? '' : resources.first.fileName;
  String get asset =>
      previewLocation ??
      resources
          .where((r) => r.role == ResourceRole.image)
          .firstOrNull
          ?.location ??
      '';
  bool get visible => local || remote || sourceMissing;
  bool get pending => local && !remote && stage != SyncStage.localOnly;
  bool get hasCompleteLocalResources {
    if (!local || resources.isEmpty) return false;
    if (resources.any(
      (r) => r.availability != ResourceAvailability.available,
    )) {
      return false;
    }
    final roles = resources.map((r) => r.role).toSet();
    return switch (kind) {
      MediaKind.photo => roles.contains(ResourceRole.image),
      MediaKind.video => roles.contains(ResourceRole.video),
      MediaKind.livePhoto =>
        roles.contains(ResourceRole.image) &&
            roles.contains(ResourceRole.pairedVideo) &&
            (pairingIdentifier?.isNotEmpty ?? false),
    };
  }

  // 仅用于演示，不是生产密文格式。
  int get demoChunks => (megabytes / 48).ceil();
}
