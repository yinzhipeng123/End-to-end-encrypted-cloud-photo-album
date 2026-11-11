import 'dart:math' as math;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';

import '../model/demo_store.dart';
import 'components.dart';

import 'package:encrypted_photo_app/ui/theme.dart';

import 'media_thumbnail.dart';

Future<void> showRepositoryDialog(BuildContext context, DemoStore store) async {
  var provider = store.provider;
  var repository = store.repository;
  var authorized = false;
  String? error;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: const Text('连接你的私有仓库'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Pill('模拟授权 · 不会打开真实登录页面', icon: Icons.science_outlined),
                const SizedBox(height: 22),
                const Text(
                  '选择存储平台',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                Row(
                  children: RepositoryProvider.values
                      .map(
                        (p) => Expanded(
                          child: Padding(
                            padding: EdgeInsets.only(
                              right: p == RepositoryProvider.github ? 10 : 0,
                            ),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(12),
                              onTap: () => update(() {
                                provider = p;
                                authorized = false;
                                error = null;
                              }),
                              child: Container(
                                padding: const EdgeInsets.all(22),
                                decoration: BoxDecoration(
                                  color: provider == p
                                      ? AppColors.sage
                                      : Colors.white,
                                  border: Border.all(
                                    color: provider == p
                                        ? AppColors.green
                                        : AppColors.line,
                                  ),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Column(
                                  children: [
                                    Icon(
                                      p == RepositoryProvider.github
                                          ? Icons.code
                                          : Icons.hub_outlined,
                                      size: 28,
                                      color: AppColors.pine,
                                    ),
                                    const SizedBox(height: 10),
                                    Text(
                                      p.label,
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.tonal(
                        onPressed: () => update(() {
                          authorized = true;
                          error = null;
                        }),
                        child: Text(
                          authorized
                              ? '${provider.label} 模拟授权成功'
                              : '模拟授权 ${provider.label}',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => update(() {
                        authorized = false;
                        error = '演示：授权失败，当前仓库配置未改变。';
                      }),
                      child: const Text('模拟失败'),
                    ),
                  ],
                ),
                if (authorized) ...[
                  const SizedBox(height: 18),
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: repository,
                    decoration: const InputDecoration(labelText: '可访问的私有仓库'),
                    items:
                        const [
                              'demo-user / private-memories',
                              'demo-user / travel-vault',
                            ]
                            .map(
                              (r) => DropdownMenuItem(value: r, child: Text(r)),
                            )
                            .toList(),
                    onChanged: (r) => update(() => repository = r!),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '切换演示仓库会重新排队本地样片，不会将旧仓库的完成状态当作新仓库备份。',
                    style: TextStyle(fontSize: 11, color: AppColors.muted),
                  ),
                ],
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      error!,
                      style: const TextStyle(color: AppColors.red),
                    ),
                  ),
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
            onPressed: authorized
                ? () {
                    store.connectRepository(provider, repository);
                    Navigator.pop(dialogContext);
                  }
                : null,
            child: const Text('使用这个仓库'),
          ),
        ],
      ),
    ),
  );
}

Future<void> showImportDialog(BuildContext context, DemoStore store) async {
  var count = 3;
  final selected = await showDialog<int>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: const Text('导入照片与视频'),
        content: SizedBox(
          width: 430,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (Platform.isWindows) ...[
                OutlinedButton.icon(
                  onPressed: () => Navigator.pop(dialogContext, 0),
                  icon: const Icon(Icons.folder_open),
                  label: const Text('选择电脑上的文件夹'),
                ),
                const SizedBox(height: 8),
                const Text(
                  '包含全部子文件夹，运行时核对新增。当前仅在内存中预览；加密索引待实现，关闭后需重新选择目录。',
                  style: TextStyle(fontSize: 12, color: AppColors.muted),
                ),
                const SizedBox(height: 16),
              ],
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(30),
                decoration: BoxDecoration(
                  color: AppColors.canvas,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.line),
                ),
                child: const Column(
                  children: [
                    Icon(
                      Icons.add_photo_alternate_outlined,
                      size: 42,
                      color: AppColors.green,
                    ),
                    SizedBox(height: 14),
                    Text(
                      '从内置样片导入',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    SizedBox(height: 6),
                    Text(
                      '样片与本机来源分开浏览',
                      style: TextStyle(fontSize: 12, color: AppColors.muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              const Text('选择样片数量'),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                children: [1, 3, 6]
                    .map(
                      (n) => ChoiceChip(
                        label: Text('$n 张照片'),
                        selected: count == n,
                        onSelected: (_) => update(() => count = n),
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 16),
              const Text(
                '样片将自动进入模拟加密与同步队列。本地原照片保留为普通图片。',
                style: TextStyle(color: AppColors.muted, fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, count),
            child: Text('导入 $count 张样片'),
          ),
        ],
      ),
    ),
  );
  if (selected == 0 && context.mounted && store.canView) {
    try {
      final folder = await getDirectoryPath(confirmButtonText: '导入此文件夹');
      if (folder != null && store.canView) await store.importFolder(folder);
    } catch (_) {
      if (context.mounted) toast(context, '无法读取所选目录，原文件没有改变');
    }
  } else if (selected != null && context.mounted && store.canView) {
    store.importSamples(selected);
    toast(context, '已导入 $selected 张内置样片，等待模拟同步');
  }
}

Future<void> showExportDialog(
  BuildContext context,
  DemoStore store,
  DemoPhoto photo,
) async {
  if (!store.exportDemo(photo)) {
    if (store.canView) toast(context, '真实导出尚未接入，原文件保持不变');
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('导出演示'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.task_alt, size: 40, color: AppColors.green),
          const SizedBox(height: 18),
          Text('1 项${photo.kindLabel} · ${photoDate(photo.takenAt)}'),
          const SizedBox(height: 8),
          const Text(
            '已演示导出流程，未向磁盘写入照片。',
            style: TextStyle(color: AppColors.muted),
          ),
          if (!photo.local)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('正式版应在客户端解密仓库副本后导出。', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('完成'),
        ),
      ],
    ),
  );
}

Future<void> showDeleteDialog(
  BuildContext context,
  DemoStore store,
  DemoPhoto photo,
) async {
  DeleteScope? selected;
  String? error;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: const Text('选择删除范围'),
        content: SizedBox(
          width: 490,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '1 项${photo.kindLabel} · ${photoDate(photo.takenAt)}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  '本机原图：${photo.local ? '存在' : '不存在'}    仓库副本：${photo.remote ? '存在' : '不存在'}',
                  style: const TextStyle(fontSize: 12, color: AppColors.muted),
                ),
                const SizedBox(height: 16),
                for (final scope in DeleteScope.values)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: InkWell(
                      onTap: () => update(() {
                        selected = scope;
                        error = null;
                      }),
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.all(15),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          color: selected == scope
                              ? AppColors.sage
                              : Colors.white,
                          border: Border.all(
                            color: selected == scope
                                ? AppColors.green
                                : AppColors.line,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              selected == scope
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_unchecked,
                              color: selected == scope
                                  ? AppColors.green
                                  : AppColors.muted,
                              size: 20,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    switch (scope) {
                                      DeleteScope.local => '删除本地，保留仓库副本',
                                      DeleteScope.everywhere => '同步删除',
                                      DeleteScope.repository => '删除仓库副本，保留本地',
                                    },
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 5),
                                  Text(
                                    switch (scope) {
                                      DeleteScope.local =>
                                        '作用于本机原照片，不是清理 App 缓存',
                                      DeleteScope.everywhere =>
                                        '本机、另一演示客户端与仓库一并删除',
                                      DeleteScope.repository =>
                                        '本机原照片继续保留，可正常使用',
                                    },
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: AppColors.muted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                const Text(
                  '本次只改变虚构数据。仓库删除不表示已清理 Git 历史。',
                  style: TextStyle(fontSize: 11, color: AppColors.muted),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Text(
                      error!,
                      style: const TextStyle(color: AppColors.red),
                    ),
                  ),
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
            style: FilledButton.styleFrom(backgroundColor: AppColors.red),
            onPressed: selected == null
                ? null
                : () {
                    final result = store.deletePhoto(photo, selected!);
                    if (result != null) {
                      update(() => error = result);
                    } else {
                      Navigator.pop(dialogContext);
                    }
                  },
            child: const Text('确认模拟删除'),
          ),
        ],
      ),
    ),
  );
}

