import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/demo_store.dart';
import 'components.dart';

import 'package:encrypted_photo_app/ui/theme.dart';

class AccessScreen extends StatefulWidget {
  const AccessScreen({super.key, required this.store});
  final DemoStore store;
  @override
  State<AccessScreen> createState() => _AccessScreenState();
}

class _AccessScreenState extends State<AccessScreen> {
  final _input = TextEditingController();
  String? _error;
  bool _obscure = true;
  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _submit() {
    final pin = widget.store.pinLocked;
    final valid = pin
        ? widget.store.unlockPin(_input.text)
        : widget.store.verifyPhotoPassword(_input.text);
    if (!valid)
      setState(() => _error = pin ? '应用锁密码不正确，请再试一次' : '照片解密密码不正确，同步保持暂停');
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final pin = store.pinLocked;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              children: [
                const VaultMark(size: 64),
                const SizedBox(height: 30),
                Text(
                  pin
                      ? '给回忆，留一点私密'
                      : store.verificationDue
                      ? '再记住一次，你的密码'
                      : '解锁你的照片库',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 12),
                Text(
                  pin
                      ? '请输入四位数字应用锁密码'
                      : store.verificationDue
                      ? '距上次验证已满 3 天。请输入照片解密密码，\n验证通过后恢复照片访问和同步。'
                      : '仓库授权已完成。还需要照片解密密码，\n才能在这台演示设备上查看照片。',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.muted, height: 1.8),
                ),
                const SizedBox(height: 30),
                TextField(
                  key: const ValueKey('access-password'),
                  controller: _input,
                  autofocus: true,
                  obscureText: _obscure,
                  onSubmitted: (_) => _submit(),
                  keyboardType: pin
                      ? TextInputType.number
                      : TextInputType.visiblePassword,
                  inputFormatters: pin
                      ? [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(4),
                        ]
                      : [],
                  textAlign: pin ? TextAlign.center : TextAlign.start,
                  style: pin
                      ? const TextStyle(fontSize: 28, letterSpacing: 18)
                      : null,
                  decoration: InputDecoration(
                    labelText: pin ? '四位应用锁密码' : '照片解密密码',
                    errorText: _error,
                    suffixIcon: pin
                        ? null
                        : IconButton(
                            tooltip: _obscure ? '显示密码' : '隐藏密码',
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                            icon: Icon(
                              _obscure
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    key: const ValueKey('unlock-button'),
                    onPressed: _submit,
                    icon: const Icon(Icons.lock_open_outlined, size: 18),
                    label: Text(pin ? '解锁应用' : '验证并继续'),
                  ),
                ),
                const SizedBox(height: 26),
                Text(
                  '仅为原型演示 · ${pin ? '当前 PIN：${store.demoPin}' : '当前照片密码：${store.demoPassword}'}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: AppColors.muted),
                ),
                if (store.photoPasswordRequired) ...[
                  const SizedBox(height: 14),
                  const Pill(
                    '照片访问与同步已暂停',
                    icon: Icons.pause_circle_outline,
                    color: AppColors.amber,
                    background: Color(0xFFF6EEDA),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, required this.store});
  final DemoStore store;
  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _pin = TextEditingController();
  RepositoryProvider _provider = RepositoryProvider.github;
  String _repository = 'demo-user / private-memories';
  bool _authorized = false;
  bool _remember = false;
  String? _error;
  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    _pin.dispose();
    super.dispose();
  }

  void _finish() {
    if (!_authorized) {
      setState(() => _error = '请先完成模拟授权并选择仓库');
      return;
    }
    if (_password.text != _confirm.text) {
      setState(() => _error = '两次照片密码不一致');
      return;
    }
    if (!_remember) {
      setState(() => _error = '请确认已记住照片解密密码');
      return;
    }
    if (!widget.store.completeSetup(
      password: _password.text,
      pin: _pin.text,
      selectedProvider: _provider,
      selectedRepository: _repository,
    )) {
      setState(() => _error = '请输入照片密码及四位数字 PIN，两种密码请使用不同内容');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: LayoutBuilder(
      builder: (context, constraints) {
        final form = SingleChildScrollView(
          padding: EdgeInsets.all(constraints.maxWidth < 650 ? 24 : 44),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 470),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      VaultMark(),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          '密屿  /  MIYU',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Pill('首次设置演示'),
                    ],
                  ),
                  const SizedBox(height: 32),
                  Text(
                    '为回忆，安一个家',
                    style: Theme.of(context).textTheme.headlineLarge,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '这是交互原型，请使用虚构密码。不会连接真实账号。',
                    style: TextStyle(color: AppColors.muted, fontSize: 12),
                  ),
                  const SizedBox(height: 28),
                  const Text(
                    '01   选择你的私有仓库',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<RepositoryProvider>(
                    segments: RepositoryProvider.values
                        .map(
                          (p) => ButtonSegment(
                            value: p,
                            label: Text(p.label),
                            icon: const Icon(Icons.code, size: 18),
                          ),
                        )
                        .toList(),
                    selected: {_provider},
                    onSelectionChanged: (value) => setState(() {
                      _provider = value.first;
                      _authorized = false;
                    }),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: () => setState(() {
                          _authorized = true;
                          _error = null;
                        }),
                        icon: const Icon(Icons.link, size: 16),
                        label: Text(
                          _authorized ? '模拟授权成功' : '模拟授权 ${_provider.label}',
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () => setState(() {
                          _authorized = false;
                          _error = '模拟授权失败，可重新尝试';
                        }),
                        child: const Text('演示失败'),
                      ),
                    ],
                  ),
                  if (_authorized) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      initialValue: _repository,
                      decoration: const InputDecoration(labelText: '私有仓库（演示）'),
                      items:
                          const [
                                'demo-user / private-memories',
                                'demo-user / travel-vault',
                              ]
                              .map(
                                (name) => DropdownMenuItem(
                                  value: name,
                                  child: Text(name),
                                ),
                              )
                              .toList(),
                      onChanged: (value) =>
                          setState(() => _repository = value!),
                    ),
                  ],
                  const SizedBox(height: 24),
                  const Text(
                    '02   设置照片解密密码',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: '演示照片解密密码'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _confirm,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: '再次输入照片解密密码'),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    '03   设置四位应用锁',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _pin,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(4),
                    ],
                    decoration: const InputDecoration(
                      labelText: '四位数字 PIN',
                      helperText: '仅用于锁定应用，不替代照片解密密码',
                    ),
                  ),
                  const SizedBox(height: 16),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text(
                      '我已记住照片解密密码',
                      style: TextStyle(fontSize: 13),
                    ),
                    subtitle: const Text(
                      '每 3 天必须正确输入，验证前照片访问和同步暂停。',
                      style: TextStyle(fontSize: 11),
                    ),
                    value: _remember,
                    onChanged: (value) => setState(() => _remember = value!),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        _error!,
                        style: const TextStyle(color: AppColors.red),
                      ),
                    ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _finish,
                      child: const Text('进入我的演示照片库'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Center(
                    child: TextButton(
                      onPressed: () => widget.store.reset(),
                      child: const Text('使用预置演示库快速体验'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        if (constraints.maxWidth < 1050) return form;
        return Row(
          children: [
            Expanded(
              flex: 5,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.asset(
                    'test/fixtures/legacy_photos/photo_01.jpg',
                    fit: BoxFit.cover,
                  ),
                  Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x22214D40), Color(0xE5214D40)],
                      ),
                    ),
                  ),
                  const Positioned(
                    left: 48,
                    right: 48,
                    bottom: 64,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '那些平凡的日子，\n都是值得珍藏的回忆。',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 34,
                            height: 1.6,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        SizedBox(height: 20),
                        Text(
                          '属于你的照片，属于你的选择。',
                          style: TextStyle(
                            color: Color(0xCCFFFFFF),
                            fontSize: 15,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(flex: 6, child: form),
          ],
        );
      },
    ),
  );
}
