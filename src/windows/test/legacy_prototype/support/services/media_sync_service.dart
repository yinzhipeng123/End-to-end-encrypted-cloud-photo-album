import 'package:encrypted_photo_shared/model/media_item.dart';

enum UploadDisposition { queued, existing, synced, unavailable, blocked }

class UploadResult {
  const UploadResult(this.mediaId, this.disposition, this.message);
  final String mediaId;
  final UploadDisposition disposition;
  final String message;
}

/// 请求契约，不执行加密或网络操作。键包含目的地与资源版本。
class UploadPlanner {
  final Set<(String, String, String)> _requests = {};

  UploadResult request(MediaItem item, String target, {String? blocked}) {
    if (blocked != null)
      return UploadResult(item.id, UploadDisposition.blocked, blocked);
    if (!item.hasCompleteLocalResources) {
      return UploadResult(
        item.id,
        UploadDisposition.unavailable,
        '所需本地原始资源缺失或不可读取',
      );
    }
    if (item.remote &&
        item.stage == SyncStage.complete &&
        item.syncedTarget == target &&
        item.syncedVersion == item.version) {
      return UploadResult(item.id, UploadDisposition.synced, '当前仓库已同步，已跳过');
    }
    final key = (target, item.id, item.version);
    if (!_requests.add(key)) {
      return UploadResult(item.id, UploadDisposition.existing, '已在队列中，保留当前进度');
    }
    return UploadResult(item.id, UploadDisposition.queued, '已加入队列，尚未完成备份');
  }

  void forget(MediaItem item, String target) =>
      _requests.remove((target, item.id, item.version));
  void reset() => _requests.clear();
}