Future<void> showAlbumDialog(
  BuildContext context,
  DemoStore store,
  DemoPhoto photo,
) async {
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AnimatedBuilder(
      animation: store,
      builder: (context, _) => AlertDialog(
        title: const Text('整理到相册'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final album in store.albums)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: album.members.contains(photo.id),
                  title: Text(album.name),
                  onChanged: (included) =>
                      store.setAlbum(photo, album.id, included!),
                ),
              const SizedBox(height: 8),
              const Text(
                '从相册移出不会删除照片，也不会改变同步副本。',
                style: TextStyle(color: AppColors.muted, fontSize: 11),
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('完成'),
          ),
        ],
      ),
    ),
  );
}

Future<void> showCreateAlbumDialog(
  BuildContext context,
  DemoStore store,
) async {
  final input = TextEditingController();
  String? error;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: const Text('给回忆起个名字'),
        content: SizedBox(
          width: 370,
          child: TextField(
            controller: input,
            autofocus: true,
            decoration: InputDecoration(
              labelText: '相册名称',
              hintText: '例如：去山里过周末',
              errorText: error,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (store.createAlbum(input.text)) {
                Navigator.pop(dialogContext);
              } else {
                update(() => error = '请输入一个尚未使用的相册名称');
              }
            },
            child: const Text('创建相册'),
          ),
        ],
      ),
    ),
  );
  // The dialog route disposes its text field after the reverse transition.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  input.dispose();
}

