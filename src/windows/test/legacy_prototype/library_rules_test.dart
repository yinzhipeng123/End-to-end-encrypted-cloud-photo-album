import 'package:flutter_test/flutter_test.dart';
import 'package:encrypted_photo_shared/model/album.dart';

import 'support/model/demo_store.dart';

import 'package:encrypted_photo_shared/model/library_query.dart';

import 'support/model/library_store.dart';

import 'package:encrypted_photo_shared/model/selection_state.dart';
import 'package:encrypted_photo_shared/services/album_import_tracker.dart';

import 'support/services/media_sync_service.dart';

MediaItem media(
  String id, {
  MediaKind kind = MediaKind.photo,
  bool complete = true,
  String version = '1',
}) => MediaItem(
  id: id,
  kind: kind,
  version: version,
  takenAt: DateTime(2026, 11, 9),
  megabytes: 4,
  pairingIdentifier: kind == MediaKind.livePhoto ? 'pair:$id' : null,
  resources: [
    MediaResource(
      role: kind == MediaKind.video ? ResourceRole.video : ResourceRole.image,
      location: '/test/$id',
      fileName: 'original_$id.${kind == MediaKind.video ? 'mov' : 'jpg'}',
    ),
    if (kind == MediaKind.livePhoto)
      MediaResource(
        role: ResourceRole.pairedVideo,
        location: '/test/$id.mov',
        fileName: 'paired_$id.mov',
        availability: complete
            ? ResourceAvailability.available
            : ResourceAvailability.missing,
      ),
  ],
);

class FixtureLibrary extends LibraryStore {
  @override
  bool canView = true;
  @override
  final List<MediaItem> mediaRecords = [];
}

