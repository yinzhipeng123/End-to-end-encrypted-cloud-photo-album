import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'package:encrypted_photo_app/services/import/windows_import_service.dart';
import 'package:encrypted_photo_app/services/library/library_organization_service.dart';
import 'package:encrypted_photo_app/services/media_operations/windows_media_export.dart';
import 'package:encrypted_photo_app/services/media_operations/windows_media_deletion.dart';
import 'package:encrypted_photo_app/services/playback/windows_media_thumbnailer.dart';
import 'package:encrypted_photo_app/services/import/windows_source_reader.dart';
import 'package:encrypted_photo_shared/model/library_query.dart';
import 'package:encrypted_photo_app/sync/windows_sync_service.dart';
import 'package:encrypted_photo_app/ui/production_album_panel.dart';
import 'package:encrypted_photo_app/ui/production_media_viewer.dart';

class _RecoveryDialog extends StatefulWidget {
  const _RecoveryDialog({
    required this.service,
    required this.token,
    this.sync,
  });
  final WindowsImportService service;
  final SourceCancellation token;
  final WindowsSyncService? sync;
  @override
  State<_RecoveryDialog> createState() => _RecoveryDialogState();
}

class _RecoveryDialogState extends State<_RecoveryDialog> {
  final _pages = <String>[''];
  bool _busy = false;
  String? _message;

