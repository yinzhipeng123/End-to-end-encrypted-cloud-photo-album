import 'dart:io';

import 'package:encrypted_photo_shared/model/media_item.dart';

class FolderScan {
  const FolderScan(this.files, this.complete, this.issue);
  final Map<String, MediaItem> files;
  final bool complete;
  final String? issue;
}

/// 只读扫描。稳定性检查降低复制中的误导入；不构成上传资源完整性验证。
class WindowsFolderImporter {
  static const photos = {
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
  };
  static const videos = {'mp4', 'mov', 'm4v', 'avi', 'mkv', 'webm', '3gp'};

  Future<FolderScan> scan(
    String path, {
    Duration settle = const Duration(milliseconds: 700),
  }) async {
    final files = <String, MediaItem>{};
    final candidates = <String, (File, FileStat, MediaKind)>{};
    var complete = true;
    String? issue;
    try {
      final root = Directory(path);
      if (!await root.exists()) return const FolderScan({}, false, '来源目录暂不可访问');
      await for (final entry in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entry is! File) continue;
        final ext = entry.path.split('.').last.toLowerCase();
        if (!photos.contains(ext) && !videos.contains(ext)) continue;
        try {
          final stat = await entry.stat();
          if (stat.type != FileSystemEntityType.file || stat.size == 0) {
            complete = false;
            issue = '部分文件尚未写入完成';
            continue;
          }
          final resolved = await entry.resolveSymbolicLinks();
          final key = Platform.isWindows ? resolved.toLowerCase() : resolved;
          candidates[key] = (
            File(resolved),
            stat,
            videos.contains(ext) ? MediaKind.video : MediaKind.photo,
          );
        } on FileSystemException {
          complete = false;
          issue = '部分文件不可读取，本次核对不判定文件删除';
        }
      }
      if (candidates.isNotEmpty) await Future<void>.delayed(settle);
      for (final candidate in candidates.entries) {
        final (file, before, kind) = candidate.value;
        try {
          final after = await file.stat();
          if (after.type != FileSystemEntityType.file ||
              before.size != after.size ||
              before.modified != after.modified) {
            complete = false;
            issue = '文件仍在变化，稍后重新核对';
            continue;
          }
          // 检查当前读取权限，不把整个大视频加载到内存。
          final handle = await file.open();
          try {
            await handle.read(16);
          } finally {
            await handle.close();
          }
          files[candidate.key] = MediaItem(
            id: 'local:${candidate.key}',
            kind: kind,
            takenAt: after.modified,
            megabytes: after.size / (1024 * 1024),
            version: '${after.size}:${after.modified.microsecondsSinceEpoch}',
            resources: [
              MediaResource(
                role: kind == MediaKind.video
                    ? ResourceRole.video
                    : ResourceRole.image,
                location: file.path,
                fileName: file.uri.pathSegments.last,
              ),
            ],
          );
        } on FileSystemException {
          complete = false;
          issue = '部分文件不可读取，本次核对不判定文件删除';
        }
      }
    } on FileSystemException {
      complete = false;
      issue = '目录扫描未完成，原有记录保持不变';
    }
    return FolderScan(files, complete, issue);
  }
}
