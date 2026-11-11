import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../model/demo_store.dart';

import 'package:encrypted_photo_shared/model/library_query.dart';
import 'package:encrypted_photo_shared/model/selection_state.dart';

import 'batch_dialogs.dart';
import 'components.dart';
import 'dialogs.dart';
import 'media_thumbnail.dart';
import 'media_viewer.dart';
import 'selection_toolbar.dart';

import 'package:encrypted_photo_app/ui/theme.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.store,
    required this.query,
    required this.favoritesOnly,
    this.album,
    required this.onOpenSync,
  });
  final DemoStore store;
  final String query;
  final bool favoritesOnly;
  final String? album;
  final VoidCallback onOpenSync;
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  LibraryFilter _filter = LibraryFilter.all;
  bool _compact = false;
  final _selection = SelectionState();

  LibraryQuery get _query => LibraryQuery(
    albumId: widget.album,
    favoritesOnly: widget.favoritesOnly,
    search: widget.query,
    filter: _filter,
  );

  List<MediaItem> _selected() {
    final result = widget.store.query(_query);
    _selection.reconcile(_query, result);
    return result.where((p) => _selection.ids.contains(p.id)).toList();
  }

  Future<void> _action(BatchAction action) async {
    final items = _selected();
    if (items.isEmpty) return;
    switch (action) {
      case BatchAction.upload:
        showUploadResults(context, widget.store, items);
      case BatchAction.favorite:
        widget.store.setFavorite(items, true);
      case BatchAction.unfavorite:
        widget.store.setFavorite(items, false);
      case BatchAction.addAlbum:
      case BatchAction.removeAlbum:
        await showBatchAlbumDialog(
          context,
          widget.store,
          _selected,
          included: action == BatchAction.addAlbum,
        );
      case BatchAction.export:
      case BatchAction.delete:
        await showBatchResourceDialog(
          context,
          widget.store,
          _selected,
          deleting: action == BatchAction.delete,
        );
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final photos = store.query(_query);
    _selection.reconcile(_query, photos);
    final groups = <String, List<MediaItem>>{};
    for (final photo in photos) {
      groups.putIfAbsent(photoDate(photo.takenAt), () => []).add(photo);
    }
    final album = store.albumById(widget.album);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              label: const Text('内置样片'),
              selected: !store.previewMode,
              onSelected: (_) => store.showLocalPreview(false),
            ),
            ChoiceChip(
              label: const Text('本机来源'),
              selected: store.previewMode,
              onSelected: (_) => store.showLocalPreview(true),
            ),
            if (store.previewMode)
              TextButton(
                onPressed: store.localPreview.scanning
                    ? null
                    : () => store.localPreview.rescan(),
                child: Text(store.localPreview.scanning ? '正在扫描…' : '重新扫描'),
              ),
          ],
        ),
        if (store.previewMode) ...[
          const SizedBox(height: 8),
          Text(
            store.localPreview.issue ?? '原文件保留在来源目录。当前仅本次会话可见，尚未备份；加密索引待实现。',
            style: const TextStyle(color: AppColors.muted, fontSize: 12),
          ),
        ],
        const SizedBox(height: 12),
        if (album != null) ...[
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('在所有照片中隐藏', style: TextStyle(fontSize: 13)),
            subtitle: const Text(
              '同时从“我的收藏”隐藏，仍可在所属相册查看。',
              style: TextStyle(fontSize: 11),
            ),
            value: album.hiddenFromLibrary,
            onChanged: (value) => store.setAlbumHidden(album.id, value),
          ),
          const SizedBox(height: 12),
        ],
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: const Color(0xFFEBF0E7),
            borderRadius: BorderRadius.circular(15),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.shield_outlined,
                size: 28,
                color: AppColors.green,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '回忆有归处，隐私有边界',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      store.syncBlockReason ??
                          '${store.syncedCount} 项已模拟同步 · ${store.pending.length} 项等待处理',
                      style: const TextStyle(
                        color: AppColors.muted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: widget.onOpenSync,
                child: const Text('查看同步'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 6,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final filter in LibraryFilter.values)
              ChoiceChip(
                label: Text(['全部媒体', '已同步', '待同步', '仅本地', '仅仓库'][filter.index]),
                selected: _filter == filter,
                showCheckmark: false,
                onSelected: (_) => setState(() => _filter = filter),
              ),
            Text(
              '${photos.length} 项',
              style: const TextStyle(color: AppColors.muted, fontSize: 12),
            ),
            IconButton(
              tooltip: _compact ? '舒适网格' : '紧凑网格',
              onPressed: () => setState(() => _compact = !_compact),
              icon: const Icon(Icons.grid_view_outlined),
            ),
            if (!_selection.active)
              OutlinedButton.icon(
                onPressed: () => setState(() => _selection.active = true),
                icon: const Icon(Icons.checklist, size: 17),
                label: const Text('多选'),
              ),
          ],
        ),
        if (_selection.active) ...[
          const SizedBox(height: 12),
          SelectionToolbar(
            selectedCount: _selection.ids.length,
            resultCount: photos.length,
            onSelectAll: () => setState(() => _selection.selectAll(photos)),
            onClear: () => setState(() => _selection.clear(exit: false)),
            onExit: () => setState(() => _selection.clear()),
            onAction: _action,
          ),
        ],
        if (photos.isEmpty)
          const EmptyState(title: '这里还没有照片', message: '试试其他筛选条件，或导入媒体。'),
        for (final group in groups.entries) ...[
          const SizedBox(height: 24),
          Row(
            children: [
              Text(
                group.key,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${group.value.length} 项',
                style: const TextStyle(color: AppColors.muted, fontSize: 11),
              ),
              const SizedBox(width: 16),
              const Expanded(child: Divider()),
            ],
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) => GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: group.value.length,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: math.max(
                  1,
                  (constraints.maxWidth / (_compact ? 180 : 235)).floor(),
                ),
                mainAxisSpacing: 18,
                crossAxisSpacing: 18,
                childAspectRatio: 1.1,
              ),
              itemBuilder: (context, index) {
                final photo = group.value[index];
                return PhotoCard(
                  key: ValueKey(photo.id),
                  photo: photo,
                  store: store,
                  selecting: _selection.active,
                  selected: _selection.ids.contains(photo.id),
                  onTap: () {
                    if (_selection.active) {
                      setState(() => _selection.toggle(photo.id));
                    } else {
                      showMediaViewer(context, store, photo, _query);
                    }
                  },
                );
              },
            ),
          ),
        ],
      ],
    );
  }
}