  Future<void> _restore(String key) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (widget.sync != null) {
        await widget.sync!.restoreLocalOriginal(key, widget.token);
      } else {
        await widget.service.restoreOriginal(key, widget.token);
      }
      if (mounted) setState(() => _message = '原文件已恢复到原位置；不会自动重建此前删除的仓库副本。');
    } catch (_) {
      if (mounted)
        setState(() => _message = '未完成恢复。请检查来源磁盘、原位置同名文件和文件权限；未覆盖任何已有文件，可重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = widget.service.recoveryFiles(after: _pages.last);
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: const Text('恢复本地原文件'),
        content: SizedBox(
          width: 640,
          height: 400,
          child: ListView(
            children: [
              const Text(
                '文件仍保存在原磁盘的 .epa-recycle 中。恢复保留原始内容，不覆盖同名文件。实况照片的两个资源分别恢复，齐全后重新组成一项。',
              ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(_message!),
                ),
              if (rows.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('当前页没有可恢复记录。'),
                ),
              for (var i = 0; i < rows.length; i++)
                Builder(
                  builder: (context) {
                    final row = rows[i];
                    final body = row['body'] as Map;
                    return ExpansionTile(
                      title: Text('回收文件 ${i + 1} · 查看详情'),
                      children: [
                        SelectableText(
                          '原位置：${body['path']}\n回收位置：${body['destination']}',
                        ),
                        TextButton.icon(
                          onPressed: _busy
                              ? null
                              : () => _restore(row['recordId'] as String),
                          icon: const Icon(Icons.restore),
                          label: const Text('恢复到原位置'),
                        ),
                      ],
                    );
                  },
                ),
              if (_busy) const LinearProgressIndicator(),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy || _pages.length == 1
                ? null
                : () => setState(() => _pages.removeLast()),
            child: const Text('上一页'),
          ),
          TextButton(
            onPressed: _busy || rows.length < 50
                ? null
                : () => setState(
                    () => _pages.add(rows.last['recordId'] as String),
                  ),
            child: const Text('下一页'),
          ),
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}

class _OperationHistoryDialog extends StatefulWidget {
  const _OperationHistoryDialog({required this.organization});
  final LibraryOrganizationService organization;
  @override
  State<_OperationHistoryDialog> createState() =>
      _OperationHistoryDialogState();
}

class _OperationHistoryDialogState extends State<_OperationHistoryDialog> {
  String _prefix = 'export:';
  final _pages = <String>[''];
  @override
  Widget build(BuildContext context) {
    final rows = widget.organization.catalog.recordPage(
      'jobs',
      _prefix,
      after: _pages.last,
      limit: 50,
    );
    return AlertDialog(
      title: const Text('导出与删除记录'),
      content: SizedBox(
        width: 640,
        height: 420,
        child: Column(
          children: [
            DropdownButton<String>(
              value: _prefix,
              isExpanded: true,
              items: [
                for (final item in {
                  'export:': '导出',
                  'delete-intent:': '本机发起的删除',
                  'remote-delete:': '仓库删除的本机处理',
                }.entries)
                  DropdownMenuItem(value: item.key, child: Text(item.value)),
              ],
              onChanged: (value) {
                if (value != null)
                  setState(() {
                    _prefix = value;
                    _pages
                      ..clear()
                      ..add('');
                  });
              },
            ),
            const Text(
              '这是已持久化的操作记录。处理中记录可能来自上次中断；失败可回到对应媒体重试。导出中断后的部分文件位置可在详情中核对。',
            ),
            Expanded(
              child: ListView(
                children: [
                  if (rows.isEmpty) const ListTile(title: Text('当前页没有操作记录')),
                  for (final row in rows)
                    Builder(
                      builder: (context) {
                        final body = row['body'] as Map;
                        final media = body['mediaId'] is String
                            ? widget.organization.catalog.mediaById(
                                body['mediaId'] as String,
                              )
                            : null;
                        final state = switch (body['phase']) {
                          'complete' => '本机处理已完成',
                          'cancelled' => '已取消',
                          'conflict' => '冲突，原文件保留',
                          'incomplete' => '未完成，需检查后重试',
                          _ => '处理已开始，尚无完成记录',
                        };
                        return ExpansionTile(
                          title: Text(state),
                          children: [
                            if (media?['fileName'] is String)
                              SelectableText('原文件名：${media!['fileName']}'),
                            if (body['scope'] != null)
                              Text(
                                '范围：${{'local': '仅本地', 'repository': '仅仓库', 'all': '本地与仓库'}[body['scope']] ?? body['scope']}',
                              ),
                            if (body['failure'] is String)
                              Text(body['failure'] as String),
                            if (body['destination'] is String)
                              SelectableText('导出位置：${body['destination']}'),
                            if (body['files'] is List)
                              for (final path in body['files'] as List)
                                SelectableText('已导出：$path'),
                            if (body['published'] is List)
                              for (final path in body['published'] as List)
                                SelectableText('部分已导出：$path'),
                            if (_prefix == 'remote-delete:' &&
                                body['restored'] == true)
                              const Text('用户已恢复原文件，该次删除不会再次执行。'),
                          ],
                        );
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _pages.length == 1
              ? null
              : () => setState(() => _pages.removeLast()),
          child: const Text('上一页'),
        ),
        TextButton(
          onPressed: rows.length < 50
              ? null
              : () =>
                    setState(() => _pages.add(rows.last['recordId'] as String)),
          child: const Text('下一页'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class ProductionLibraryPanel extends StatefulWidget {
  const ProductionLibraryPanel({
    super.key,
    required this.service,
    required this.organization,
    this.sync,
  });
  final WindowsImportService service;
  final LibraryOrganizationService organization;
  final WindowsSyncService? sync;
  @override
  State<ProductionLibraryPanel> createState() => _ProductionLibraryPanelState();
}

class _ProductionLibraryPanelState extends State<ProductionLibraryPanel> {
  int _page = 0;
  bool _choosing = false;
  bool _exporting = false;
  SourceCancellation? _export;
  String? _exportProgress;
  bool _deleting = false;
  bool _recovering = false;
  SourceCancellation? _deletion;
  String? _deletionProgress;
  final _search = TextEditingController();
  LibraryOrganizationService get o => widget.organization;

  Future<void> _upload(Iterable<String> ids) async {
    final query = o.query;
    final chosen = ids.toSet();
    await widget.sync?.requestUpload(
      chosen,
      scope: query,
      stillCurrent: () => mounted && o.query == query,
    );
    if (mounted && widget.sync?.issue != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(widget.sync!.issue!)));
    }
  }

  Future<void> _exportMedia(Iterable<String> ids) async {
    if (_exporting || _deleting || _recovering) return;
    final query = o.query;
    final chosen = o.catalog.queryIds(query, within: ids.toSet());
    if (chosen.isEmpty) return;
    setState(() => _exporting = true);
    final token = SourceCancellation(
      checkAccess: () {
        if (!mounted || o.query != query)
          throw const SourceFailure(SourceFailureCode.cancelled);
        o.catalog;
      },
    );
    _export = token;
    var done = 0, failed = 0;
    try {
      final destination = await getDirectoryPath(
        confirmButtonText: '导出原始文件到此文件夹',
      );
      if (destination == null) return;
      token.check();
      final service = WindowsMediaExport(widget.service, o, widget.sync);
      for (final id in chosen) {
        token.check();
        setState(
          () => _exportProgress =
              '导出中：已完成 $done 项，失败 $failed 项，共 ${chosen.length} 项',
        );
        try {
          await service.export(id, destination, token);
          done++;
        } catch (_) {
          token.check();
          failed++;
        }
      }
    } catch (_) {
      // The final message reports actual completed items, never the requested total.
    } finally {
      final cancelled = token.cancelled;
      token.cancel();
      _export = null;
      if (mounted)
        setState(() {
          _exporting = false;
          _exportProgress =
              '导出${cancelled ? '已取消' : '结束'}：实际完成 $done 项，失败 $failed 项。';
        });
    }
  }

  Future<void> _deleteMedia(Iterable<String> ids) async {
    if (_deleting || _exporting || _recovering) return;
    final query = o.query;
    final chosen = o.catalog.queryIds(query, within: ids.toSet());
    if (chosen.isEmpty) return;
    final scope = await showDialog<MediaDeletionScope>(
      context: context,
      builder: (dialog) => SimpleDialog(
        title: Text('删除 ${chosen.length} 项媒体'),
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '本地原文件将移入来源文件夹的 .epa-recycle，可恢复但暂不释放空间。仓库删除不清除 Git 历史。离线设备需重连后处理，改动过的文件会保留并报告冲突。',
            ),
          ),
          for (final item in {
            MediaDeletionScope.local: '删除本地，保留仓库副本（先完整校验仓库）',
            MediaDeletionScope.all: '同步删除（本地与仓库）',
            MediaDeletionScope.repository: '删除仓库副本，保留本地',
          }.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialog, item.key),
              child: Text(item.value),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (!mounted || scope == null || o.query != query) return;
    final token = SourceCancellation(
      checkAccess: () {
        if (!mounted || o.query != query)
          throw const SourceFailure(SourceFailureCode.cancelled);
        o.catalog;
      },
    );
    _deletion = token;
    setState(() => _deleting = true);
    var done = 0, failed = 0;
    final service = WindowsMediaDeletion(widget.service, o, widget.sync);
    try {
      for (final id in chosen) {
        token.check();
        setState(
          () => _deletionProgress =
              '正在处理：完成 $done 项，失败 $failed 项，共 ${chosen.length} 项',
        );
        try {
          await service.remove(id, scope, token);
          done++;
        } catch (_) {
          token.check();
          failed++;
        }
      }
    } catch (_) {
      // An interrupted batch retains per-target intentions and actual results.
    } finally {
      token.cancel();
      _deletion = null;
      if (mounted)
        setState(() {
          _deleting = false;
          _deletionProgress =
              '删除处理结束：完成 $done 项，失败 $failed 项；未完成项可按同一范围重试。离线设备尚需重连处理。';
        });
    }
  }

  @override
  void dispose() {
    _export?.cancel();
    _deletion?.cancel();
    _search.clear();
    _search.dispose();
    super.dispose();
  }

  Future<void> _showRecovery() async {
    if (_exporting || _deleting || _recovering) return;
    setState(() => _recovering = true);
    final token = SourceCancellation(
      checkAccess: () {
        if (!mounted) throw const SourceFailure(SourceFailureCode.cancelled);
        o.catalog;
      },
    );
    _deletion = token;
    try {
      await showDialog<void>(
        context: context,
        builder: (dialog) => _RecoveryDialog(
          service: widget.service,
          token: token,
          sync: widget.sync,
        ),
      );
    } finally {
      token.cancel();
      _deletion = null;
      if (mounted) setState(() => _recovering = false);
      if (mounted) o.refresh();
    }
  }

  Future<void> _showOperations() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _OperationHistoryDialog(organization: o),
    );
  }

  void _query({bool? favorites, String? search, LibraryFilter? filter}) {
    _page = 0;
    o.setQuery(
      LibraryQuery(
        albumId: o.query.albumId,
        favoritesOnly: favorites ?? o.query.favoritesOnly,
        search: search ?? o.query.search,
        filter: filter ?? o.query.filter,
      ),
    );
  }

  Future<void> _organize(String action, Iterable<String> selection) async {
    final ids = selection.toList();
    final query = o.query;
    try {
      String? albumId;
      final membership = action == 'add' || action == 'remove';
      if (membership) {
        final albums = o.albums;
        if (albums.isEmpty) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('请先在“我的相册”中创建相册。')));
          return;
        }
        albumId = await showDialog<String>(
          context: context,
          builder: (dialog) => SimpleDialog(
            title: Text(action == 'add' ? '加入相册' : '移出相册'),
            children: [
              for (final album in albums)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(dialog, album['id'] as String),
                  child: Text(album['name'] as String),
                ),
              SimpleDialogOption(
                onPressed: () => Navigator.pop(dialog),
                child: const Text('取消'),
              ),
            ],
          ),
        );
        if (!mounted || albumId == null) return;
      }
      if (!mounted || query != o.query) return;
      final saved = o.organize(
        ids,
        favorite: membership ? null : action == 'favorite',
        albumId: albumId,
        remove: action == 'remove',
      );
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              saved == 0
                  ? '当前没有可操作的所选项目。'
                  : '已保存 $saved 项整理${saved < ids.length ? '；其他项目已不在当前结果中' : ''}。',
            ),
          ),
        );
    } catch (_) {
      if (mounted) organizationError(context);
    }
  }

  Future<void> _choose() async {
    setState(() => _choosing = true);
    try {
      final selected = await getDirectoryPath(confirmButtonText: '导入此文件夹');
      if (!mounted || selected == null) return;
      widget.service.token.check();
      await widget.service.addFolder(selected);
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('未能选择或保存导入目录，请重试。')));
    } finally {
      if (mounted) setState(() => _choosing = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([o, if (widget.sync != null) widget.sync!]),
    builder: (context, _) {
      final s = widget.service;
      final count = o.count;
      final maxPage = count == 0 ? 0 : (count - 1) ~/ 200;
      if (_page > maxPage) _page = maxPage;
      final rows = o.page(_page);
      final counts = s.counts;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$count 项媒体 · 本机加密照片库'),
          const SizedBox(height: 12),
          if (o.query.albumId == null)
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: Text('全部 ${o.countFor(const LibraryQuery())}'),
                  selected: !o.query.favoritesOnly,
                  onSelected: (_) => _query(favorites: false),
                ),
                ChoiceChip(
                  label: Text(
                    '我的收藏 ${o.countFor(const LibraryQuery(favoritesOnly: true))}',
                  ),
                  selected: o.query.favoritesOnly,
                  onSelected: (_) => _query(favorites: true),
                ),
              ],
            ),
          const SizedBox(height: 12),
          TextField(
            controller: _search,
            enableIMEPersonalizedLearning: false,
            decoration: const InputDecoration(
              labelText: '按原文件名搜索',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (value) => _query(search: value),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final filter in LibraryFilter.values)
                ChoiceChip(
                  label: Text(
                    ['全部媒体', '已同步', '待同步', '仅本地', '仅仓库'][filter.index],
                  ),
                  selected: o.query.filter == filter,
                  onSelected:
                      LibraryOrganizationService.availableFilters.contains(
                        filter,
                      )
                      ? (_) => _query(filter: filter)
                      : null,
                ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                onPressed: _choosing ? null : _choose,
                icon: const Icon(Icons.create_new_folder_outlined),
                label: Text(_choosing ? '正在选择…' : '选择文件夹导入'),
              ),
              OutlinedButton.icon(
                onPressed: s.scanning ? null : s.requestScan,
                icon: const Icon(Icons.refresh),
                label: const Text('重新扫描'),
              ),
              OutlinedButton.icon(
                onPressed: _exporting || _deleting || _recovering
                    ? null
                    : _showRecovery,
                icon: const Icon(Icons.restore),
                label: const Text('恢复已删除的本地文件'),
              ),
              OutlinedButton.icon(
                onPressed: _showOperations,
                icon: const Icon(Icons.history),
                label: const Text('导出与删除记录'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            widget.sync == null
                ? '包含所有子文件夹。原文件保留在原位置，导入记录加密保存。同步服务当前不可用。'
                : '包含所有子文件夹。原文件保留在原位置，导入记录加密保存；云端同步需先选择并初始化私有仓库。',
          ),
          if (s.scanning || s.pending > 0) ...[
            const SizedBox(height: 12),
            Text(
              s.scanning ? '正在发现文件…' : '等待处理 ${s.pending} 个来源文件；被占用的文件会稍后重试',
            ),
            const SizedBox(height: 8),
            const LinearProgressIndicator(),
          ],
          if (s.issue case final message?)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                message,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          for (final source in s.sources)
            Builder(
              builder: (context) {
                final state = source['state'] as Map;
                var ready = 0, unsupported = 0;
                for (final c in counts.where(
                  (c) => c['source_id'] == source['id'],
                )) {
                  if (c['status'] == 'ready') ready += c['count'] as int;
                  if (c['status'] == 'unsupported')
                    unsupported += c['count'] as int;
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SelectableText(
                        source['path'] as String,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      Text(
                        '已保存 $ready 个来源文件${unsupported > 0 ? ' · $unsupported 个文件无法识别或读取' : ''}${state['phase'] == 'complete' ? ' · 本轮扫描完成' : ''}',
                      ),
                      if (state['issue'] case final String message)
                        Text(message),
                    ],
                  ),
                );
              },
            ),
          const SizedBox(height: 24),
          if (_exportProgress != null) Text(_exportProgress!),
          if (_deletionProgress != null) Text(_deletionProgress!),
          if (_deleting)
            TextButton(
              onPressed: () => _deletion?.cancel(),
              child: const Text('停止后续删除'),
            ),
          if (_exporting)
            TextButton(
              onPressed: () => _export?.cancel(),
              child: const Text('取消剩余导出'),
            ),
          if (!o.selection.active)
            OutlinedButton.icon(
              onPressed: o.beginSelection,
              icon: const Icon(Icons.checklist),
              label: const Text('多选'),
            ),
          if (o.selection.active)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('已选择 ${o.selection.ids.length} 项'),
                TextButton(
                  onPressed: count == 0 ? null : o.selectAll,
                  child: const Text('全选'),
                ),
                TextButton(
                  onPressed: o.selection.ids.isEmpty
                      ? null
                      : () => o.clearSelection(exit: false),
                  child: const Text('取消全选'),
                ),
                for (final entry in {
                  'favorite': '收藏所选',
                  'unfavorite': '取消收藏所选',
                  'add': '加入相册',
                  'remove': '移出相册',
                }.entries)
                  OutlinedButton(
                    onPressed: o.selection.ids.isEmpty
                        ? null
                        : () => _organize(entry.key, o.selection.ids),
                    child: Text(entry.value),
                  ),
                OutlinedButton(
                  onPressed: widget.sync == null || o.selection.ids.isEmpty
                      ? null
                      : () => _upload(o.selection.ids),
                  child: Text(widget.sync == null ? '批量上传 · 暂不可用' : '批量上传'),
                ),
                OutlinedButton(
                  onPressed: _exporting || o.selection.ids.isEmpty
                      ? null
                      : () => _exportMedia(o.selection.ids),
                  child: const Text('批量导出'),
                ),
                OutlinedButton(
                  onPressed: _deleting || _exporting || o.selection.ids.isEmpty
                      ? null
                      : () => _deleteMedia(o.selection.ids),
                  child: const Text('批量删除'),
                ),
                TextButton(
                  onPressed: o.clearSelection,
                  child: const Text('退出选择'),
                ),
              ],
            ),
          const SizedBox(height: 12),
          if (rows.isEmpty)
            SizedBox(
              height: 230,
              child: Center(
                child: Text(
                  s.mediaCount == 0
                      ? '这里还没有照片\n选择一个照片或视频文件夹开始导入。'
                      : '当前没有符合条件的媒体',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          else
            SizedBox(
              height: 560,
              child: GridView.builder(
                key: ValueKey(_page),
                itemCount: rows.length,
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 220,
                  mainAxisExtent: 200,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                itemBuilder: (context, index) => _MediaCard(
                  key: ValueKey(
                    '${rows[index]['id']}/${rows[index]['version']}/${rows[index]['local']}',
                  ),
                  record: rows[index],
                  service: s,
                  organization: o,
                  sync: widget.sync,
                  onUpload: () => _upload([rows[index]['id'] as String]),
                  onDelete: _deleting || _exporting
                      ? null
                      : () => _deleteMedia([rows[index]['id'] as String]),
                  onExport: _exporting
                      ? null
                      : () => _exportMedia([rows[index]['id'] as String]),
                  selecting: o.selection.active,
                  selected: o.selection.ids.contains(rows[index]['id']),
                  onSelect: () => o.toggle(rows[index]['id'] as String),
                  onOrganize: (action) =>
                      _organize(action, [rows[index]['id'] as String]),
                ),
              ),
            ),
          if (count > 200)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton(
                  onPressed: _page == 0 ? null : () => setState(() => _page--),
                  child: const Text('上一页'),
                ),
                Text('${_page + 1} / ${maxPage + 1}'),
                TextButton(
                  onPressed: _page >= maxPage
                      ? null
                      : () => setState(() => _page++),
                  child: const Text('下一页'),
                ),
              ],
            ),
        ],
      );
    },
  );
}

