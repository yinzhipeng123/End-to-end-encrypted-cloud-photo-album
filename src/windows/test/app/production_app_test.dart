import 'dart:convert';
import 'dart:io';

import 'package:encrypted_photo_app/app/vault_controller.dart';
import 'package:encrypted_photo_app/main.dart';
import 'package:encrypted_photo_app/services/import/windows_source_reader.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  if (!Platform.isWindows) return;
  WindowsSourceReader.setTestLibrary(
    File('build/source-reader/Release/epa_source_reader.dll').absolute.path,
  );
  testWidgets(
    'production forms use real credentials; revocation removes dialogs; unavailable operations are disabled',
    (tester) async {
      late Directory scratch;
      late VaultController controller;
      const channel = MethodChannel('miyu/access');
      const pickerChannel = MethodChannel('plugins.flutter.io/file_selector');
      String? pickedDirectory;
      // Only the OS dialog response is substituted. The selected directory,
      // credentials, protected locator and SQLCipher writes remain real.
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        pickerChannel,
        (call) async {
          expect(call.method, 'getDirectoryPath');
          return pickedDirectory;
        },
      );
      // Only native window-event delivery is substituted here. OS delivery is
      // verified separately in the compiled Windows runner.
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => true,
      );
      await tester.runAsync(() async {
        scratch = await Directory.systemTemp.createTemp('epa-widget-real-');
        controller = VaultController(
          Directory('${scratch.path}/vault'),
          automaticCheck: false,
        );
        await controller.start();
      });
      addTearDown(() async {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          pickerChannel,
          null,
        );
        final imports = controller.imports;
        await controller.close();
        await imports?.settled;
        controller.dispose();
        await scratch.delete(recursive: true);
      });
      tester.view.physicalSize = const Size(1280, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(PhotoVaultApp(controller: controller));
      await tester.pumpAndSettle();
      expect(find.text('为回忆，安一个家'), findsOneWidget);
      expect(find.textContaining('样片'), findsNothing);
      expect(find.text('程序的数据保存目的地'), findsOneWidget);
      final originalDirectory = controller.setupDirectory.path;
      await tester.tap(find.text('选择文件夹'));
      await tester.pumpAndSettle();
      expect(controller.setupDirectory.path, originalDirectory);
      pickedDirectory = scratch.path;
      await tester.tap(find.text('选择文件夹'));
      await tester.pumpAndSettle();
      expect(controller.setupDirectory.path, isNot(originalDirectory));
      expect(find.text(controller.setupDirectory.path), findsOneWidget);
      final selectedDirectory = controller.setupDirectory;
      expect(selectedDirectory.existsSync(), false);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '建立加密照片库'))
            .onPressed,
        isNull,
      );
      const password = 'artificial production form password';
      for (final entry in {
        '照片解密密码': password,
        '再次输入照片解密密码': password,
        '设置四位应用锁密码': '4958',
        '再次输入四位应用锁密码': '4958',
      }.entries) {
        await tester.enterText(
          find.widgetWithText(TextField, entry.key),
          entry.value,
        );
      }
      final photoPassword = find.widgetWithText(TextField, '照片解密密码');
      expect(
        tester
            .widgetList<TextField>(find.byType(TextField))
            .every((field) => field.obscureText),
        isTrue,
      );
      await tester.tap(
        find.descendant(of: photoPassword, matching: find.byTooltip('显示密码')),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(photoPassword).obscureText, false);
      expect(
        tester.widget<TextField>(photoPassword).controller!.text,
        password,
      );
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, '再次输入照片解密密码'))
            .obscureText,
        true,
      );
      await tester.tap(
        find.descendant(of: photoPassword, matching: find.byTooltip('隐藏密码')),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(photoPassword).obscureText, true);
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      Future<void> submit(String label) async {
        await tester.runAsync(() async {
          await tester.tap(find.widgetWithText(FilledButton, label));
          // Native DPAPI/KDF/database IO executes outside Flutter's fake clock.
          for (var i = 0; i < 2000; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            if (!controller.busy) break;
          }
          // A retained background importer can have a timer queued on the
          // widget clock. Form completion does not require it to become idle;
          // waiting here would block the pump that runs that timer.
        });
        await tester.pumpAndSettle();
        expect(controller.busy, false);
      }

      await submit('建立加密照片库');
      expect(controller.screen, VaultScreen.pin, reason: controller.message);
      expect(controller.directory.path, selectedDirectory.path);
      expect(controller.catalogFile.existsSync(), true);
      expect(find.text('选择文件夹'), findsNothing);
      await tester.enterText(find.widgetWithText(TextField, '四位应用锁密码'), '0000');
      expect(
        tester.widget<TextField>(find.byType(TextField)).obscureText,
        true,
      );
      await tester.tap(find.byTooltip('显示密码'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).obscureText,
        false,
      );
      await submit('解锁');
      expect(find.text('所有照片'), findsNothing);
      await tester.enterText(find.widgetWithText(TextField, '四位应用锁密码'), '4958');
      await submit('解锁');
      expect(
        controller.screen,
        VaultScreen.library,
        reason: controller.message,
      );
      expect(find.textContaining('这里还没有照片'), findsOneWidget);
      pickedDirectory = null;
      await tester.tap(find.text('选择文件夹导入'));
      await tester.pumpAndSettle();
      expect(controller.catalog.sources(), isEmpty);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '选择文件夹导入'))
            .onPressed,
        isNotNull,
      );
      await tester.runAsync(() async {
        final folder = await Directory('${scratch.path}/source/subfolder')
            .create(recursive: true);
        await File('${folder.path}/artificial-private-name.png').writeAsBytes(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=',
          ),
        );
        pickedDirectory = folder.parent.path;
        await tester.tap(find.text('选择文件夹导入'));
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (controller.mediaCount != 1) {
          if (DateTime.now().isAfter(deadline))
            throw StateError('Real UI import timed out');
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      });
      await tester.pump();
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('1 项媒体'), findsOneWidget);
      expect(find.textContaining('artificial-private-name.png'), findsNothing);
      // Real organization from the production UI, persisted into the same
      // SQLCipher catalog as the actual file import above.
      Future<void> tapText(String text) async {
        final target = find.text(text).last;
        await tester.ensureVisible(target);
        await tester.tap(target);
        await tester.pumpAndSettle();
      }

      await tapText('我的相册');
      await tapText('创建相册');
      await tester.enterText(find.widgetWithText(TextField, '相册名称'), '人工私密相册');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.text('保存'));
      for (var i = 0; i < 100 && controller.catalog.albums().isEmpty; i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.textContaining('整理未能保存'), findsNothing);
      expect(controller.catalog.albums().single['name'], '人工私密相册');
      await tapText('改名');
      await tester.enterText(find.widgetWithText(TextField, '相册名称'), '人工整理相册');
      await tapText('保存');
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(controller.catalog.albums().single['hidden'], 1);
      await tapText('所有照片');
      await tapText('多选');
      await tapText('全选');
      expect(find.text('已选择 1 项'), findsOneWidget);
      await tapText('收藏所选');
      expect(controller.catalog.media().single['favorite'], true);
      await tapText('加入相册');
      await tapText('人工整理相册');
      expect(find.text('已选择 0 项'), findsOneWidget);
      expect(find.text('我的收藏 0'), findsOneWidget);
      expect(
        controller.catalog
            .albumMembers(controller.catalog.albums().single['id'] as String)
            .length,
        1,
      );
      await tapText('我的相册');
      await tapText('人工整理相册');
      expect(find.textContaining('1 项媒体'), findsOneWidget);
      expect(find.textContaining('artificial-private-name.png'), findsNothing);
      await tapText('多选');
      await tapText('全选');
      await tapText('移出相册');
      await tapText('人工整理相册');
      expect(find.text('已选择 0 项'), findsOneWidget);
      expect(controller.catalog.mediaCount, 1);
      await tapText('返回相册列表');
      await tapText('删除相册');
      await tapText('取消');
      expect(controller.catalog.albums().length, 1);
      await tapText('删除相册');
      await tapText('删除相册');
      expect(controller.catalog.albums(), isEmpty);
      expect(
        File('${pickedDirectory!}/subfolder/artificial-private-name.png')
            .existsSync(),
        true,
      );
      await tapText('所有照片');
      expect(find.text('我的收藏 1'), findsOneWidget);
      await tester.ensureVisible(find.byTooltip('媒体操作'));
      await tester.tap(find.byTooltip('媒体操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看详情'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('原文件名：artificial-private-name.png'),
        findsOneWidget,
      );
      final beforeMinimize = controller.sync;
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'miyu/access',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('lock', {'reason': 'minimize', 'epoch': 7}),
        ),
        (_) {},
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.textContaining('artificial-private-name.png'), findsNothing);
      expect(find.byType(Image), findsNothing);
      expect(PaintingBinding.instance.imageCache.currentSize, 0);
      expect(controller.sync, same(beforeMinimize));
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'backgroundAvailable',
      );
      await tester.enterText(find.widgetWithText(TextField, '四位应用锁密码'), '4958');
      await submit('解锁');
      expect(controller.screen, VaultScreen.pin);
      expect(
        controller.sync,
        same(beforeMinimize),
        reason: 'A minimized-window PIN attempt must not stop background work',
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => true,
      );
      await tester.enterText(find.widgetWithText(TextField, '四位应用锁密码'), '4958');
      await submit('解锁');
      expect(controller.mediaCount, 1);
      expect(controller.sync, same(beforeMinimize));
      await tester.tap(find.text('云端同步'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'GitHub 授权登录'),
            )
            .onPressed,
        isNotNull,
      );
      for (final label in ['Gitee 授权 · 未实现']) {
        expect(
          tester
              .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, label),
              )
              .onPressed,
          isNull,
        );
      }
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '初始化此私有仓库'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('访问与密码'));
      await tester.pumpAndSettle();
      expect(find.text('程序的数据保存目的地'), findsOneWidget);
      expect(find.text(selectedDirectory.absolute.path), findsOneWidget);
      expect(find.text(originalDirectory), findsNothing);
      await tester.tap(find.text('修改照片解密密码'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      final oldPassword = find.widgetWithText(TextField, '当前照片密码');
      await tester.enterText(oldPassword, password);
      await tester.tap(
        find.descendant(of: oldPassword, matching: find.byTooltip('显示密码')),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(oldPassword).obscureText, false);
      // Deliver the exact runner-to-Dart event with a mock messenger only.
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'miyu/access',
        const StandardMethodCodec().encodeMethodCall(const MethodCall('lock')),
        (_) {},
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        controller.sync,
        isNull,
        reason: 'Unknown/system lock must fully revoke',
      );
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.text('程序的数据保存目的地'), findsNothing);
      expect(find.text(selectedDirectory.absolute.path), findsNothing);
      expect(find.widgetWithText(TextField, '四位应用锁密码'), findsOneWidget);
      final lockedPin = tester.widget<TextField>(find.byType(TextField));
      expect(lockedPin.obscureText, true);
      expect(lockedPin.controller!.text, isEmpty);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => false,
      );
      await tester.enterText(find.widgetWithText(TextField, '四位应用锁密码'), '4958');
      await submit('解锁');
      expect(controller.screen, VaultScreen.pin);
      expect(find.text('Windows 安全事件监听不可用或窗口已锁定，无法解锁。'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
