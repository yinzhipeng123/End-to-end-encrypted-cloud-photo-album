import 'package:flutter/material.dart';
import 'package:encrypted_photo_app/ui/theme.dart';

enum BatchAction {
  upload,
  favorite,
  unfavorite,
  addAlbum,
  removeAlbum,
  export,
  delete,
}

class SelectionToolbar extends StatelessWidget {
  const SelectionToolbar({
    super.key,
    required this.selectedCount,
    required this.resultCount,
    required this.onSelectAll,
    required this.onClear,
    required this.onExit,
    required this.onAction,
  });
  final int selectedCount;
  final int resultCount;
  final VoidCallback onSelectAll;
  final VoidCallback onClear;
  final VoidCallback onExit;
  final ValueChanged<BatchAction> onAction;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: AppColors.sage,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text('已选择 $selectedCount 项'),
        ),
        TextButton(
          onPressed: resultCount == 0 ? null : onSelectAll,
          child: const Text('全选'),
        ),
        TextButton(
          onPressed: selectedCount == 0 ? null : onClear,
          child: const Text('取消全选'),
        ),
        FilledButton.icon(
          onPressed: selectedCount == 0
              ? null
              : () => onAction(BatchAction.upload),
          icon: const Icon(Icons.cloud_upload_outlined, size: 17),
          label: const Text('批量上传'),
        ),
        PopupMenuButton<BatchAction>(
          tooltip: '批量操作',
          enabled: selectedCount > 0,
          onSelected: onAction,
          itemBuilder: (_) => const [
            PopupMenuItem(value: BatchAction.favorite, child: Text('收藏所选')),
            PopupMenuItem(value: BatchAction.unfavorite, child: Text('取消收藏所选')),
            PopupMenuItem(value: BatchAction.addAlbum, child: Text('加入相册')),
            PopupMenuItem(value: BatchAction.removeAlbum, child: Text('移出相册')),
            PopupMenuItem(value: BatchAction.export, child: Text('批量导出')),
            PopupMenuItem(
              value: BatchAction.delete,
              child: Text('批量删除', style: TextStyle(color: AppColors.red)),
            ),
          ],
          child: const Padding(
            padding: EdgeInsets.all(12),
            child: Text('更多操作'),
          ),
        ),
        TextButton(onPressed: onExit, child: const Text('退出选择')),
      ],
    ),
  );
}
