import 'package:flutter/foundation.dart';

import 'package:encrypted_photo_shared/model/library_query.dart';
import 'package:encrypted_photo_shared/model/selection_state.dart';
import 'package:encrypted_photo_shared/security/vault_crypto.dart';
import 'package:encrypted_photo_app/storage/library_catalog.dart';
import 'package:encrypted_photo_app/services/import/windows_import_service.dart';

/// Real local organization for one unlocked lifetime. No file or repository
/// mutation is available through this service. Selection is only in memory.
final class LibraryOrganizationService extends ChangeNotifier {
  static const availableFilters = {
    LibraryFilter.all,
    LibraryFilter.pending,
    LibraryFilter.localOnly,
    LibraryFilter.synced,
    LibraryFilter.remoteOnly,
  };
  LibraryOrganizationService(
    this.imports, {
    this.additionalChanges,
    this.viewCatalog,
  }) {
    imports.addListener(_changed);
    additionalChanges?.addListener(_changed);
  }
  final Listenable? additionalChanges;
  final WindowsImportService imports;
  final LibraryCatalog Function()? viewCatalog;
  final selection = SelectionState();
  LibraryQuery _query = const LibraryQuery();
  bool _disposed = false;
  LibraryQuery get query => _query;
  LibraryCatalog get catalog {
    if (_disposed) throw const CatalogFailure(CatalogFailureCode.closed);
    return viewCatalog?.call() ?? imports.catalog();
  }

  List<Map<String, Object?>> get albums => catalog.albums();
  int get count => catalog.queryCount(_query);
  int countFor(LibraryQuery query) => catalog.queryCount(query);
  List<Map<String, Object?>> page(int index) =>
      catalog.queryMedia(_query, page: index);

  void setQuery(LibraryQuery query) {
    catalog;
    if (!availableFilters.contains(query.filter))
      throw const CatalogFailure(CatalogFailureCode.invalidRecord);
    if (_query == query) return;
    _query = query;
    selection.clear();
    _changed();
  }

  void _reconcile() {
    selection.reconcileIds(
      _query,
      selection.ids.isEmpty
          ? const <String>[]
          : catalog.queryIds(_query, within: selection.ids),
    );
  }

  void _changed() {
    if (_disposed) return;
    _reconcile();
    notifyListeners();
  }

  void refresh() => _changed();

  void beginSelection() {
    _reconcile();
    selection.active = true;
    notifyListeners();
  }

  void toggle(String id) {
    _reconcile();
    if (catalog.queryIds(_query, within: [id]).isNotEmpty) selection.toggle(id);
    notifyListeners();
  }

  void selectAll() {
    _reconcile();
    selection.selectAllIds(catalog.queryIds(_query));
    notifyListeners();
  }

  void clearSelection({bool exit = true}) {
    selection.clear(exit: exit);
    notifyListeners();
  }

  Future<String> createAlbum(String name) async {
    catalog;
    if (name.trim().isEmpty)
      throw const CatalogFailure(CatalogFailureCode.invalidRecord);
    final crypto = await VaultCrypto.load();
    final id = crypto
        .randomBytes(16)
        .map((v) => v.toRadixString(16).padLeft(2, '0'))
        .join();
    catalog.transaction(() {
      if (catalog.albumById(id) != null)
        throw const CatalogFailure(CatalogFailureCode.alreadyExists);
      catalog.putAlbum(
        id: id,
        name: name.trim(),
        hidden: false,
        members: const [],
      );
    });
    _changed();
    return id;
  }

  void renameAlbum(String id, String name) {
    catalog.renameAlbum(id, name);
    _changed();
  }

  void setHidden(String id, bool hidden) {
    catalog.setAlbumHidden(id, hidden);
    _changed();
  }

  void deleteAlbum(String id) {
    catalog.transaction(() {
      if (catalog.albumById(id) == null)
        throw const CatalogFailure(CatalogFailureCode.missing);
      catalog.deleteAlbum(id);
    });
    if (_query.albumId == id) {
      _query = const LibraryQuery();
      selection.clear();
    }
    _changed();
  }

  int organize(
    Iterable<String> ids, {
    bool? favorite,
    String? albumId,
    bool remove = false,
  }) {
    // A dialog may have stayed open while visibility changed. SQL revalidates
    // the frozen IDs against the current scope inside the writing transaction.
    final count = catalog.organize(
      _query,
      ids,
      favorite: favorite,
      albumId: albumId,
      remove: remove,
    );
    _changed();
    return count;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    imports.removeListener(_changed);
    additionalChanges?.removeListener(_changed);
    selection.clear();
    super.dispose();
  }
}