class _MediaCard extends StatefulWidget {
  const _MediaCard({
    super.key,
    required this.record,
    required this.service,
    required this.organization,
    required this.selecting,
    required this.selected,
    required this.onSelect,
    required this.onOrganize,
    this.sync,
    this.onUpload,
    this.onExport,
    this.onDelete,
  });
  final Map<String, Object?> record;
  final WindowsImportService service;
  final LibraryOrganizationService organization;
  final bool selecting, selected;
  final VoidCallback onSelect;
  final ValueChanged<String> onOrganize;
  final WindowsSyncService? sync;
  final VoidCallback? onUpload;
  final VoidCallback? onExport;
  final VoidCallback? onDelete;
  @override
  State<_MediaCard> createState() => _MediaCardState();
}

class _MediaCardState extends State<_MediaCard> {
  @override
  void initState() {
    super.initState();
    WindowsMediaThumbnailer.resumed.addListener(_retryPreview);
  }

  late SourceCancellation _thumbnailToken = _newThumbnailToken();
  SourceCancellation _newThumbnailToken() {
    final query = widget.organization.query;
    final id = widget.record['id'] as String,
        version = widget.record['version'];
    return SourceCancellation(
      checkAccess: () {
        if (!mounted || widget.organization.query != query)
          throw const SourceFailure(SourceFailureCode.cancelled);
        final catalog = widget.organization.catalog;
        if (catalog.mediaById(id)?['version'] != version ||
            catalog.queryIds(query, within: [id]).isEmpty) {
          throw const SourceFailure(SourceFailureCode.cancelled);
        }
      },
    );
  }

