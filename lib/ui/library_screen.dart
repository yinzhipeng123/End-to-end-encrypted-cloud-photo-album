import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../model/demo_store.dart';
import 'components.dart';
import 'dialogs.dart';
import 'theme.dart';

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
  int _filter = 0;
  bool _compact = false;
  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final photos = store.photos.where((photo) {
      if (widget.favoritesOnly && !photo.favorite) return false;
      if (widget.album != null && !photo.albums.contains(widget.album))
        return false;
      if (!'${photo.title} ${photo.fileName}'.toLowerCase().contains(
        widget.query.toLowerCase(),
      ))
        return false;
      return switch (_filter) {
        1 => photo.remote,
        2 => photo.pending,
        3 => photo.local && !photo.remote,
        4 => !photo.local && photo.remote,
        _ => true,
      };
    }).toList()..sort((a, b) => b.takenAt.compareTo(a.takenAt));
    final groups = <String, List<DemoPhoto>>{};
    for (final photo in photos) {
      groups.putIfAbsent(photoDate(photo.takenAt), () => []).add(photo);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
          decoration: BoxDecoration(
            color: const Color(0xFFEBF0E7),
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: const Color(0xFFDCE5D5)),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: .7),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.shield_outlined,
                  size: 27,
                  color: AppColors.green,
                ),
              ),
              const SizedBox(width: 16),
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
                          '${store.syncedCount} 张已模拟同步 · ${store.pending.length} 张等待处理',
                      style: const TextStyle(
                        color: Color(0xFF6A826D),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: widget.onOpenSync,
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('查看同步', style: TextStyle(fontSize: 11)),
                    SizedBox(width: 4),
                    Icon(Icons.arrow_forward, size: 14),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 25),
        LayoutBuilder(
          builder: (context, constraints) => Wrap(
            alignment: WrapAlignment.spaceBetween,
            runSpacing: 12,
            spacing: 18,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 8,
                children: List.generate(
                  5,
                  (index) => ChoiceChip(
                    label: Text(['全部照片', '已同步', '待同步', '仅本地', '仅仓库'][index]),
                    labelStyle: TextStyle(
                      fontSize: 11,
                      color: _filter == index ? Colors.white : AppColors.muted,
                    ),
                    selectedColor: AppColors.pine,
                    backgroundColor: Colors.white,
                    side: BorderSide(
                      color: _filter == index ? AppColors.pine : AppColors.line,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(9),
                    ),
                    showCheckmark: false,
                    selected: _filter == index,
                    onSelected: (_) => setState(() => _filter = index),
                  ),
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${photos.length} 张照片',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.muted,
                    ),
                  ),
                  const SizedBox(width: 12),
                  IconButton(
                    tooltip: _compact ? '舒适网格' : '紧凑网格',
                    onPressed: () => setState(() => _compact = !_compact),
                    icon: Icon(
                      _compact ? Icons.grid_view_outlined : Icons.apps,
                      size: 18,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (photos.isEmpty)
          const EmptyState(title: '这里还没有照片', message: '试试其他筛选条件，或导入几张内置样片。'),
        for (final group in groups.entries) ...[
          const SizedBox(height: 26),
          Row(
            children: [
              Text(
                group.key,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '${group.value.length} 张',
                style: const TextStyle(fontSize: 10, color: AppColors.muted),
              ),
              const SizedBox(width: 18),
              const Expanded(child: Divider()),
            ],
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = math.max(
                1,
                (constraints.maxWidth / (_compact ? 180 : 235)).floor(),
              );
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: group.value.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: 18,
                  crossAxisSpacing: 18,
                  childAspectRatio: 1.04,
                ),
                itemBuilder: (context, index) =>
                    PhotoCard(photo: group.value[index], store: store),
              );
            },
          ),
        ],
      ],
    );
  }
}

class PhotoCard extends StatefulWidget {
  const PhotoCard({super.key, required this.photo, required this.store});
  final DemoPhoto photo;
  final DemoStore store;
  @override
  State<PhotoCard> createState() => _PhotoCardState();
}

class _PhotoCardState extends State<PhotoCard> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final photo = widget.photo;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(
            color: _hover ? const Color(0xFFA7BBA9) : AppColors.line,
          ),
          boxShadow: [
            if (_hover)
              const BoxShadow(
                color: Color(0x12214D40),
                blurRadius: 18,
                offset: Offset(0, 7),
              ),
          ],
        ),
        child: Column(
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Semantics(
                    label: '查看照片：${photo.title}',
                    button: true,
                    child: InkWell(
                      onTap: () =>
                          showPhotoDetails(context, widget.store, photo),
                      child: Image.asset(
                        photo.asset,
                        fit: BoxFit.cover,
                        cacheWidth: 650,
                      ),
                    ),
                  ),
                  Positioned(
                    top: 10,
                    left: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xD9FFFFFF),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            photo.remote
                                ? Icons.cloud_done_outlined
                                : Icons.sync,
                            size: 12,
                            color: photo.remote
                                ? AppColors.green
                                : AppColors.amber,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            photo.remote ? '已同步' : photo.stage.label,
                            style: TextStyle(
                              fontSize: 9,
                              color: photo.remote
                                  ? AppColors.green
                                  : AppColors.amber,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_hover || photo.favorite)
                    Positioned(
                      top: 4,
                      right: 5,
                      child: IconButton(
                        tooltip: photo.favorite ? '取消收藏' : '收藏照片',
                        onPressed: () => widget.store.toggleFavorite(photo),
                        icon: Icon(
                          photo.favorite
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          color: photo.favorite
                              ? const Color(0xFFFFD8BB)
                              : Colors.white,
                          size: 20,
                        ),
                        style: IconButton.styleFrom(
                          backgroundColor: const Color(0x441C3228),
                        ),
                      ),
                    ),
                  if (!photo.local)
                    const Positioned(
                      bottom: 10,
                      left: 10,
                      child: Pill(
                        '仅仓库副本',
                        icon: Icons.cloud_outlined,
                        color: Colors.white,
                        background: Color(0x990F3023),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(13, 10, 8, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          photo.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${photo.fileName}  ·  ${dataSize(photo.megabytes)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 9,
                            color: AppColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '照片操作',
                    padding: EdgeInsets.zero,
                    iconSize: 18,
                    onSelected: (value) {
                      switch (value) {
                        case 'details':
                          showPhotoDetails(context, widget.store, photo);
                        case 'album':
                          showAlbumDialog(context, widget.store, photo);
                        case 'export':
                          showExportDialog(context, widget.store, photo);
                        case 'delete':
                          showDeleteDialog(context, widget.store, photo);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'details', child: Text('查看详情')),
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
      ),
    );
  }
}

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
        final photos = store.photos
            .where((p) => p.albums.contains(album))
            .toList();
        return InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => onOpenAlbum(album),
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.line),
            ),
            child: Column(
              children: [
                Expanded(
                  child: photos.isEmpty
                      ? const Center(
                          child: Icon(
                            Icons.photo_album_outlined,
                            color: AppColors.muted,
                            size: 42,
                          ),
                        )
                      : SizedBox.expand(
                          child: Image.asset(
                            photos.first.asset,
                            fit: BoxFit.cover,
                          ),
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.all(18),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          album,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      Text(
                        '${photos.length} 张',
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.muted,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Icon(
                        Icons.arrow_forward,
                        size: 16,
                        color: AppColors.muted,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