void main() {
  test(
    'three media kinds count as three projects, retaining exact filenames',
    () {
      final items = MediaKind.values
          .map((kind) => media(kind.name, kind: kind))
          .toList();
      expect(const LibraryQuery().apply(items, []), hasLength(3));
      expect(items.last.resources, hasLength(2));
      expect(items.last.hasCompleteLocalResources, isTrue);
      expect(items.last.fileName, 'original_livePhoto.jpg');
      expect(
        media(
          'broken',
          kind: MediaKind.livePhoto,
          complete: false,
        ).hasCompleteLocalResources,
        isFalse,
      );
    },
  );

  test(
    'missing pairing metadata cannot be inferred from matching filenames',
    () {
      final source = media('live', kind: MediaKind.livePhoto);
      final unpaired = MediaItem(
        id: 'no-pair',
        resources: source.resources,
        kind: MediaKind.livePhoto,
        takenAt: source.takenAt,
        megabytes: 1,
      );
      expect(unpaired.hasCompleteLocalResources, isFalse);
    },
  );

  test('any hidden album excludes all media kinds from aggregate search and favorites', () {
    final store = FixtureLibrary();
    addTearDown(store.dispose);
    store.mediaRecords.addAll(
      MediaKind.values.map((k) => media(k.name, kind: k)..favorite = true),
    );
    store.albums.addAll([
      Album(
        id: 'ordinary',
        name: '相册',
        members: {'photo', 'video', 'livePhoto'},
      ),
      Album(
        id: 'hidden',
        name: '相册',
        hiddenFromLibrary: true,
        members: {'photo', 'livePhoto'},
      ),
      Album(
        id: 'hidden2',
        name: '相册2',
        hiddenFromLibrary: true,
        members: {'photo'},
      ),
    ]);
    expect(store.query().map((p) => p.id), ['video']);
    expect(
      store.query(const LibraryQuery(favoritesOnly: true)).map((p) => p.id),
      ['video'],
    );
    expect(store.query(const LibraryQuery(search: 'original_photo')), isEmpty);
    expect(store.query(const LibraryQuery(albumId: 'ordinary')), hasLength(3));
    store.setAlbumHidden('hidden', false);
    expect(store.query().map((p) => p.id), containsAll(['video', 'livePhoto']));
    expect(store.query().map((p) => p.id), isNot(contains('photo')));
    store.setAlbumHidden('hidden2', false);
    expect(store.query(), hasLength(3));
    expect(
      store.mediaRecords.every((p) => p.favorite && p.local && !p.remote),
      isTrue,
    );
  });

  test(
    'selection spans complete query and excludes other albums and filters',
    () {
      final items = List.generate(
        120,
        (i) => media('$i', kind: MediaKind.values[i % MediaKind.values.length]),
      );
      final album = Album(
        id: 'scope',
        name: '范围',
        members: {'0', '1', '2', '100', '119'},
      );
      const query = LibraryQuery(albumId: 'scope', search: 'original_1');
      final results = query.apply(items, [album]);
      final selection = SelectionState()
        ..reconcile(query, results)
        ..selectAll(results);
      expect(selection.ids, {'1', '100', '119'});
      expect(selection.active, isTrue);
      selection.reconcile(query, [...results, media('199')]);
      expect(selection.ids, isNot(contains('199')));
      selection.reconcile(const LibraryQuery(search: 'other'), items);
      expect(selection.ids, isEmpty);
      expect(selection.active, isFalse);
      selection.selectAll([]);
      expect(selection.ids, isEmpty);
    },
  );

  test('newly hidden or removed items leave a selection, unselected items stay unchanged', () {
    final store = FixtureLibrary();
    addTearDown(store.dispose);
    store.mediaRecords.addAll([media('a'), media('b'), media('c')]);
    store.albums.add(Album(id: 'a', name: 'A', members: {'a'}));
    final selection = SelectionState()
      ..reconcile(const LibraryQuery(), store.query())
      ..selectAll(store.query());
    store.setAlbumHidden('a', true);
    selection.reconcile(const LibraryQuery(), store.query());
    store.setFavorite(
      store.query().where((p) => selection.ids.contains(p.id)),
      true,
    );
    expect(selection.ids, {'b', 'c'});
    expect(store.mediaRecords.first.favorite, isFalse);
    store.setAlbum(store.mediaRecords.first, 'a', false);
    expect(store.mediaRecords.first.local, isTrue);
    selection.reconcile(const LibraryQuery(), store.query());
    expect(selection.ids, {'b', 'c'});
  });

  test(
    'same-named albums use IDs, App renaming does not mutate source name',
    () {
      final store = FixtureLibrary();
      addTearDown(store.dispose);
      store.albumTracker.reconcile([
        const SystemAlbumSnapshot('source1', '旅行', {'a'}),
        const SystemAlbumSnapshot('source2', '旅行', {'b'}),
      ], complete: true);
      expect(store.albums, hasLength(2));
      expect(store.albums.first.id, isNot(store.albums.last.id));
      store.renameAlbum(store.albums.first.id, '自己的名字');
      expect(store.albumTracker.observations['source1']!.systemName, '旅行');
    },
  );

  test(
    'manual upload only requeues explicitly selected local-only demo items',
    () {
      final store = DemoStore();
      addTearDown(store.dispose);
      final a = store.photos[0], b = store.photos[1];
      store.deletePhoto(a, DeleteScope.repository);
      store.deletePhoto(b, DeleteScope.repository);
      expect(
        store.requestUpload([a]).single.disposition,
        UploadDisposition.queued,
      );
      expect(a.remote, isFalse);
      expect(b.stage, SyncStage.localOnly);
      store.tick();
      final stage = a.stage;
      expect(
        store.requestUpload([a]).single.disposition,
        UploadDisposition.existing,
      );
      expect(a.stage, stage);
      for (var i = 0; i < 30; i++) {
        store.tick();
      }
      expect(a.remote, isTrue);
      expect(b.remote, isFalse);
    },
  );

  test('requests deduplicate by target and media version and reject incomplete resources', () {
    final planner = UploadPlanner();
    final item = media('a');
    expect(
      planner.request(item, 'github:one').disposition,
      UploadDisposition.queued,
    );
    expect(
      planner.request(item, 'github:one').disposition,
      UploadDisposition.existing,
    );
    expect(
      planner.request(item, 'gitee:one').disposition,
      UploadDisposition.queued,
    );
    expect(
      planner.request(media('a', version: '2'), 'github:one').disposition,
      UploadDisposition.queued,
    );
    final broken = media('b', kind: MediaKind.livePhoto, complete: false);
    expect(
      planner.request(broken, 'github:one').disposition,
      UploadDisposition.unavailable,
    );
    item
      ..remote = true
      ..stage = SyncStage.complete
      ..syncedTarget = 'github:one'
      ..syncedVersion = '1';
    expect(
      planner.request(item, 'github:one').disposition,
      UploadDisposition.synced,
    );
    expect(
      planner.request(item, 'github:two').disposition,
      UploadDisposition.queued,
    );
  });

  test('manual upload honors verification pause and repository switch', () {
    final store = DemoStore();
    addTearDown(store.dispose);
    final item = store.photos.first;
    expect(
      store.requestUpload([item]).single.disposition,
      UploadDisposition.synced,
    );
    store.deletePhoto(item, DeleteScope.repository);
    store.togglePause();
    expect(
      store.requestUpload([item]).single.disposition,
      UploadDisposition.blocked,
    );
    expect(item.stage, SyncStage.localOnly);
    store.expireVerification();
    store.verifyPhotoPassword(DemoStore.defaultPassword);
    expect(
      store.requestUpload([item]).single.disposition,
      UploadDisposition.blocked,
    );
    store.togglePause();
    store.requestUpload([item]);
    store.connectRepository(RepositoryProvider.gitee, 'new-target');
    expect(item.remote, isFalse);
    expect(item.stage, SyncStage.queued);
    expect(
      store.requestUpload([item]).single.disposition,
      UploadDisposition.existing,
    );
  });

  test('demo reset rejects foreign resource operations and preserves separate library', () {
    final store = DemoStore();
    final library = FixtureLibrary();
    addTearDown(store.dispose);
    addTearDown(library.dispose);
    final item = media('real');
    library.mediaRecords.add(item);
    library.createAlbum('真实分类');
    store.reset();
    expect(library.mediaRecords.single, same(item));
    expect(library.albums.single.name, '真实分类');
    expect(store.exportDemo(item), isFalse);
    expect(store.deletePhoto(item, DeleteScope.everywhere), isNotNull);
    expect(
      store.requestUpload([item]).single.disposition,
      UploadDisposition.blocked,
    );
    expect(item.local, isTrue);
  });
}