  late Future<Uint8List?> _preview = _loadPreview();
  Future<Uint8List?> _loadPreview() async {
    _thumbnailToken.check();
    final cover = widget.service.readVideoCover(widget.record['id'] as String);
    if (cover != null) return cover;
    if (widget.record['local'] != true &&
        widget.sync?.receipt(widget.record['id'] as String) != null) {
      return WindowsMediaThumbnailer.createRemote(
        widget.service,
        widget.sync!,
        widget.record,
        _thumbnailToken,
      );
    }
    if (widget.record['local'] == true &&
        ({'video', 'livePhoto'}.contains(widget.record['kind']) ||
            (widget.record['size'] as int) > 16 * 1024 * 1024 ||
            !{
              'JPEG',
              'PNG',
              'GIF',
              'BMP',
              'WebP',
              'Live Photo',
            }.contains(widget.record['format']))) {
      return WindowsMediaThumbnailer.create(
        widget.service,
        widget.record,
        _thumbnailToken,
      );
    }
    return widget.service.preview(widget.record['id'] as String);
  }

  void _retryPreview() {
    if (!mounted) return;
    _thumbnailToken.cancel();
    _preview.then(widget.service.releasePreview, onError: (Object _) {});
    setState(() {
      _thumbnailToken = _newThumbnailToken();
      _preview = _loadPreview();
    });
  }

