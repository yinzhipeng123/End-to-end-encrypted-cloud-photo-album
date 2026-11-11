import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:encrypted_photo_app/repositories/github_api.dart';
import 'package:encrypted_photo_app/repositories/github_connection.dart';
import 'package:encrypted_photo_app/sync/windows_sync_service.dart';

class GitHubConnectionPanel extends StatefulWidget {
  const GitHubConnectionPanel({
    super.key,
    required this.connection,
    this.sync,
    this.onRestore,
  });
  final GitHubConnection connection;
  final WindowsSyncService? sync;
  final VoidCallback? onRestore;
  @override
  State<GitHubConnectionPanel> createState() => _GitHubConnectionPanelState();
}

class _GitHubConnectionPanelState extends State<GitHubConnectionPanel> {
  String? _browserError;
  String? _queueTarget;
  String _queueFilter = 'pending';
  final _jobPages = <String>[''];
  Future<void> _openDevicePage() async {
    try {
      final ok = await const MethodChannel('miyu/access')
          .invokeMethod<bool>('openGitHubDevice');
      if (mounted)
        setState(
          () => _browserError = ok == true
              ? null
              : '浏览器未能打开，请手动访问 https://github.com/login/device。',
        );
    } catch (_) {
      if (mounted)
        setState(
          () =>
              _browserError = '浏览器未能打开，请手动访问 https://github.com/login/device。',
        );
    }
  }

  Future<void> _openInstallationPage() async {
    const fallback = '浏览器未能打开，请手动访问 ${GitHubRegistration.manageAppsPage}。';
    try {
      final ok = await const MethodChannel('miyu/access')
          .invokeMethod<bool>('openGitHubApps');
      if (mounted) {
        setState(() => _browserError = ok == true ? null : fallback);
      }
    } catch (_) {
      if (mounted) setState(() => _browserError = fallback);
    }
  }

