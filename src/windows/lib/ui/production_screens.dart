import 'package:flutter/material.dart';

import 'package:encrypted_photo_app/ui/github_connection_panel.dart';
import 'package:encrypted_photo_app/ui/production_library_panel.dart';
import 'package:encrypted_photo_app/ui/production_album_panel.dart';
import 'package:encrypted_photo_shared/model/library_query.dart';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

import 'package:encrypted_photo_app/app/vault_controller.dart';
import 'package:encrypted_photo_app/sync/repository_vault_recovery.dart';
import 'package:encrypted_photo_app/ui/theme.dart';

class _PasswordField extends StatefulWidget {
  const _PasswordField({
    super.key,
    required this.controller,
    required this.label,
    this.enabled = true,
    this.pin = false,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String label;
  final bool enabled;
  final bool pin;
  final ValueChanged<String>? onSubmitted;

  @override
  State<_PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<_PasswordField> {
  bool _visible = false;

  @override
  void didUpdateWidget(covariant _PasswordField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller || !widget.enabled) {
      _visible = false;
    }
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: widget.controller,
    enabled: widget.enabled,
    obscureText: !_visible,
    autocorrect: false,
    enableSuggestions: false,
    enableIMEPersonalizedLearning: false,
    keyboardType: widget.pin
        ? TextInputType.number
        : TextInputType.visiblePassword,
    inputFormatters: widget.pin
        ? [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(4),
          ]
        : null,
    decoration: InputDecoration(
      labelText: widget.label,
      suffixIcon: IconButton(
        tooltip: _visible ? '隐藏密码' : '显示密码',
        onPressed: widget.enabled
            ? () => setState(() => _visible = !_visible)
            : null,
        icon: Icon(
          _visible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
        ),
      ),
    ),
    onSubmitted: widget.onSubmitted,
  );
}

class VaultAccessScreen extends StatefulWidget {
  const VaultAccessScreen({
    super.key,
    required this.controller,
    required this.platformAvailable,
  });
  final VaultController controller;
  final Future<bool> Function() platformAvailable;
  @override
  State<VaultAccessScreen> createState() => _VaultAccessScreenState();
}

class _VaultAccessScreenState extends State<VaultAccessScreen> {
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  final _pin = TextEditingController();
  final _pinConfirmation = TextEditingController();
  bool _remembered = false;
  bool _resetPin = false;
  bool _choosingDirectory = false;
  String? _error;

  @override
  void dispose() {
    for (final value in [_password, _confirmation, _pin, _pinConfirmation]) {
      value.clear();
      value.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    final controller = widget.controller;
    if (controller.busy || _choosingDirectory) return;
    final screen = controller.screen;
    final password = _password.text;
    final confirmation = _confirmation.text;
    final pin = _pin.text;
    final pinConfirmation = _pinConfirmation.text;
    final reset = _resetPin;
    if (!await widget.platformAvailable()) {
      if (mounted) setState(() => _error = 'Windows 安全事件监听不可用或窗口已锁定，无法解锁。');
      return;
    }
    if (!mounted) return;
    setState(() => _error = null);
    switch (screen) {
      case VaultScreen.setup:
        await controller.initialize(
          password: password,
          confirmation: confirmation,
          pin: pin,
          pinConfirmation: pinConfirmation,
        );
      case VaultScreen.pin:
        await controller.unlock(pin);
      case VaultScreen.photoPassword:
        await controller.authenticatePhotoPassword(
          password,
          newPin: reset ? pin : null,
          pinConfirmation: reset ? pinConfirmation : null,
        );
      default:
        return;
    }
    // Cover a platform transition racing the asynchronous native computation.
    await widget.platformAvailable();
    if (mounted) {
      _password.clear();
      _confirmation.clear();
      _pin.clear();
      _pinConfirmation.clear();
    }
  }

  Future<void> _chooseDirectory() async {
    final controller = widget.controller;
    if (controller.busy || _choosingDirectory) return;
    setState(() {
      _choosingDirectory = true;
      _error = null;
    });
    try {
      final parent = await getDirectoryPath(
        initialDirectory: controller.setupDirectory.parent.path,
        confirmButtonText: '选择保存位置',
      );
      if (mounted && parent != null) controller.selectDataParent(parent);
    } catch (_) {
      if (mounted) setState(() => _error = '无法打开文件夹选择窗口，请重试。');
    } finally {
      if (mounted) setState(() => _choosingDirectory = false);
    }
  }

  Widget _field(
    TextEditingController value,
    String label, {
    bool pin = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: _PasswordField(
      key: ValueKey(value),
      controller: value,
      label: label,
      enabled: !widget.controller.busy && !_choosingDirectory,
      pin: pin,
      onSubmitted: (_) {
        if (!widget.controller.busy &&
            (widget.controller.screen != VaultScreen.setup || _remembered)) {
          _submit();
        }
      },
    ),
  );

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final setup = c.screen == VaultScreen.setup;
    final photo = c.screen == VaultScreen.photoPassword;
    final failed = c.screen == VaultScreen.failure;
    final loading = c.screen == VaultScreen.loading;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 490),
            child: Card(
              elevation: 0,
              color: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
                side: const BorderSide(color: AppColors.line),
              ),
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(
                      Icons.lock_outline_rounded,
                      color: AppColors.pine,
                      size: 42,
                    ),
                    const SizedBox(height: 20),
                    Text(
                      setup
                          ? '为回忆，安一个家'
                          : failed
                          ? '照片库暂时无法打开'
                          : photo
                          ? '再记住一次，你的密码'
                          : '密屿 · 应用已锁定',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      setup
                          ? '设置照片解密密码和本机应用锁。请牢记照片密码，遗忘后无法通过平台账号或四位密码找回。'
                          : photo
                          ? '每 72 小时需要正确输入照片解密密码。验证前，照片访问与同步保持暂停。'
                          : failed
                          ? '已有加密数据不会被自动删除或重建。'
                          : '输入本机的四位应用锁密码，继续访问照片库。',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    if (loading)
                      const Center(child: CircularProgressIndicator()),
                    if (setup) ...[
                      Text(
                        '程序的数据保存目的地',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 8),
                      SelectableText(c.setupDirectory.path),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: c.busy || _choosingDirectory
                                ? null
                                : _chooseDirectory,
                            icon: const Icon(Icons.folder_open_outlined),
                            label: const Text('选择文件夹'),
                          ),
                          TextButton(
                            onPressed: c.busy || _choosingDirectory
                                ? null
                                : c.useDefaultDataDirectory,
                            child: const Text('恢复默认位置'),
                          ),
                        ],
                      ),
                      const Text(
                        '选择后将在该位置创建 EncryptedPhotoApp 专用子目录，保存加密管理数据；原照片位置不变。',
                      ),
                      const SizedBox(height: 20),
                    ],
                    if (setup || photo) _field(_password, '照片解密密码'),
                    if (setup) ...[
                      _field(_confirmation, '再次输入照片解密密码'),
                      const Padding(
                        padding: EdgeInsets.only(bottom: 18),
                        child: Text('12–128 个字符；建议用多个不相关的词组成长口令。'),
                      ),
                    ],
                    if (photo)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('同时重新设置本机四位应用锁'),
                        value: _resetPin,
                        onChanged: c.busy
                            ? null
                            : (value) => setState(() => _resetPin = value!),
                      ),
                    if (setup ||
                        c.screen == VaultScreen.pin ||
                        (photo && _resetPin))
                      _field(
                        _pin,
                        setup || _resetPin ? '设置四位应用锁密码' : '四位应用锁密码',
                        pin: true,
                      ),
                    if (setup || (photo && _resetPin))
                      _field(_pinConfirmation, '再次输入四位应用锁密码', pin: true),
                    if (setup)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('我已记住照片解密密码，并了解遗忘后无法找回'),
                        value: _remembered,
                        onChanged: c.busy
                            ? null
                            : (value) => setState(() => _remembered = value!),
                      ),
                    if (_error != null || c.message != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        child: Text(
                          _error ?? c.message!,
                          style: const TextStyle(color: AppColors.red),
                        ),
                      ),
                    if (!failed && !loading)
                      FilledButton(
                        onPressed:
                            c.busy ||
                                _choosingDirectory ||
                                (setup && !_remembered)
                            ? null
                            : _submit,
                        child: Text(
                          c.busy
                              ? '正在验证与保存…'
                              : setup
                              ? '建立加密照片库'
                              : photo
                              ? c.repositoryPasswordRequired
                                    ? '验证并采用仓库当前照片密码'
                                    : '验证照片密码'
                              : '解锁',
                        ),
                      ),
                    if (c.screen == VaultScreen.pin)
                      TextButton(
                        onPressed: c.busy ? null : c.requestPhotoPassword,
                        child: const Text('忘记应用锁密码？使用照片密码验证'),
                      ),
                    if (photo)
                      const Padding(
                        padding: EdgeInsets.only(top: 18),
                        child: Text('忘记照片密码后无法重置解密，也不会通过清空数据来重置。'),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ProductionShell extends StatefulWidget {
  const ProductionShell({
    super.key,
    required this.controller,
    required this.lock,
  });
  final VaultController controller;
  final VoidCallback lock;
  @override
  State<ProductionShell> createState() => _ProductionShellState();
}

class _ProductionShellState extends State<ProductionShell> {
  int _page = 0;
  String? _albumId;
  static const _pages = ['所有照片', '我的相册', '云端同步', '访问与密码'];
  late final Future<String?> _version = _readVersion();

  Future<String?> _readVersion() async {
    try {
      return await const MethodChannel('miyu/access')
          .invokeMethod<String>('appVersion');
    } catch (_) {
      return null;
    }
  }

  void _about(String? version) => showAboutDialog(
    context: context,
    applicationName: '密屿',
    applicationVersion: version,
    children: const [
      Text('照片管理与加密同步 · Windows 客户端'),
      SizedBox(height: 12),
      Text('当前云端服务：GitHub 私有仓库。Gitee 授权及同步尚未开放；iOS 客户端尚未提供。'),
      SizedBox(height: 12),
      Text('本版本的媒体兼容性、同步与异常恢复仍待完整验收。具体操作结果请查看同步和导出／删除记录。'),
    ],
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('密屿'),
      actions: [
        FutureBuilder<String?>(
          future: _version,
          builder: (context, snapshot) => TextButton.icon(
            onPressed: () => _about(snapshot.data),
            icon: const Icon(Icons.info_outline),
            label: Text(snapshot.hasData ? 'v${snapshot.data}' : '关于密屿'),
          ),
        ),
        const SizedBox(width: 20),
        TextButton.icon(
          onPressed: widget.lock,
          icon: const Icon(Icons.lock_outline),
          label: const Text('锁定'),
        ),
        const SizedBox(width: 20),
      ],
    ),
    body: Row(
      children: [
        NavigationRail(
          extended: MediaQuery.sizeOf(context).width >= 900,
          selectedIndex: _page,
          onDestinationSelected: (value) {
            widget.controller.organization?.setQuery(const LibraryQuery());
            widget.controller.organization?.clearSelection();
            setState(() {
              _page = value;
              _albumId = null;
            });
          },
          destinations: [
            for (var i = 0; i < _pages.length; i++)
              NavigationRailDestination(
                icon: Icon(
                  [
                    Icons.photo_library_outlined,
                    Icons.collections_bookmark_outlined,
                    Icons.cloud_outlined,
                    Icons.settings_outlined,
                  ][i],
                ),
                label: Text(_pages[i]),
              ),
          ],
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(36),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _pages[_page],
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
                const SizedBox(height: 12),
                if (_page == 0) ...[
                  if (widget.controller.imports case final service?)
                    ProductionLibraryPanel(
                      key: const ValueKey('aggregate'),
                      service: service,
                      organization: widget.controller.organization!,
                      sync: widget.controller.sync,
                    ),
                ],
                if (_page == 1) ...[
                  if (_albumId == null)
                    ProductionAlbumPanel(
                      service: widget.controller.organization!,
                      onOpen: (id) {
                        widget.controller.organization!.setQuery(
                          LibraryQuery(albumId: id),
                        );
                        setState(() => _albumId = id);
                      },
                    )
                  else ...[
                    TextButton.icon(
                      onPressed: () {
                        widget.controller.organization!.setQuery(
                          const LibraryQuery(),
                        );
                        setState(() => _albumId = null);
                      },
                      icon: const Icon(Icons.arrow_back),
                      label: const Text('返回相册列表'),
                    ),
                    Text(
                      widget.controller.catalog.albumById(_albumId!)?['name']
                              as String? ??
                          '相册',
                    ),
                    const SizedBox(height: 12),
                    ProductionLibraryPanel(
                      key: ValueKey(_albumId),
                      service: widget.controller.imports!,
                      organization: widget.controller.organization!,
                      sync: widget.controller.sync,
                    ),
                  ],
                ],
                if (_page == 2) ...[
                  if (widget.controller.github case final connection?)
                    GitHubConnectionPanel(
                      connection: connection,
                      sync: widget.controller.sync,
                      onRestore: () => showDialog<void>(
                        context: context,
                        builder: (_) => _RestoreRepositoryDialog(
                          controller: widget.controller,
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  const OutlinedButton(
                    onPressed: null,
                    child: Text('Gitee 授权 · 未实现'),
                  ),
                  const Text('Gitee 尚未接入符合本应用安全要求的授权方式，当前不能选择 Gitee 仓库或向其同步。'),
                  const SizedBox(height: 12),
                ],
                if (_page == 3) ...[
                  Text(
                    '程序的数据保存目的地',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  SelectableText(widget.controller.directory.absolute.path),
                  const SizedBox(height: 24),
                  const Text(
                    '最小化或手动锁定后，照片界面关闭，后台继续导入与同步。系统锁屏、睡眠或照片密码到期时，同步暂停；重启后需先解锁。',
                  ),
                  const SizedBox(height: 20),
                  if (widget.controller.expiresAt != null)
                    Text(
                      '下次照片密码复验期限：${DateTime.fromMillisecondsSinceEpoch(widget.controller.expiresAt!).toLocal().toString().split('.').first}',
                    ),
                  const SizedBox(height: 20),
                  OutlinedButton(
                    onPressed: widget.controller.requestPhotoPassword,
                    child: const Text('验证照片密码 / 重设应用锁'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: () => _changePassword(context),
                    child: const Text('修改照片解密密码'),
                  ),
                  const SizedBox(height: 24),
                  const Text('请牢记照片密码。平台账号、应用锁和系统辅助解锁均不能重置照片解密密码。'),
                  const SizedBox(height: 24),
                  TextButton(
                    onPressed: () => showLicensePage(
                      context: context,
                      applicationName: '密屿',
                    ),
                    child: const Text('开源许可'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    ),
  );

  Future<void> _changePassword(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _ChangePasswordDialog(controller: widget.controller),
    );
  }
}

class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog({required this.controller});
  final VaultController controller;
  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _old = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  @override
  void dispose() {
    for (final value in [_old, _next, _confirm]) {
      value.clear();
      value.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('修改照片解密密码'),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '本机改密后，已关联仓库的恢复材料会等待解锁联网后更新。完成前会明确显示待更新；已复制出去的旧密码包装和主密钥不会被撤销。',
            ),
            const SizedBox(height: 20),
            for (final field in [
              (_old, '当前照片密码'),
              (_next, '新的照片密码'),
              (_confirm, '再次输入新的照片密码'),
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: _PasswordField(
                  key: ValueKey(field.$1),
                  controller: field.$1,
                  label: field.$2,
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          final old = _old.text;
          final next = _next.text;
          final confirm = _confirm.text;
          widget.controller.changePassword(
            oldPassword: old,
            newPassword: next,
            confirmation: confirm,
          );
        },
        child: const Text('验证并修改'),
      ),
    ],
  );
}

class _RestoreRepositoryDialog extends StatefulWidget {
  const _RestoreRepositoryDialog({required this.controller});
  final VaultController controller;
  @override
  State<_RestoreRepositoryDialog> createState() =>
      _RestoreRepositoryDialogState();
}

class _RestoreRepositoryDialogState extends State<_RestoreRepositoryDialog> {
  final _password = TextEditingController(),
      _pin = TextEditingController(),
      _confirmation = TextEditingController();
  RepositoryRecoveryPreview? _preview;
  String? _parent, _error;
  bool _busy = true;
  @override
  void initState() {
    super.initState();
    _inspect();
  }

  Future<void> _inspect() async {
    try {
      final preview = await widget.controller.inspectRepositoryRecovery();
      if (mounted) setState(() => _preview = preview);
    } catch (e) {
      if (mounted) setState(() => _error = VaultController.describeFailure(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    for (final field in [_password, _pin, _confirmation]) {
      field.clear();
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('恢复仓库照片库'),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_busy) const LinearProgressIndicator(),
            if (_preview case final preview?) ...[
              Text('仓库：${preview.repositoryName}'),
              SelectableText('照片库身份：${preview.vaultId}'),
              const SizedBox(height: 14),
              const Text(
                '请确认这是你要恢复的照片库。输入该仓库的照片密码，在新目录建立独立加密索引和应用锁。完成后切换到新库，原库仍保留；原始照片和视频按需下载。',
              ),
              const SizedBox(height: 14),
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () async {
                        final path = await getDirectoryPath(
                          confirmButtonText: '选择恢复位置',
                        );
                        if (mounted && path != null)
                          setState(() => _parent = path);
                      },
                child: const Text('选择新数据保存位置'),
              ),
              if (_parent != null)
                SelectableText('恢复位置：$_parent\\EncryptedPhotoApp'),
              const SizedBox(height: 14),
              _PasswordField(
                controller: _password,
                label: '仓库照片密码',
                enabled: !_busy,
              ),
              _PasswordField(
                controller: _pin,
                label: '新库四位应用锁',
                pin: true,
                enabled: !_busy,
              ),
              _PasswordField(
                controller: _confirmation,
                label: '再次输入新库应用锁',
                pin: true,
                enabled: !_busy,
              ),
            ],
            if (_error != null) Text(_error!),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _busy || _preview == null || _parent == null
            ? null
            : () async {
                setState(() => _busy = true);
                final password = _password.text,
                    pin = _pin.text,
                    confirmation = _confirmation.text;
                _password.clear();
                _pin.clear();
                _confirmation.clear();
                await widget.controller.restoreRepository(
                  expected: _preview!,
                  parent: _parent!,
                  password: password,
                  pin: pin,
                  pinConfirmation: confirmation,
                );
                if (mounted)
                  setState(() {
                    _busy = false;
                    _error = widget.controller.message;
                  });
              },
        child: const Text('恢复并切换到新库'),
      ),
    ],
  );
}