Future<void> showPhotoDetails(
  BuildContext context,
  DemoStore store,
  DemoPhoto photo,
) async {
  if (!store.canView || !store.containsItem(photo)) return;
  final hostContext = context;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AnimatedBuilder(
      animation: store,
      builder: (context, _) => Dialog(
        clipBehavior: Clip.antiAlias,
        insetPadding: const EdgeInsets.all(24),
        child: SizedBox(
          width: 1040,
          height: math.min(MediaQuery.sizeOf(context).height - 48, 660),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final image = Container(
                color: const Color(0xFF172620),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(18),
                      child: MediaThumbnail(item: photo, fit: BoxFit.contain),
                    ),
                    Positioned(
                      left: 18,
                      top: 18,
                      child: Pill(
                        photo.isDemo ? '内置演示样片' : '本机原文件 · 未备份',
                        color: Colors.white,
                        background: const Color(0x77314439),
                      ),
                    ),
                  ],
                ),
              );
              final details = Padding(
                padding: const EdgeInsets.all(24),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              '照片详情',
                              style: TextStyle(
                                color: AppColors.muted,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: '关闭详情',
                            onPressed: () => Navigator.pop(dialogContext),
                            icon: const Icon(Icons.close, size: 20),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      Text(
                        photo.kindLabel,
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        photo.resources.map((r) => r.fileName).join('\n'),
                        style: const TextStyle(color: AppColors.muted),
                      ),
                      const SizedBox(height: 24),
                      _detailRow(
                        Icons.calendar_today_outlined,
                        photo.isDemo ? '拍摄时间' : '文件修改时间',
                        photoDate(photo.takenAt),
                      ),
                      _detailRow(
                        Icons.aspect_ratio,
                        photo.isDemo ? '原图大小（演示）' : '原始资源大小',
                        dataSize(photo.megabytes),
                      ),
                      _detailRow(
                        Icons.desktop_windows_outlined,
                        '本机原始资源',
                        photo.local ? '原文件保留在本机' : '本机不存在',
                      ),
                      _detailRow(
                        Icons.cloud_outlined,
                        '仓库副本',
                        photo.isDemo
                            ? (photo.remote ? '已同步（模拟）' : photo.stage.label)
                            : '尚未备份，真实同步未接入',
                      ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: store
                            .albumsFor(photo)
                            .map(
                              (a) => Pill(a.name, icon: Icons.folder_outlined),
                            )
                            .toList(),
                      ),
                      const SizedBox(height: 24),
                      const Divider(),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => store.toggleFavorite(photo),
                              icon: Icon(
                                photo.favorite
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                                size: 17,
                              ),
                              label: Text(photo.favorite ? '已收藏' : '收藏'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () =>
                                  showAlbumDialog(context, store, photo),
                              icon: const Icon(
                                Icons.create_new_folder_outlined,
                                size: 17,
                              ),
                              label: const Text('相册'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: () =>
                              showExportDialog(context, store, photo),
                          icon: const Icon(Icons.download_outlined, size: 17),
                          label: const Text('导出演示'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Center(
                        child: TextButton.icon(
                          onPressed: () async {
                            Navigator.pop(dialogContext);
                            await showDeleteDialog(hostContext, store, photo);
                          },
                          icon: const Icon(Icons.delete_outline, size: 17),
                          label: const Text('删除照片'),
                          style: TextButton.styleFrom(
                            foregroundColor: AppColors.red,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
              if (constraints.maxWidth > 760)
                return Row(
                  children: [
                    Expanded(child: image),
                    SizedBox(width: 330, child: details),
                  ],
                );
              return Column(
                children: [
                  Expanded(flex: 4, child: image),
                  Expanded(flex: 5, child: details),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
}

Widget _detailRow(IconData icon, String label, String value) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 9),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 17, color: AppColors.muted),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(fontSize: 11, color: AppColors.muted),
            ),
            const SizedBox(height: 4),
            Text(value, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    ],
  ),
);

Future<void> showRenameAlbumDialog(
  BuildContext context,
  DemoStore store,
  String id,
) async {
  final album = store.albumById(id);
  if (album == null) return;
  final input = TextEditingController(text: album.name);
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('重命名相册'),
      content: TextField(
        controller: input,
        autofocus: true,
        decoration: const InputDecoration(labelText: '相册名称'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            if (store.renameAlbum(id, input.text)) Navigator.pop(dialogContext);
          },
          child: const Text('保存'),
        ),
      ],
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 300));
  input.dispose();
}

Future<void> showDeleteAlbumDialog(
  BuildContext context,
  DemoStore store,
  String id,
) async {
  final album = store.albumById(id);
  if (album == null) return;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('删除相册'),
      content: Text('删除“${album.name}”的 App 分组，保留全部媒体。若关联了系统相册，将停止本次跟踪。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('删除相册'),
        ),
      ],
    ),
  );
  if (confirmed == true && store.canView) store.deleteAlbum(id);
}