class PhotoCard extends StatelessWidget {
  const PhotoCard({
    super.key,
    required this.photo,
    required this.store,
    this.selecting = false,
    this.selected = false,
    required this.onTap,
  });
  final MediaItem photo;
  final DemoStore store;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Container(
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(13),
      border: Border.all(
        color: selected ? AppColors.green : AppColors.line,
        width: selected ? 2 : 1,
      ),
    ),
    child: Column(
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              Semantics(
                label:
                    '${selecting ? '选择' : '查看'}${photo.kindLabel}，${photoDate(photo.takenAt)}',
                selected: selecting ? selected : null,
                button: true,
                child: InkWell(
                  onTap: onTap,
                  child: MediaThumbnail(item: photo, cacheWidth: 650),
                ),
              ),
              Positioned(
                top: 10,
                left: 10,
                child: IgnorePointer(
                  child: Pill(
                    !photo.isDemo
                        ? (photo.sourceMissing ? '本地原文件缺失' : '本机 · 未备份')
                        : photo.remote
                        ? '已同步（模拟）'
                        : photo.stage.label,
                    icon: photo.remote ? Icons.cloud_done_outlined : Icons.sync,
                  ),
                ),
              ),
              Positioned(
                top: 2,
                right: 2,
                child: selecting
                    ? Checkbox(
                        value: selected,
                        onChanged: (_) => onTap(),
                        fillColor: WidgetStateProperty.resolveWith(
                          (states) => states.contains(WidgetState.selected)
                              ? AppColors.green
                              : Colors.white,
                        ),
                      )
                    : IconButton(
                        tooltip: photo.favorite ? '取消收藏' : '收藏照片',
                        onPressed: () => store.toggleFavorite(photo),
                        icon: Icon(
                          photo.favorite
                              ? Icons.favorite
                              : Icons.favorite_border,
                          color: photo.favorite
                              ? const Color(0xFFFFD8BB)
                              : Colors.white,
                        ),
                        style: IconButton.styleFrom(
                          backgroundColor: const Color(0x441C3228),
                        ),
                      ),
              ),
              if (!photo.local && photo.remote)
                const Positioned(
                  left: 10,
                  bottom: 10,
                  child: IgnorePointer(child: Pill('仅仓库副本')),
                ),
              if (photo.kind != MediaKind.photo)
                Positioned(
                  right: 10,
                  bottom: 10,
                  child: IgnorePointer(
                    child: Pill(
                      '${photo.kindLabel}${photo.duration == null ? '' : ' · ${_duration(photo.duration!)}'}',
                      icon: photo.kind == MediaKind.video
                          ? Icons.play_circle_outline
                          : Icons.motion_photos_on_outlined,
                    ),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 3, 4, 3),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  dataSize(photo.megabytes),
                  style: const TextStyle(fontSize: 11, color: AppColors.muted),
                ),
              ),
              if (selecting)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Icon(Icons.checklist, size: 18),
                )
              else
                PopupMenuButton<String>(
                  tooltip: '照片操作',
                  iconSize: 18,
                  onSelected: (value) {
                    switch (value) {
                      case 'details':
                        showPhotoDetails(context, store, photo);
                      case 'upload':
                        showUploadResults(context, store, [photo]);
                      case 'album':
                        showAlbumDialog(context, store, photo);
                      case 'export':
                        showExportDialog(context, store, photo);
                      case 'delete':
                        showDeleteDialog(context, store, photo);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'details', child: Text('查看详情')),
                    PopupMenuItem(value: 'upload', child: Text('上传')),
                    PopupMenuItem(value: 'album', child: Text('整理到相册')),
                    PopupMenuItem(value: 'export', child: Text('导出演示')),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text(
                        '选择删除范围',
                        style: TextStyle(color: AppColors.red),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

String _duration(Duration duration) =>
    '${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';

class AlbumsScreen extends StatelessWidget {
  const AlbumsScreen({
    super.key,
    required this.store,
    required this.onOpenAlbum,
  });
  final DemoStore store;
  final ValueChanged<String> onOpenAlbum;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: store.albums.length,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: math.max(1, (constraints.maxWidth / 280).floor()),
        mainAxisSpacing: 22,
        crossAxisSpacing: 22,
        childAspectRatio: 1.12,
      ),
      itemBuilder: (context, index) {
        final album = store.albums[index];
        final photos = store.query(LibraryQuery(albumId: album.id));
        return Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.line),
          ),
          child: Column(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () => onOpenAlbum(album.id),
                  child: SizedBox.expand(
                    child: photos.isEmpty
                        ? const Icon(
                            Icons.photo_album_outlined,
                            size: 42,
                            color: AppColors.muted,
                          )
                        : MediaThumbnail(item: photos.first, cacheWidth: 650),
                  ),
                ),
              ),
              ListTile(
                onTap: () => onOpenAlbum(album.id),
                title: Text(album.name),
                subtitle: Text(
                  '${photos.length} 项${album.hiddenFromLibrary ? ' · 聚合视图已隐藏' : ''}',
                  style: const TextStyle(fontSize: 11),
                ),
                trailing: PopupMenuButton<String>(
                  tooltip: '相册设置',
                  onSelected: (value) {
                    switch (value) {
                      case 'hide':
                        store.setAlbumHidden(
                          album.id,
                          !album.hiddenFromLibrary,
                        );
                      case 'rename':
                        showRenameAlbumDialog(context, store, album.id);
                      case 'delete':
                        showDeleteAlbumDialog(context, store, album.id);
                    }
                  },
                  itemBuilder: (_) => [
                    CheckedPopupMenuItem(
                      value: 'hide',
                      checked: album.hiddenFromLibrary,
                      child: const Text('在所有照片中隐藏'),
                    ),
                    const PopupMenuItem(value: 'rename', child: Text('重命名相册')),
                    const PopupMenuItem(value: 'delete', child: Text('删除相册')),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}
