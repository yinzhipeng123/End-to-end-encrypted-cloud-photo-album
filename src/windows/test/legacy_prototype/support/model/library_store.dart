import 'package:flutter/foundation.dart';
import 'package:encrypted_photo_shared/model/album.dart';
import 'package:encrypted_photo_shared/model/library_query.dart';
import 'package:encrypted_photo_shared/model/media_item.dart';
import 'package:encrypted_photo_shared/services/album_import_tracker.dart';

/// 与演示密码、同步模拟和平台资源读取无关的整理规则。
abstract class LibraryStore extends ChangeNotifier {
  bool get canView;
  List<MediaItem> get mediaRecords;
  final List<Album> _albums = [];
  List<Album> get albums => _albums;
  late final _albumTracker = AlbumImportTracker(_albums);
  AlbumImportTracker get albumTracker => _albumTracker;
  int _nextAlbum = 1;

  List<MediaItem> get photos =>
      canView ? mediaRecords.where((p) => p.visible).toList() : [];
  List<MediaItem> query([LibraryQuery query = const LibraryQuery()]) =>
      query.apply(photos, albums);
  Album? albumById(String? id) => albums.where((a) => a.id == id).firstOrNull;
  Iterable<Album> albumsFor(MediaItem item) =>
      albums.where((a) => a.members.contains(item.id));
  bool containsItem(MediaItem item) =>
      mediaRecords.any((p) => identical(p, item)) && item.visible;

  void toggleFavorite(MediaItem item) => setFavorite([item], !item.favorite);
  void setFavorite(Iterable<MediaItem> items, bool value) {
    if (!canView) return;
    for (final item in items.where(containsItem)) {
      item.favorite = value;
    }
    notifyListeners();
  }

  bool createAlbum(String name) {
    if (!canView ||
        name.trim().isEmpty ||
        albums.any((a) => a.name == name.trim()))
      return false;
    albums.add(Album(id: 'app:${_nextAlbum++}', name: name.trim()));
    notifyListeners();
    return true;
  }

  bool renameAlbum(String albumId, String name) {
    final album = albumById(albumId);
    if (!canView || album == null || name.trim().isEmpty) return false;
    album.name = name.trim();
    notifyListeners();
    return true;
  }

  void setAlbum(MediaItem item, String albumId, bool included) {
    if (!canView || !containsItem(item) || albumById(albumId) == null) return;
    albumTracker.setMember(albumId, item.id, included);
    notifyListeners();
  }

  void setAlbumHidden(String albumId, bool value) {
    if (!canView) return;
    final album = albumById(albumId);
    if (album == null) return;
    album.hiddenFromLibrary = value;
    notifyListeners();
  }

  void deleteAlbum(String albumId) {
    if (!canView) return;
    albumTracker.deleteAlbum(albumId);
    notifyListeners();
  }
}
