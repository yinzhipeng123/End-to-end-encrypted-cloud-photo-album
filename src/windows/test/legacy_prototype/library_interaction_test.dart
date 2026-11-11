import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/model/demo_store.dart';
import 'support/ui/library_screen.dart';
import 'support/ui/home_shell.dart';
import 'support/ui/selection_toolbar.dart';
import 'support/ui/batch_dialogs.dart';
import 'support/ui/media_viewer.dart';
import 'app_test.dart' show render;

class MixedDemoStore extends DemoStore {
  final fixtures = <MediaItem>[];
  @override
  List<MediaItem> get mediaRecords => fixtures;
}

void main() {
  testWidgets(
    'cards hide all filenames; search still matches; menu places upload after details',
    (tester) async {
      final store = DemoStore();
      addTearDown(store.dispose);
      await render(tester, store);
      final filename = store.photos.first.fileName;
      expect(
        find.byWidgetPredicate((w) => w is Text && w.data == filename),
        findsNothing,
      );
      await tester.enterText(
        find.byKey(const ValueKey('photo-search')),
        filename,
      );
      await tester.pumpAndSettle();
      expect(find.byType(PhotoCard), findsOneWidget);
      expect(
        find.byWidgetPredicate((w) => w is Text && w.data == filename),
        findsNothing,
      );
      await tester.tap(find.byTooltip('照片操作'));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('上传')).dy,
        greaterThan(tester.getTopLeft(find.text('查看详情')).dy),
      );
      await tester.tap(find.text('查看详情'));
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate((w) => w is Text && w.data == filename),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'all results selected offscreen, card click toggles and query changes clear selection',
    (tester) async {
      final store = DemoStore()..importSamples(6);
      addTearDown(store.dispose);
      await render(tester, store);
      await tester.tap(find.text('多选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SelectionToolbar>(find.byType(SelectionToolbar))
            .selectedCount,
        22,
      );
      final card = find.byType(PhotoCard).first;
      await tester.tap(
        find.descendant(of: card, matching: find.byType(InkWell)).first,
      );
      await tester.pumpAndSettle();
      expect(find.byType(MediaViewer), findsNothing);
      expect(
        tester
            .widget<SelectionToolbar>(find.byType(SelectionToolbar))
            .selectedCount,
        21,
      );
      await tester.enterText(
        find.byKey(const ValueKey('photo-search')),
        'IMG_0100',
      );
      await tester.pumpAndSettle();
      expect(find.byType(SelectionToolbar), findsNothing);
      expect(find.byType(PhotoCard), findsOneWidget);
    },
  );

  testWidgets('hidden selection is removed before favorite batch action', (
    tester,
  ) async {
    final store = DemoStore();
    addTearDown(store.dispose);
    await render(tester, store);
    final hidden = store.albums.first;
    final original = {for (final p in store.photos) p.id: p.favorite};
    await tester.tap(find.text('多选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    store.setAlbumHidden(hidden.id, true);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SelectionToolbar>(find.byType(SelectionToolbar))
          .selectedCount,
      store.visibleCount,
    );
    await tester.tap(find.text('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('收藏所选'));
    await tester.pumpAndSettle();
    for (final p in store.photos) {
      expect(p.favorite, hidden.members.contains(p.id) ? original[p.id] : true);
    }
  });

  for (final expired in [false, true]) {
    testWidgets(
      'fullscreen is removed by ${expired ? 'verification expiry' : 'PIN lock'}',
      (tester) async {
        final store = DemoStore();
        addTearDown(store.dispose);
        await render(tester, store);
        final card = find.byType(PhotoCard).first;
        await tester.tap(
          find.descendant(of: card, matching: find.byType(InkWell)).first,
        );
        await tester.pumpAndSettle();
        expect(find.byType(MediaViewer), findsOneWidget);
        expect(find.byTooltip('退出全屏'), findsOneWidget);
        expired ? store.expireVerification() : store.lock();
        await tester.pumpAndSettle();
        expect(find.byType(MediaViewer), findsNothing);
        expect(find.byType(PhotoCard), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'batch cancel has no effect; partial deletion retries only failed items',
    (tester) async {
      final store = DemoStore();
      addTearDown(store.dispose);
      await render(tester, store);
      final items = store.photos.take(2).toList();
      final unselected = store.photos[3];
      showBatchResourceDialog(
        tester.element(find.byType(HomeShell)),
        store,
        () => items,
        deleting: true,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(items.every((p) => p.local && p.remote), isTrue);
      store.setDeletionFailure(true);
      showBatchResourceDialog(
        tester.element(find.byType(HomeShell)),
        store,
        () => items,
        deleting: true,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除仓库副本，保留本地'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认模拟删除'));
      await tester.pumpAndSettle();
      expect(find.text('模拟完成 1 项；失败 1 项'), findsOneWidget);
      expect(find.textContaining('第 1 项 · 照片：'), findsOneWidget);
      expect(find.text('第 2 项 · 照片：模拟完成'), findsOneWidget);
      expect(items[0].remote, isTrue);
      expect(items[1].remote, isFalse);
      await tester.tap(find.text('重试失败项'));
      await tester.pumpAndSettle();
      expect(find.text('模拟完成 2 项；失败 0 项'), findsOneWidget);
      expect(items.every((p) => p.local && !p.remote), isTrue);
      expect(unselected.local && unselected.remote, isTrue);
    },
  );

  testWidgets(
    'batch export cancellation and execution leave copies unchanged',
    (tester) async {
      final store = DemoStore();
      addTearDown(store.dispose);
      await render(tester, store);
      final items = store.photos.take(2).toList();
      final before = store.events.length;
      showBatchResourceDialog(
        tester.element(find.byType(HomeShell)),
        store,
        () => items,
        deleting: false,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(store.events.length, before);
      showBatchResourceDialog(
        tester.element(find.byType(HomeShell)),
        store,
        () => items,
        deleting: false,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认模拟导出'));
      await tester.pumpAndSettle();
      expect(find.text('模拟完成 2 项；失败 0 项'), findsOneWidget);
      expect(items.every((p) => p.local && p.remote), isTrue);
    },
  );

  testWidgets('selection toolbar fits narrow windows and clears on cancel', (
    tester,
  ) async {
    final store = DemoStore();
    addTearDown(store.dispose);
    await render(tester, store, size: const Size(390, 844));
    await tester.tap(find.text('多选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SelectionToolbar>(find.byType(SelectionToolbar))
          .selectedCount,
      16,
    );
    await tester.tap(find.text('取消全选'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SelectionToolbar>(find.byType(SelectionToolbar))
          .selectedCount,
      0,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Live Photo batch deletion reports one logical item and keeps the selected scope',
    (tester) async {
      final store = MixedDemoStore();
      addTearDown(store.dispose);
      final live = MediaItem(
        id: 'live-fixture',
        isDemo: true,
        kind: MediaKind.livePhoto,
        pairingIdentifier: 'verified-test-pair',
        takenAt: DateTime(2026, 11, 9),
        megabytes: 2,
        remote: true,
        resources: const [
          MediaResource(
            role: ResourceRole.image,
            location: 'test/fixtures/legacy_photos/photo_01.jpg',
            fileName: 'fixture.heic',
          ),
          MediaResource(
            role: ResourceRole.pairedVideo,
            location: '/test/fixture.mov',
            fileName: 'fixture.mov',
          ),
        ],
      );
      store.fixtures.add(live);
      await render(tester, store);
      showBatchResourceDialog(
        tester.element(find.byType(HomeShell)),
        store,
        () => [live],
        deleting: true,
      );
      await tester.pumpAndSettle();
      expect(find.text('当前选择 1 项媒体'), findsOneWidget);
      await tester.tap(find.text('删除本地，保留仓库副本'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认模拟删除'));
      await tester.pumpAndSettle();
      expect(find.text('模拟完成 1 项；失败 0 项'), findsOneWidget);
      expect(find.text('第 1 项 · 实况照片：模拟完成'), findsOneWidget);
      expect(find.textContaining('第 2 项'), findsNothing);
      expect(live.local, isFalse);
      expect(live.remote, isTrue);
      expect(live.resources, hasLength(2));
    },
  );

  testWidgets(
    'batch album changes affect selected members without deleting resources',
    (tester) async {
      final store = DemoStore();
      addTearDown(store.dispose);
      store.createAlbum('批量测试');
      final album = store.albums.last;
      final selected = store.photos.take(2).toList();
      await render(tester, store);
      for (final included in [true, false]) {
        showBatchAlbumDialog(
          tester.element(find.byType(HomeShell)),
          store,
          () => selected,
          included: included,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(RadioListTile<String>, '批量测试'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('确认'));
        await tester.pumpAndSettle();
        expect(
          album.members,
          included ? selected.map((p) => p.id).toSet() : isEmpty,
        );
        expect(selected.every((p) => p.local && p.remote), isTrue);
      }
    },
  );

  testWidgets(
    'batch upload queues selected media only and reports pending backup',
    (tester) async {
      final store = DemoStore();
      addTearDown(store.dispose);
      final selected = store.photos.take(2).toList();
      final other = store.photos[3];
      for (final item in [...selected, other]) {
        store.deletePhoto(item, DeleteScope.repository);
      }
      await render(tester, store);
      showUploadResults(
        tester.element(find.byType(HomeShell)),
        store,
        selected,
      );
      await tester.pumpAndSettle();
      expect(find.text('2 项：已加入模拟队列，尚未完成备份'), findsOneWidget);
      expect(
        selected.every((p) => p.stage == SyncStage.queued && !p.remote),
        isTrue,
      );
      expect(other.stage, SyncStage.localOnly);
      expect(other.remote, isFalse);
    },
  );
}
