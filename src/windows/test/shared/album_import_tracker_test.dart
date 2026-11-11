import 'package:flutter_test/flutter_test.dart';
import 'package:encrypted_photo_shared/model/album.dart';
import 'package:encrypted_photo_shared/model/album_source_binding.dart';
import 'package:encrypted_photo_shared/services/album_import_tracker.dart';

void main() {
  late List<Album> albums;
  late AlbumImportTracker tracker;
  setUp(() {
    albums = [];
    tracker = AlbumImportTracker(albums);
  });
  void scan(String name, Set<String> members) => tracker.reconcile([
    SystemAlbumSnapshot('source', name, members),
  ], complete: true);

  test('repeat snapshots are idempotent; different source IDs with same name stay independent', () {
    scan('旅行', {'a'});
    scan('旅行', {'a'});
    expect(albums, hasLength(1));
    tracker.reconcile([
      const SystemAlbumSnapshot('source', '旅行', {'a'}),
      const SystemAlbumSnapshot('another', '旅行', {'a'}),
    ], complete: true);
    expect(albums, hasLength(2));
  });
  test('system deltas merge while preserving App additions and removals', () {
    scan('旅行', {'a', 'b'});
    final id = albums.single.id;
    tracker.setMember(id, 'a', false);
    tracker.setMember(id, 'c', true);
    tracker.setMember(id, 'b', true);
    scan('旅行', {'a', 'd'});
    expect(albums.single.members, {'b', 'c', 'd'});
    scan('旅行', {'d'});
    scan('旅行', {'a', 'd'});
    expect(albums.single.members, {'b', 'c', 'd'});
    tracker.setMember(id, 'a', true);
    expect(albums.single.members, {'a', 'b', 'c', 'd'});
    tracker.setMember(id, 'c', false);
    expect(albums.single.members, {'a', 'b', 'd'});
  });
  test('system rename freezes old effective members and creates new generation exactly once', () {
    scan('旅行', {'a', 'b'});
    final old = albums.single;
    tracker.setMember(old.id, 'a', false);
    tracker.setMember(old.id, 'c', true);
    old.name = '我的独立名称';
    scan('旅行', {'a', 'b'});
    expect(albums, hasLength(1));
    scan('假期', {'a', 'd'});
    scan('假期', {'a', 'd'});
    expect(albums, hasLength(2));
    expect(old.name, '我的独立名称');
    expect(old.members, {'b', 'c'});
    expect(albums.last.name, '假期');
    expect(albums.last.members, {'a', 'd'});
    scan('假期', {'d'});
    expect(old.members, {'b', 'c'});
    scan('旅行', {'e'});
    expect(albums, hasLength(3));
    expect(tracker.observations['source']!.generation, 3);
  });
  test('confirmed system deletion preserves album and members without applying empty membership', () {
    scan('旅行', {'a', 'b'});
    tracker.setMember(albums.single.id, 'c', true);
    tracker.reconcile([], complete: true);
    expect(albums.single.members, {'a', 'b', 'c'});
    expect(tracker.bindings.single.status, AlbumBindingStatus.detached);
  });
  test('App deletion stops unchanged source; later rename auto imports without resurrection', () {
    scan('旅行', {'a'});
    final id = albums.single.id;
    tracker.deleteAlbum(id);
    scan('旅行', {'a', 'b'});
    expect(albums, isEmpty);
    expect(tracker.bindings.single.status, AlbumBindingStatus.stopped);
    scan('假期', {'a', 'b'});
    scan('假期', {'a', 'b'});
    expect(albums.single.name, '假期');
    expect(albums.single.id, isNot(id));
    expect(tracker.bindings.first.status, AlbumBindingStatus.stopped);
  });
  test(
    'manual reimport restores stopped source; active reimport is idempotent',
    () {
      scan('旅行', {'a'});
      tracker.deleteAlbum(albums.single.id);
      const source = SystemAlbumSnapshot('source', '旅行', {'a', 'b'});
      final id = tracker.importManually(source);
      expect(albums.single.members, {'a', 'b'});
      expect(tracker.importManually(source), id);
      expect(albums, hasLength(1));
    },
  );
  test(
    'incomplete snapshots do not infer deletion, rename or membership removals',
    () {
      scan('旅行', {'a'});
      tracker.reconcile([], complete: false);
      tracker.reconcile([
        const SystemAlbumSnapshot('source', '假期', {}),
      ], complete: false);
      expect(albums.single.name, '旅行');
      expect(albums.single.members, {'a'});
      expect(tracker.activeFor('source'), isNotNull);
    },
  );
}
