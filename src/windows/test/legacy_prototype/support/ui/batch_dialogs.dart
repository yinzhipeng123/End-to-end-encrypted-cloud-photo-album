import 'package:flutter/material.dart';

import '../model/demo_store.dart';
import '../services/media_sync_service.dart';
import 'components.dart';

void showUploadResults(
  BuildContext context,
  DemoStore store,
  Iterable<MediaItem> items,
) {
  final results = store.requestUpload(items);
  final counts = <String, int>{};
  for (final r in results) {
    final message = switch (r.disposition) {
      UploadDisposition.queued => '已加入模拟队列，尚未完成备份',
      UploadDisposition.synced => '当前演示仓库已同步，已跳过',
      _ => r.message,
    };
    counts.update(message, (n) => n + 1, ifAbsent: () => 1);
  }
  toast(context, counts.entries.map((e) => '${e.value} 项：${e.key}').join('；'));
}

Future<void> showBatchAlbumDialog(
  BuildContext context,
  DemoStore store,
  List<MediaItem> Function() currentSelection, {
  required bool included,
}) async {
  String? albumId;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: Text(included ? '加入相册' : '移出相册'),
        content: SizedBox(
          width: 380,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioGroup<String>(
                  groupValue: albumId,
                  onChanged: (value) => update(() => albumId = value),
                  child: Column(
                    children: [
                      for (final album in store.albums)
                        RadioListTile<String>(
                          value: album.id,
                          title: Text(album.name),
                        ),
                    ],
                  ),
                ),
                const Text('仅调整所选项目的相册归属，不删除原文件。'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: albumId == null
                ? null
                : () {
                    final items = currentSelection();
                    for (final item in items) {
                      store.setAlbum(item, albumId!, included);
                    }
                    Navigator.pop(dialogContext);
                  },
            child: const Text('确认'),
          ),
        ],
      ),
    ),
  );
}

Future<void> showBatchResourceDialog(
  BuildContext context,
  DemoStore store,
  List<MediaItem> Function() currentSelection, {
  required bool deleting,
}) async {
  DeleteScope? scope;
  final initialItems = currentSelection().toList();
  final completed = <String>{};
  final errors = <String, String>{};
  var attempted = false;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: Text(deleting ? '批量删除' : '批量导出'),
        content: SizedBox(
          width: 450,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('当前选择 ${currentSelection().length} 项媒体'),
                const SizedBox(height: 12),
                if (deleting)
                  RadioGroup<DeleteScope>(
                    groupValue: scope,
                    onChanged: (value) {
                      if (!attempted) update(() => scope = value);
                    },
                    child: Column(
                      children: [
                        for (final value in DeleteScope.values)
                          RadioListTile<DeleteScope>(
                            value: value,
                            enabled: !attempted,
                            title: Text(switch (value) {
                              DeleteScope.local => '删除本地，保留仓库副本',
                              DeleteScope.everywhere => '同步删除',
                              DeleteScope.repository => '删除仓库副本，保留本地',
                            }),
                          ),
                      ],
                    ),
                  ),
                Text(
                  deleting
                      ? '本次只模拟所选范围，不删除真实文件。仓库删除不表示清除 Git 历史。'
                      : '本次只演示导出，不向磁盘写入文件。',
                ),
                if (attempted) ...[
                  const SizedBox(height: 16),
                  Text('模拟完成 ${completed.length} 项；失败 ${errors.length} 项'),
                  for (var i = 0; i < initialItems.length; i++)
                    if (completed.contains(initialItems[i].id) ||
                        errors.containsKey(initialItems[i].id))
                      Text(
                        '第 ${i + 1} 项 · ${initialItems[i].kindLabel}：'
                        '${completed.contains(initialItems[i].id) ? '模拟完成' : errors[initialItems[i].id]}',
                      ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(attempted ? '关闭' : '取消'),
          ),
          FilledButton(
            onPressed:
                (deleting && scope == null) || (attempted && errors.isEmpty)
                ? null
                : () {
                    final items = currentSelection()
                        .where((p) => !completed.contains(p.id))
                        .toList();
                    update(() {
                      attempted = true;
                      for (final item in items) {
                        final error = deleting
                            ? store.deletePhoto(item, scope!)
                            : store.exportDemo(item)
                            ? null
                            : '项目不可访问或真实导出服务尚未接入';
                        if (error == null) {
                          completed.add(item.id);
                          errors.remove(item.id);
                        } else {
                          errors[item.id] = error;
                        }
                      }
                    });
                  },
            child: Text(
              attempted
                  ? '重试失败项'
                  : deleting
                  ? '确认模拟删除'
                  : '确认模拟导出',
            ),
          ),
        ],
      ),
    ),
  );
}