  @override
  void didUpdateWidget(covariant _MediaCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.record['viewMetadata'];
    final current = widget.record['viewMetadata'];
    if ((old is Map ? old['thumbnail'] : null) !=
        (current is Map ? current['thumbnail'] : null)) {
      _preview.then(widget.service.releasePreview, onError: (Object _) {});
      _preview = _loadPreview();
    }
  }

  @override
  void dispose() {
    WindowsMediaThumbnailer.resumed.removeListener(_retryPreview);
    _thumbnailToken.cancel();
    _preview.then(widget.service.releasePreview, onError: (Object _) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.record;
    final video = r['kind'] != 'photo';
    final local = r['local'] == true;
    final metadata = r['viewMetadata'];
    final duration = metadata is Map && metadata['version'] == r['version']
        ? metadata['durationMs']
        : (r['sourceMetadata'] is Map
              ? (r['sourceMetadata'] as Map)['durationMs']
              : null);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Expanded(
            child: InkWell(
              onTap: widget.selecting
                  ? widget.onSelect
                  : (local || widget.sync?.receipt(r['id'] as String) != null)
                  ? () => _view(context)
                  : null,
              child: SizedBox(
                width: double.infinity,
                child: FutureBuilder<Uint8List?>(
                  future: _preview,
                  builder: (context, snapshot) {
                    if (snapshot.hasData)
                      return Image.memory(
                        snapshot.data!,
                        fit: BoxFit.cover,
                        cacheWidth: 512,
                        errorBuilder: (_, __, ___) =>
                            _fallback(video, '预览解码失败'),
                      );
                    return _fallback(
                      video,
                      snapshot.connectionState == ConnectionState.waiting
                          ? '正在读取封面…'
                          : !local
                          ? widget.sync?.receipt(r['id'] as String) != null
                                ? video
                                      ? '仓库视频 · 点击按需播放'
                                      : '仓库照片 · 点击按需查看'
                                : '本地原文件缺失'
                          : video
                          ? '视频 · 点击播放'
                          : snapshot.connectionState == ConnectionState.waiting
                          ? '正在读取…'
                          : '预览暂不可用',
                    );
                  },
                ),
              ),
            ),
          ),
          Row(
            children: [
              const SizedBox(width: 10),
              if (widget.selecting)
                Checkbox(
                  value: widget.selected,
                  onChanged: (_) => widget.onSelect(),
                ),
              Expanded(
                child: Text(
                  '${_size(r['size'] as int)}${video && duration is int ? ' · ${duration ~/ 60000}:${((duration ~/ 1000) % 60).toString().padLeft(2, '0')}' : ''}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              IconButton(
                tooltip: r['favorite'] == true ? '取消收藏' : '收藏',
                iconSize: 18,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28),
                onPressed: () => widget.onOrganize(
                  r['favorite'] == true ? 'unfavorite' : 'favorite',
                ),
                icon: Icon(
                  r['favorite'] == true
                      ? Icons.favorite
                      : Icons.favorite_border,
                ),
              ),
              PopupMenuButton<String>(
                tooltip: '媒体操作',
                onSelected: (action) => action == 'details'
                    ? _details(context)
                    : action == 'preview'
                    ? _retryPreview()
                    : action == 'upload'
                    ? widget.onUpload?.call()
                    : action == 'export'
                    ? widget.onExport?.call()
                    : action == 'delete'
                    ? widget.onDelete?.call()
                    : widget.onOrganize(action),
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'details', child: Text('查看详情')),
                  PopupMenuItem(
                    value: 'upload',
                    enabled: widget.sync != null,
                    child: Text(widget.sync == null ? '上传 · 暂不可用' : '上传'),
                  ),
                  const PopupMenuItem(value: 'preview', child: Text('重新读取封面')),
                  const PopupMenuItem(value: 'add', child: Text('加入相册')),
                  const PopupMenuItem(value: 'remove', child: Text('移出相册')),
                  PopupMenuItem(
                    value: 'export',
                    enabled: widget.onExport != null,
                    child: const Text('导出'),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    enabled: widget.onDelete != null,
                    child: const Text('删除'),
                  ),
                ],
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              widget.sync?.verified(r) == true
                  ? '已备份至当前仓库'
                  : !local
                  ? widget.sync?.receipt(r['id'] as String) != null
                        ? '仓库清单已认证 · 内容按需校验'
                        : '原文件缺失'
                  : r['autoUploadSuppressed'] == true
                  ? '仅保留本地'
                  : '未备份',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _fallback(bool video, String text) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(video ? Icons.videocam_outlined : Icons.image_outlined, size: 34),
        const SizedBox(height: 8),
        Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12),
        ),
      ],
    ),
  );
  void _view(BuildContext context) {
    final source = widget.organization.query;
    final id = widget.record['id'] as String;
    if (widget.organization.catalog.queryIds(source, within: [id]).isEmpty)
      return;
    final releaseThumbnails = WindowsMediaThumbnailer.prioritizeViewer();
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => ProductionMediaViewer(
              record: widget.record,
              organization: widget.organization,
              source: source,
              imports: widget.service,
              sync: widget.sync,
              onDetails: () => _details(context),
              onClosed: releaseThumbnails,
            ),
          ),
        )
        .whenComplete(releaseThumbnails);
  }

  void _details(BuildContext context) {
    final source = widget.organization.query;
    final id = widget.record['id'] as String;
    final db = widget.organization.catalog;
    if (db.queryIds(source, within: [id]).isEmpty) return;
    final r = db.mediaById(id);
    if (r == null) return;
    final metadata = r['viewMetadata'];
    final properties = metadata is Map && metadata['version'] == r['version']
        ? metadata
        : r['sourceMetadata'] is Map
        ? r['sourceMetadata'] as Map
        : null;
    final duration = properties?['durationMs'];
    final dimensions =
        properties?['width'] == null || properties?['height'] == null
        ? '未知'
        : '${properties?['width']} × ${properties?['height']}';
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('查看详情'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                SelectableText('原文件名：${r['fileName']}'),
                const SizedBox(height: 10),
                SelectableText('来源：${r['path'] ?? '当前仓库'}'),
                const SizedBox(height: 10),
                Text(
                  '大小：${_size(r['size'] as int)}\n识别格式：${r['format']}\n画面尺寸：$dimensions\n拍摄时间：${r['sourceMetadata'] is Map ? ((r['sourceMetadata'] as Map)['captureText'] ?? '未知') : '未知'}\n${r['kind'] != 'photo' ? '时长：${duration is int ? '${(duration / 1000).toStringAsFixed(1)} 秒' : '未知（打开视频后读取）'}\n' : ''}本地原文件：${r['local'] == true ? '可用' : '缺失'}\n仓库备份：${widget.sync == null
                      ? '同步服务不可用'
                      : widget.sync!.verified(r)
                      ? '当前版本已发布并读回核验'
                      : '当前版本未确认完整备份'}',
                ),
                const SizedBox(height: 10),
                Text(
                  r['local'] == true
                      ? '导入索引加密保存。格式识别不代表完整播放或远端备份已通过验证。'
                      : '仓库清单已认证；未读取的原始资源仍需按需下载并验证。',
                ),
                if (r['identityReliable'] == false)
                  const Text('此来源不能可靠跟踪改名，使用保守路径匹配。'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}

String _size(int bytes) => bytes < 1024
    ? '$bytes B'
    : bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} KB'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
