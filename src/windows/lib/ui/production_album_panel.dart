import 'package:flutter/material.dart';

import 'package:encrypted_photo_shared/model/library_query.dart';
import 'package:encrypted_photo_app/services/library/library_organization_service.dart';

void organizationError(BuildContext context) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(const SnackBar(content: Text('整理未能保存，请检查程序数据目录。已有记录保留，请重试。')));
}

Future<String?> albumNameDialog(BuildContext context, {String? current}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _AlbumNameDialog(current: current),
    );

class _AlbumNameDialog extends StatefulWidget {
  const _AlbumNameDialog({this.current});
  final String? current;
  @override
  State<_AlbumNameDialog> createState() => _AlbumNameDialogState();
}

class _AlbumNameDialogState extends State<_AlbumNameDialog> {
  late final _name = TextEditingController(text: widget.current);
  @override
  void dispose() {
    _name.clear();
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    if (_name.text.trim().isNotEmpty) Navigator.pop(context, _name.text.trim());
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.current == null ? '创建相册' : '相册改名'),
    content: SizedBox(
      width: 360,
      child: TextField(
        controller: _name,
        autofocus: true,
        enableIMEPersonalizedLearning: false,
        decoration: const InputDecoration(labelText: '相册名称'),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _submit(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _name.text.trim().isEmpty ? null : _submit,
        child: const Text('保存'),
      ),
    ],
  );
}

class ProductionAlbumPanel extends StatelessWidget {
  const ProductionAlbumPanel({
    super.key,
    required this.service,
    required this.onOpen,
  });
  final LibraryOrganizationService service;
  final ValueChanged<String> onOpen;

  Future<void> _create(BuildContext context) async {
    final name = await albumNameDialog(context);
    if (!context.mounted || name == null) return;
    try {
      await service.createAlbum(name);
    } catch (_) {
      if (context.mounted) organizationError(context);
    }
  }

  Future<void> _rename(BuildContext context, Map<String, Object?> album) async {
    final name = await albumNameDialog(
      context,
      current: album['name'] as String,
    );
    if (!context.mounted || name == null) return;
    try {
      service.renameAlbum(album['id'] as String, name);
    } catch (_) {
      organizationError(context);
    }
  }

  Future<void> _delete(BuildContext context, Map<String, Object?> album) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('删除相册？'),
        content: Text(
          '删除“${album['name']}”这个分组。照片、视频及原文件会保留；若没有其他隐藏相册，它们将重新出现在所有照片中。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('删除相册'),
          ),
        ],
      ),
    );
    if (!context.mounted || confirmed != true) return;
    try {
      service.deleteAlbum(album['id'] as String);
    } catch (_) {
      organizationError(context);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: service,
    builder: (context, _) {
      final albums = service.albums;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FilledButton.icon(
            onPressed: () => _create(context),
            icon: const Icon(Icons.add),
            label: const Text('创建相册'),
          ),
          const SizedBox(height: 16),
          if (albums.isEmpty)
            const Padding(
              padding: EdgeInsets.all(36),
              child: Text('还没有相册。创建后，可以从照片库选择媒体加入。'),
            ),
          for (final album in albums)
            Card(
              key: ValueKey('album-${album['id']}'),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.photo_album_outlined),
                      title: Text(album['name'] as String),
                      subtitle: Text(
                        '${service.countFor(LibraryQuery(albumId: album['id'] as String))} 项媒体',
                      ),
                      onTap: () => onOpen(album['id'] as String),
                      trailing: const Icon(Icons.chevron_right),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('在所有照片中隐藏'),
                      subtitle: const Text('同时从我的收藏中隐藏，所属相册内仍可查看。'),
                      value: album['hidden'] == 1,
                      onChanged: (value) {
                        try {
                          service.setHidden(album['id'] as String, value);
                        } catch (_) {
                          organizationError(context);
                        }
                      },
                    ),
                    Wrap(
                      spacing: 12,
                      children: [
                        TextButton(
                          onPressed: () => _rename(context, album),
                          child: const Text('改名'),
                        ),
                        TextButton(
                          onPressed: () => _delete(context, album),
                          child: const Text('删除相册'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
    },
  );
}
