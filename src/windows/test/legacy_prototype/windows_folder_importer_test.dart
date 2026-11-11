import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/model/demo_store.dart';
import 'support/model/local_preview_library.dart';
import 'support/services/windows_folder_importer.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('miyu-test-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });
  Future<File> file(String name) async {
    final result = File('${root.path}/$name');
    await result.parent.create(recursive: true);
    await result.writeAsBytes(List.filled(100, 1));
    return result;
  }

  test(
    'recursive scan discovers original photos and videos without writing them',
    () async {
      final photo = await file('a.JPG');
      await file('a/b/c/video.MOV');
      await file('ignore.txt');
      final before = await photo.readAsBytes();
      final scan = await WindowsFolderImporter().scan(
        root.path,
        settle: Duration.zero,
      );
      expect(scan.complete, isTrue);
      expect(scan.files, hasLength(2));
      expect(
        scan.files.values.map((p) => p.kind),
        containsAll([MediaKind.photo, MediaKind.video]),
      );
      expect(
        scan.files.values.map((p) => p.fileName),
        containsAll(['a.JPG', 'video.MOV']),
      );
      expect(await photo.readAsBytes(), before);
    },
  );

  test(
    'zero length and inaccessible roots are incomplete, not empty success',
    () async {
      await File('${root.path}/copying.mp4').create();
      final importer = WindowsFolderImporter();
      expect(
        (await importer.scan(root.path, settle: Duration.zero)).complete,
        isFalse,
      );
      expect((await importer.scan('${root.path}/missing')).complete, isFalse);
    },
  );

  test(
    'rescan deduplicates, keeps organizing state and marks external deletion',
    () async {
      final original = await file('original.jpg');
      final library = LocalPreviewLibrary(mayScan: () => true);
      addTearDown(library.dispose);
      await library.addFolder(root.path);
      final item = library.photos.single;
      library.setFavorite([item], true);
      library.createAlbum('本机分类');
      library.setAlbum(item, library.albums.single.id, true);
      item.remote = true; // 模拟已有仓库状态，扫描不得删除它。
      await library.rescan();
      expect(library.photos, hasLength(1));
      expect(library.photos.single.favorite, isTrue);
      await file('new/sub/video.mp4');
      await library.rescan();
      expect(library.photos, hasLength(2));
      await original.delete();
      await library.rescan();
      expect(item.local, isFalse);
      expect(item.sourceMissing, isTrue);
      expect(item.remote, isTrue);
      expect(library.albums.single.members, {item.id});
    },
  );

  test('demo reset preserves separate real source records and never simulates their upload', () async {
    final original = await file('local.jpg');
    final store = DemoStore();
    addTearDown(store.dispose);
    await store.importFolder(root.path);
    expect(store.previewMode, isTrue);
    final item = store.photos.single;
    store.createAlbum('真实整理');
    store.setAlbum(item, store.albums.single.id, true);
    store.toggleFavorite(item);
    for (var i = 0; i < 20; i++) {
      store.tick();
    }
    expect(item.remote || item.encrypted, isFalse);
    store.reset();
    expect(store.previewMode, isFalse);
    store.showLocalPreview(true);
    expect(store.photos.single, same(item));
    expect(item.favorite, isTrue);
    expect(store.albums.single.members, {item.id});
    expect(await original.exists(), isTrue);
    expect(store.deletePhoto(item, DeleteScope.local), isNotNull);
    expect(await original.exists(), isTrue);
  });
}
