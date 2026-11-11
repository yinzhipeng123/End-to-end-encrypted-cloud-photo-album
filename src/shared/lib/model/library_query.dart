import 'package:encrypted_photo_shared/model/album.dart';
import 'package:encrypted_photo_shared/model/media_item.dart';

enum LibraryFilter { all, synced, pending, localOnly, remoteOnly }

class LibraryQuery {
  const LibraryQuery({
    this.albumId,
    this.favoritesOnly = false,
    this.search = '',
    this.filter = LibraryFilter.all,
  });

  final String? albumId;
  final bool favoritesOnly;
  final String search;
  final LibraryFilter filter;

  List<MediaItem> apply(Iterable<MediaItem> items, Iterable<Album> albums) {
    final albumMap = {for (final album in albums) album.id: album};
    final hidden = <String>{
      for (final album in albums.where((a) => a.hiddenFromLibrary))
        ...album.members,
    };
    final term = search.trim().toLowerCase();
    return items.where((item) {
      if (!item.visible) return false;
      if (albumId != null) {
        if (!(albumMap[albumId]?.members.contains(item.id) ?? false))
          return false;
      } else if (hidden.contains(item.id)) {
        return false;
      }
      if (favoritesOnly && !item.favorite) return false;
      if (term.isNotEmpty &&
          !item.resources.any((r) => r.fileName.toLowerCase().contains(term))) {
        return false;
      }
      return switch (filter) {
        LibraryFilter.all => true,
        LibraryFilter.synced => item.remote,
        LibraryFilter.pending => item.pending,
        LibraryFilter.localOnly => item.local && !item.remote,
        LibraryFilter.remoteOnly => !item.local && item.remote,
      };
    }).toList()..sort((a, b) => b.takenAt.compareTo(a.takenAt));
  }

  @override
  bool operator ==(Object other) =>
      other is LibraryQuery &&
      albumId == other.albumId &&
      favoritesOnly == other.favoritesOnly &&
      search == other.search &&
      filter == other.filter;
  @override
  int get hashCode => Object.hash(albumId, favoritesOnly, search, filter);
}
