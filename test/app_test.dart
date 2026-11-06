import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:encrypted_photo_app/main.dart';
import 'package:encrypted_photo_app/model/demo_store.dart';
import 'package:encrypted_photo_app/ui/library_screen.dart';
import 'package:encrypted_photo_app/ui/dialogs.dart';
import 'package:encrypted_photo_app/ui/home_shell.dart';

Future<void> render(
  WidgetTester tester,
  DemoStore store, {
  Size size = const Size(1280, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(PhotoVaultApp(store: store, autoTick: false));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('import and export dialogs use fictional data', (tester) async {
    final store = DemoStore();
    addTearDown(store.dispose);
    await render(tester, store);
    final count = store.totalCount;
    await tester.tap(find.text('导入照片'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入 3 张样片'));
    await tester.pumpAndSettle();
    expect(store.totalCount, count + 3);
    showExportDialog(
      tester.element(find.byType(HomeShell)),
      store,
      store.photos.first,
    );
    await tester.pumpAndSettle();
    expect(find.text('已演示导出流程，未向磁盘写入照片。'), findsOneWidget);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'repository cancellation and failure do not connect a new target',
    (tester) async {
      final store = DemoStore();
      addTearDown(store.dispose);
      await render(tester, store);
      showRepositoryDialog(tester.element(find.byType(HomeShell)), store);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Gitee'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('模拟失败'));
      await tester.pumpAndSettle();
      expect(store.provider, RepositoryProvider.github);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '使用这个仓库'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(store.provider, RepositoryProvider.github);
      showRepositoryDialog(tester.element(find.byType(HomeShell)), store);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Gitee'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('模拟授权 Gitee'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('使用这个仓库'));
      await tester.pumpAndSettle();
      expect(store.provider, RepositoryProvider.gitee);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'deletion requires explicit scope and reports failure before retry',
    (tester) async {
      final store = DemoStore();
      addTearDown(store.dispose);
      await render(tester, store);
      final photo = store.photos.first;
      showDeleteDialog(tester.element(find.byType(HomeShell)), store, photo);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确认模拟删除'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(photo.local && photo.remote, isTrue);
      store.setDeletionFailure(true);
      showDeleteDialog(tester.element(find.byType(HomeShell)), store, photo);
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除仓库副本，保留本地'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认模拟删除'));
      await tester.pumpAndSettle();
      expect(find.textContaining('模拟删除失败'), findsOneWidget);
      expect(photo.local && photo.remote, isTrue);
      await tester.tap(find.text('确认模拟删除'));
      await tester.pumpAndSettle();
      expect(photo.local, isTrue);
      expect(photo.remote, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('first setup completes with separate credentials', (
    tester,
  ) async {
    final store = DemoStore()..beginSetup();
    addTearDown(store.dispose);
    await render(tester, store, size: const Size(900, 1100));
    await tester.tap(find.text('模拟授权 GitHub'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, '演示照片解密密码'),
      'test-photo-password',
    );
    await tester.enterText(
      find.widgetWithText(TextField, '再次输入照片解密密码'),
      'test-photo-password',
    );
    await tester.enterText(find.widgetWithText(TextField, '四位数字 PIN'), '8642');
    await tester.ensureVisible(find.text('我已记住照片解密密码'));
    await tester.tap(find.text('我已记住照片解密密码'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('进入我的演示照片库'));
    await tester.tap(find.text('进入我的演示照片库'));
    await tester.pumpAndSettle();
    expect(store.configured, isTrue);
    expect(store.demoPin, '8642');
    expect(store.demoPassword, 'test-photo-password');
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop library renders local samples and searches', (
    tester,
  ) async {
    final store = DemoStore();
    addTearDown(store.dispose);
    await render(tester, store);
    expect(find.text('密屿'), findsOneWidget);
    expect(find.byType(PhotoCard), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.enterText(
      find.byKey(const ValueKey('photo-search')),
      'not-a-photo',
    );
    await tester.pumpAndSettle();
    expect(find.text('这里还没有照片'), findsOneWidget);
  });

  testWidgets('mobile-width shell has navigation and no overflow', (
    tester,
  ) async {
    final store = DemoStore();
    addTearDown(store.dispose);
    await render(tester, store, size: const Size(390, 844));
    expect(find.byTooltip('打开导航'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('打开导航'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('偏好设置'));
    await tester.pumpAndSettle();
    expect(find.text('访问与密码'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'expiration replaces open photo detail and requires correct password',
    (tester) async {
      final store = DemoStore();
      addTearDown(store.dispose);
      await render(tester, store);
      final card = find.byType(PhotoCard).first;
      await tester.tap(
        find.descendant(of: card, matching: find.byType(InkWell)).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('照片详情'), findsOneWidget);
      store.expireVerification();
      await tester.pumpAndSettle();
      expect(find.text('照片详情'), findsNothing);
      expect(find.byType(PhotoCard), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('access-password')),
        'wrong',
      );
      await tester.tap(find.byKey(const ValueKey('unlock-button')));
      await tester.pumpAndSettle();
      expect(find.text('照片解密密码不正确，同步保持暂停'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('access-password')),
        DemoStore.defaultPassword,
      );
      await tester.tap(find.byKey(const ValueKey('unlock-button')));
      await tester.pumpAndSettle();
      expect(find.byType(PhotoCard), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'PIN page hides navigation and PIN cannot clear expired verification',
    (tester) async {
      final store = DemoStore();
      addTearDown(store.dispose);
      store.lock();
      store.expireVerification();
      await render(tester, store);
      expect(find.text('偏好设置'), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('access-password')),
        DemoStore.defaultPin,
      );
      await tester.tap(find.byKey(const ValueKey('unlock-button')));
      await tester.pumpAndSettle();
      expect(find.text('再记住一次，你的密码'), findsOneWidget);
      expect(find.byType(PhotoCard), findsNothing);
    },
  );

  testWidgets('setup screen fits narrow layout', (tester) async {
    final store = DemoStore()..beginSetup();
    addTearDown(store.dispose);
    await render(tester, store, size: const Size(390, 844));
    expect(find.text('为回忆，安一个家'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
