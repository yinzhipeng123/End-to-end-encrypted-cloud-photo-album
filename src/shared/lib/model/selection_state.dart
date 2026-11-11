import 'package:encrypted_photo_shared/model/library_query.dart';
import 'package:encrypted_photo_shared/model/media_item.dart';

/// 全选是当前查询的快照，新发现项目不会自动加入选择。
class SelectionState {
  bool active = false;
  final Set<String> ids = {};
  LibraryQuery? _query;

  void reconcile(LibraryQuery query, Iterable<MediaItem> results) {
    reconcileIds(query, results.map((p) => p.id));
  }

  void reconcileIds(LibraryQuery query, Iterable<String> results) {
    if (_query != query) {
      clear();
      _query = query;
    }
    ids.retainAll(results);
  }

  void toggle(String id) {
    active = true;
    if (!ids.remove(id)) ids.add(id);
  }

  void selectAll(Iterable<MediaItem> results) {
    selectAllIds(results.map((p) => p.id));
  }

  void selectAllIds(Iterable<String> results) {
    active = true;
    ids
      ..clear()
      ..addAll(results);
  }

  void clear({bool exit = true}) {
    ids.clear();
    if (exit) active = false;
  }
}