  Widget _queue(WindowsSyncService sync, bool connectionBusy) {
    if (_queueTarget != sync.targetKey) {
      _queueTarget = sync.targetKey;
      _jobPages
        ..clear()
        ..add('');
    }
    final counts = sync.jobCounts;
    final filters = <String, Set<String>?>{
      'pending': {'queued', 'preparing', 'prepared', 'uploading', 'retry'},
      'failed': {'failed', 'conflict'},
      'complete': {'complete'},
      'all': null,
    };
    final labels = {
      'pending': '待处理',
      'failed': '失败或冲突',
      'complete': '已完成任务',
      'all': '全部记录',
    };
    int count(String key) => counts.entries
        .where((item) => filters[key]?.contains(item.key) ?? true)
        .fold(0, (sum, item) => sum + item.value);
    final rows = sync.jobPage(
      after: _jobPages.last,
      phases: filters[_queueFilter],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          children: [
            for (final key in filters.keys)
              ChoiceChip(
                label: Text('${labels[key]} ${count(key)}'),
                selected: _queueFilter == key,
                onSelected: (_) => setState(() {
                  _queueFilter = key;
                  _jobPages
                    ..clear()
                    ..add('');
                }),
              ),
          ],
        ),
        if (rows.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text('当前页没有此类任务。'),
          ),
        for (final job in rows)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(switch (job['phase']) {
              'complete' => '此版本上传任务已完成',
              'deleted' => '副本已删除，可在媒体详情中重新上传',
              'conflict' => '版本冲突，已保留内容，未自动覆盖',
              'failed' => '上传未完成',
              'retry' => '等待重试',
              'preparing' => '正在加密',
              'prepared' => '已加密，等待上传',
              'uploading' => '正在上传／核对',
              _ => '等待同步',
            }),
            subtitle: job['failure'] is String
                ? Text(job['failure'] as String)
                : null,
            trailing: Wrap(
              spacing: 4,
              children: [
                if ({'failed', 'retry'}.contains(job['phase']))
                  TextButton(
                    onPressed: sync.busy || connectionBusy
                        ? null
                        : () => sync.retryUploadJob(job['recordKey'] as String),
                    child: const Text('重试'),
                  ),
                if (job['phase'] == 'complete' &&
                    sync.receipt(job['mediaId'] as String) != null)
                  TextButton(
                    onPressed: sync.busy || connectionBusy || sync.paused
                        ? null
                        : () => sync.verifyRemote(job['mediaId'] as String),
                    child: const Text('校验当前副本'),
                  ),
                IconButton(
                  tooltip: '查看任务详情',
                  icon: const Icon(Icons.info_outline),
                  onPressed: () {
                    final media = sync.catalog().mediaById(
                      job['mediaId'] as String,
                    );
                    showDialog<void>(
                      context: context,
                      builder: (dialog) => AlertDialog(
                        title: const Text('上传任务详情'),
                        content: SingleChildScrollView(
                          child: SelectableText(
                            '原文件名：${media?['fileName'] ?? '当前目录中已不存在'}\n仓库：${sync.selectedName ?? '未选择'}\n任务版本：${job['sourceVersion']}\n重试次数：${job['attempts'] ?? 0}\n${job['retryAt'] is int ? '最早重试时间：${DateTime.fromMillisecondsSinceEpoch(job['retryAt'] as int).toLocal()}\n' : ''}${job['failure'] ?? ''}\n历史任务完成不代表当前版本或其他仓库已备份。',
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(dialog),
                            child: const Text('关闭'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton(
              onPressed: _jobPages.length == 1
                  ? null
                  : () => setState(() => _jobPages.removeLast()),
              child: const Text('上一页'),
            ),
            Text('第 ${_jobPages.length} 页'),
            TextButton(
              onPressed: rows.length < 50
                  ? null
                  : () => setState(
                      () => _jobPages.add(rows.last['recordKey'] as String),
                    ),
              child: const Text('下一页'),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      widget.connection,
      if (widget.sync != null) widget.sync!,
    ]),
    builder: (context, _) {
      final connection = widget.connection;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('GitHub', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Text('网络：${connection.networkDescription}'),
          const SizedBox(height: 8),
          if (connection.user case final user?) Text('账号：${user.login}'),
          if (connection.selected case final target?)
            SelectableText(
              '所选仓库：${target.fullName}${connection.verified ? '' : '（待核验）'}',
            ),
          if (connection.message case final message?) ...[
            const SizedBox(height: 12),
            Text(message),
          ],
          if (connection.busy) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
          if (connection.userCode case final code?) ...[
            const SizedBox(height: 20),
            const Text('本次设备授权码'),
            SelectableText(
              code,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            if (connection.codeExpiresAt case final expiry?)
              Text('有效至：${expiry.toLocal().toString().split('.').first}'),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _openDevicePage,
              icon: const Icon(Icons.open_in_browser),
              label: const Text('打开 GitHub 官方授权页面'),
            ),
            const SizedBox(height: 8),
            const SelectableText('https://github.com/login/device'),
            const Text('请核对应用名称和权限，仅输入本 App 当前显示的代码。'),
          ],
          const SizedBox(height: 20),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              OutlinedButton(
                onPressed: connection.busy ? null : connection.authorize,
                child: Text(
                  connection.user == null ? 'GitHub 授权登录' : '重新授权 GitHub',
                ),
              ),
              OutlinedButton.icon(
                onPressed: connection.busy ? null : _openInstallationPage,
                icon: const Icon(Icons.open_in_browser),
                label: const Text('安装 / 管理 GitHub App'),
              ),
              if (connection.user != null) ...[
                OutlinedButton(
                  onPressed: connection.busy
                      ? null
                      : connection.refreshRepositories,
                  child: const Text('检查连接 / 刷新仓库'),
                ),
                TextButton(
                  onPressed: connection.busy ? null : connection.disconnect,
                  child: const Text('断开本机连接'),
                ),
              ],
              if (connection.busy)
                TextButton(
                  onPressed: connection.cancelAuthorization,
                  child: const Text('取消本次操作'),
                ),
            ],
          ),
          if (_browserError != null) ...[
            const SizedBox(height: 12),
            SelectableText(_browserError!),
          ],
          const SizedBox(height: 16),
          const Text(
            '账号授权后，还需把本相册应用安装到照片仓库。管理页中选择本应用 → Edit → Install App → Only select repositories；安装完成后返回这里刷新仓库。',
          ),
          const SelectableText('本相册应用 App ID：${GitHubRegistration.appId}'),
          const SizedBox(height: 20),
          const Text('选择照片备份仓库（首次使用需明确初始化）'),
          const SizedBox(height: 8),
          if (connection.user == null)
            const Text('请先完成 GitHub 授权登录，再查询可选仓库。')
          else if (!connection.verified)
            const Text('仓库列表尚未核验，请点击“检查连接 / 刷新仓库”。')
          else if (connection.repositories.isEmpty)
            Text(
              connection.installationCount == 0
                  ? '未查到本相册应用在当前账号下的安装。请安装本应用并选择照片私有仓库，再刷新。'
                  : '已查到本相册应用的安装，但没有可列出的仓库。请检查安装中所选的仓库和当前账号的访问权限，再刷新。',
            )
          else ...[
            for (final repository in connection.repositories)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(repository.fullName),
                subtitle: Text(repository.reason ?? '私有仓库 · 平台报告具备写权限'),
                trailing: OutlinedButton(
                  onPressed: !repository.eligible || connection.busy
                      ? null
                      : () => connection.selectRepository(repository),
                  child: Text(
                    connection.selected?.id == repository.id ? '重新核验' : '选择',
                  ),
                ),
              ),
          ],
          const SizedBox(height: 24),
          if (widget.onRestore != null) ...[
            OutlinedButton(
              onPressed:
                  connection.busy ||
                      widget.sync?.busy == true ||
                      connection.selected == null
                  ? null
                  : widget.onRestore,
              child: const Text('从所选仓库恢复到新数据目录'),
            ),
            const SizedBox(height: 12),
          ],
          if (widget.sync case final sync?) ...[
            if (sync.issue != null) Text(sync.issue!),
            const SizedBox(height: 12),
            Text(switch (sync.phase) {
              'initializing' => '正在初始化仓库…',
              'encrypting' => '正在加密原始资源',
              'uploading' => '正在上传密文',
              'verifying' => '正在从仓库读回校验',
              'publishing' => '正在发布并核对完整清单',
              'downloading' => '正在下载并认证解密仓库副本',
              _ =>
                sync.paused
                    ? '同步已手动暂停'
                    : sync.initialized
                    ? '自动同步已启用，最小化或手动锁定后继续；系统锁屏、睡眠或密码到期时暂停'
                    : '仓库尚未初始化',
            }),
            if (sync.bytesTotal > 0 && sync.busy) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: (sync.bytesDone / sync.bytesTotal).clamp(0.0, 1.0),
              ),
              Text('${sync.bytesDone} / ${sync.bytesTotal} 字节（当前阶段）'),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                if (!sync.initialized)
                  FilledButton(
                    onPressed:
                        sync.busy ||
                            connection.busy ||
                            connection.selected == null
                        ? null
                        : () async {
                            final approved = await showDialog<bool>(
                              context: context,
                              builder: (dialog) => AlertDialog(
                                title: const Text('初始化加密仓库'),
                                content: Text(
                                  '目标：${sync.selectedName}\n将创建 epa-data-v1 数据分支保存密文。空仓库会先在默认分支建立固定应用标识文件。初始化成功后会自动上传本机已导入媒体。',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(dialog, false),
                                    child: const Text('取消'),
                                  ),
                                  FilledButton(
                                    onPressed: () =>
                                        Navigator.pop(dialog, true),
                                    child: const Text('初始化'),
                                  ),
                                ],
                              ),
                            );
                            if (approved == true && mounted)
                              await sync.initializeRepository();
                          },
                    child: const Text('初始化此私有仓库'),
                  ),
                if (sync.initialized)
                  OutlinedButton.icon(
                    onPressed: sync.busy || connection.busy || sync.paused
                        ? null
                        : sync.synchronizeNow,
                    icon: const Icon(Icons.sync),
                    label: const Text('立即同步'),
                  ),
                if (connection.selected != null)
                  OutlinedButton(
                    onPressed: sync.paused ? sync.resume : sync.pause,
                    child: Text(sync.paused ? '恢复同步' : '暂停同步'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            const Text('队列状态来自真实操作；加密、上传或入队不等于已备份。'),
            _queue(sync, connection.busy),
          ] else
            const Text('同步服务当前不可用，请重新解锁后检查连接。'),
        ],
      );
    },
  );
}
