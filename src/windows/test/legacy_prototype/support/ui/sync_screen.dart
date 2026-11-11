import 'package:flutter/material.dart';

import '../model/demo_store.dart';
import 'components.dart';
import 'dialogs.dart';

import 'package:encrypted_photo_app/ui/theme.dart';

class SyncScreen extends StatelessWidget {
  const SyncScreen({super.key, required this.store});
  final DemoStore store;
  @override
  Widget build(BuildContext context) {
    if (store.previewMode) {
      return const Surface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeading('真实加密同步尚未接入'),
            SizedBox(height: 16),
            Text('本机照片与视频目前只纳入会话预览，未上传到任何仓库。单项与批量上传会返回未接入状态。'),
            SizedBox(height: 12),
            Text('本机索引须加密后才能跨启动保存。原文件保持在所选目录。'),
          ],
        ),
      );
    }
    final blocked = store.syncBlockReason;
    final pending = store.pending;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Surface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.sage,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      blocked == null
                          ? Icons.cloud_sync_outlined
                          : Icons.cloud_off_outlined,
                      size: 32,
                      color: AppColors.green,
                    ),
                  ),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          blocked ??
                              (pending.isEmpty ? '所有回忆，已模拟同步' : '正在照顾你的回忆'),
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 7),
                        Text(
                          '${store.syncedCount} 张已同步  /  ${store.totalCount} 张照片',
                          style: const TextStyle(
                            color: AppColors.muted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: store.togglePause,
                    icon: Icon(
                      store.manualPause ? Icons.play_arrow : Icons.pause,
                      size: 17,
                    ),
                    label: Text(store.manualPause ? '继续' : '暂停'),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: store.totalCount == 0
                      ? 0
                      : store.syncedCount / store.totalCount,
                  minHeight: 7,
                  color: AppColors.green,
                  backgroundColor: AppColors.sage,
                ),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 20,
                runSpacing: 10,
                children: [
                  const Pill('先加密，后上传', icon: Icons.lock_outline),
                  const Pill('分块目标 ≤ 50 MB', icon: Icons.widgets_outlined),
                  Pill(
                    '演示库 ${dataSize(store.totalMegabytes)}',
                    icon: Icons.photo_library_outlined,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                '以上为模拟状态，照片没有进行真实加密或上传。应用不设自有总容量配额，实际存储仍受平台限制。',
                style: TextStyle(color: AppColors.muted, fontSize: 11),
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        Surface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionHeading(
                '我的存储位置',
                trailing: TextButton(
                  onPressed: () => showRepositoryDialog(context, store),
                  child: const Text('切换仓库'),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Container(
                    width: 45,
                    height: 45,
                    decoration: BoxDecoration(
                      color: AppColors.canvas,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.code, color: AppColors.ink),
                  ),
                  const SizedBox(width: 15),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          store.repository,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          '${store.provider.label}  ·  私有仓库  ·  模拟连接',
                          style: const TextStyle(
                            color: AppColors.muted,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Pill('私有', icon: Icons.lock_outline),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 26),
        SectionHeading(
          '同步队列',
          subtitle: '自动处理新导入的演示照片',
          trailing: Text(
            '${pending.length} 项待处理',
            style: const TextStyle(color: AppColors.muted, fontSize: 12),
          ),
        ),
        const SizedBox(height: 16),
        if (pending.isEmpty)
          Surface(
            child: Row(
              children: [
                const Icon(Icons.task_alt, size: 26, color: AppColors.green),
                const SizedBox(width: 14),
                const Expanded(child: Text('队列已完成。导入样片，看看新的同步过程。')),
                TextButton(
                  onPressed: () => showImportDialog(context, store),
                  child: const Text('导入样片'),
                ),
              ],
            ),
          ),
        for (final photo in pending)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Surface(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(9),
                    child: Image.asset(
                      photo.asset,
                      width: 55,
                      height: 50,
                      fit: BoxFit.cover,
                      cacheWidth: 160,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${photo.kindLabel} · ${photoDate(photo.takenAt)}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          '${dataSize(photo.megabytes)} · ${photo.demoChunks} 个演示块',
                          style: const TextStyle(
                            color: AppColors.muted,
                            fontSize: 10,
                          ),
                        ),
                        if (photo.stage == SyncStage.uploading) ...[
                          const SizedBox(height: 8),
                          LinearProgressIndicator(
                            value: photo.uploadProgress,
                            color: AppColors.green,
                            backgroundColor: AppColors.sage,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Pill(
                    blocked != null ? '已暂停' : photo.stage.label,
                    icon: blocked != null ? Icons.pause : Icons.sync,
                    color: blocked != null ? AppColors.amber : AppColors.green,
                    background: blocked != null
                        ? const Color(0xFFF6EEDA)
                        : AppColors.sage,
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 24),
        Surface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeading('最近活动', subtitle: '本次演示会话的操作记录'),
              const SizedBox(height: 16),
              for (final event in store.events.take(7))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 5),
                        child: Icon(
                          Icons.circle,
                          size: 5,
                          color: AppColors.green,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          event,
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.muted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
