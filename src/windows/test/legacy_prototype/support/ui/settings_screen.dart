import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/demo_store.dart';
import 'components.dart';
import 'dialogs.dart';

import 'package:encrypted_photo_app/ui/theme.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.store});
  final DemoStore store;

  Future<void> _confirmReset(BuildContext context, {bool setup = false}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(setup ? '重新体验首次设置？' : '重置演示会话？'),
        content: const Text('只会还原虚构照片和演示设置。所有本次演示修改会重置，不影响真实文件。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    if (confirmed == true) setup ? store.beginSetup() : store.reset();
  }

  Future<void> _changePin(BuildContext context) async {
    final input = TextEditingController();
    String? error;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('设置演示应用锁'),
          content: SizedBox(
            width: 350,
            child: TextField(
              controller: input,
              autofocus: true,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(4),
              ],
              decoration: InputDecoration(
                labelText: '新的四位数字 PIN',
                errorText: error,
                helperText: '只用于本次演示会话',
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
                if (store.setPin(input.text)) {
                  Navigator.pop(dialogContext);
                } else {
                  update(() => error = '请输入四位数字，并与照片密码区分');
                }
              },
              child: const Text('保存演示 PIN'),
            ),
          ],
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    input.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Surface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeading('访问与密码', subtitle: '照片解密密码与四位应用锁，各自负责不同的保护'),
            const SizedBox(height: 20),
            _settingRow(
              Icons.password_rounded,
              '照片解密密码',
              '每 3 天必须正确输入 · 还有 ${store.verificationRemaining.inHours} 小时到期',
              OutlinedButton(
                onPressed: store.expireVerification,
                child: const Text('模拟到期'),
              ),
            ),
            const Divider(height: 28),
            _settingRow(
              Icons.pin_outlined,
              '四位应用锁',
              '上锁后，仅显示密码输入界面',
              OutlinedButton(
                onPressed: () => _changePin(context),
                child: const Text('设置 PIN'),
              ),
            ),
            const SizedBox(height: 20),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.canvas,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '仅供体验的演示凭据',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    '照片密码：${store.demoPassword}\n应用锁 PIN：${store.demoPin}',
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.9,
                      color: AppColors.green,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '请勿输入真实密码。演示状态仅存在内存中，退出应用后重置。',
                    style: TextStyle(color: AppColors.muted, fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 22),
      Surface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeading('仓库与设备', subtitle: 'GitHub 与 Gitee 均提供模拟授权流程'),
            const SizedBox(height: 20),
            _settingRow(
              Icons.cloud_outlined,
              store.provider.label,
              '${store.repository} · 私有 · 模拟连接',
              OutlinedButton(
                onPressed: () => showRepositoryDialog(context, store),
                child: const Text('管理仓库'),
              ),
            ),
            const Divider(height: 28),
            _settingRow(
              Icons.devices_outlined,
              '新设备解锁',
              '平台已授权后，仍须输入照片解密密码',
              OutlinedButton(
                onPressed: store.beginNewDevice,
                child: const Text('体验解锁'),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 22),
      Surface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeading('演示控制台', subtitle: '用可重复的场景检查交互，不代表正式实现策略'),
            const SizedBox(height: 20),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                OutlinedButton.icon(
                  onPressed: () {
                    store.advanceTime(const Duration(days: 1));
                  },
                  icon: const Icon(Icons.update, size: 17),
                  label: const Text('时间前进 1 天'),
                ),
                OutlinedButton.icon(
                  onPressed: store.expireVerification,
                  icon: const Icon(Icons.event_busy_outlined, size: 17),
                  label: const Text('立即到期'),
                ),
                OutlinedButton.icon(
                  onPressed: store.lock,
                  icon: const Icon(Icons.lock_outline, size: 17),
                  label: const Text('锁定应用'),
                ),
                OutlinedButton.icon(
                  onPressed: () => store.importSamples(3),
                  icon: const Icon(
                    Icons.add_photo_alternate_outlined,
                    size: 17,
                  ),
                  label: const Text('添加 3 张待同步样片'),
                ),
              ],
            ),
            const SizedBox(height: 24),
            DropdownButtonFormField<SyncFault>(
              key: ValueKey(store.fault),
              initialValue: store.fault,
              decoration: const InputDecoration(labelText: '同步环境（模拟）'),
              items: SyncFault.values
                  .map((f) => DropdownMenuItem(value: f, child: Text(f.label)))
                  .toList(),
              onChanged: (fault) => store.setFault(fault!),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('普通应用锁上锁时暂停同步', style: TextStyle(fontSize: 13)),
              subtitle: const Text(
                '仅切换本次演示行为，正式策略尚待确认',
                style: TextStyle(fontSize: 11, color: AppColors.muted),
              ),
              value: store.pauseOnPinLock,
              onChanged: store.setPauseOnLock,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('模拟下一次删除失败', style: TextStyle(fontSize: 13)),
              subtitle: const Text(
                '失败时保留原状态，不显示为删除成功',
                style: TextStyle(fontSize: 11, color: AppColors.muted),
              ),
              value: store.failNextDeletion,
              onChanged: store.setDeletionFailure,
            ),
            const Divider(height: 28),
            Wrap(
              spacing: 12,
              runSpacing: 10,
              children: [
                OutlinedButton(
                  onPressed: () => _confirmReset(context, setup: true),
                  child: const Text('重新体验首次设置'),
                ),
                TextButton(
                  onPressed: () => _confirmReset(context),
                  child: const Text('重置全部演示数据'),
                ),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 24),
      const Center(
        child: Text(
          '密屿 · MIYU   /   WINDOWS 交互原型 0.1.0\n加密算法、真实授权和同步协议将在后续方案中确定。',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11, color: AppColors.muted, height: 1.9),
        ),
      ),
    ],
  );
}

Widget _settingRow(
  IconData icon,
  String title,
  String subtitle,
  Widget action,
) => LayoutBuilder(
  builder: (context, constraints) {
    final label = Row(
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.sage,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: AppColors.green, size: 21),
        ),
        const SizedBox(width: 15),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
                style: const TextStyle(color: AppColors.muted, fontSize: 11),
              ),
            ],
          ),
        ),
      ],
    );
    if (constraints.maxWidth < 440)
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [label, const SizedBox(height: 14), action],
      );
    return Row(
      children: [
        Expanded(child: label),
        const SizedBox(width: 16),
        action,
      ],
    );
  },
);
