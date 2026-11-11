import 'dart:async';
import 'dart:io';

import '../services/windows_folder_importer.dart';
import 'library_store.dart';

import 'package:encrypted_photo_shared/model/media_item.dart';

/// 等待加密目录设计的内存来源适配；不保存文件名、路径、索引或凭据。
class LocalPreviewLibrary extends LibraryStore {
  @override
  bool get canView => true;
  final Map<String, MediaItem> _items = {};
  @override
  List<MediaItem> get mediaRecords => List.unmodifiable(_items.values);
  final Set<String> folders = {};
  final Map<String, Set<String>> _knownByFolder = {};
  final Map<String, StreamSubscription<FileSystemEvent>> _watchers = {};
  final WindowsFolderImporter importer = WindowsFolderImporter();
  final bool Function() mayScan;
  Timer? _periodic;
  Timer? _debounce;
  bool _disposed = false;
  bool _scanning = false;
  bool _again = false;
  String? issue;
  bool get scanning => _scanning;

  LocalPreviewLibrary({required this.mayScan});

  Future<void> addFolder(String path) async {
    if (_disposed || !mayScan()) return;
    final canonical = await Directory(path).resolveSymbolicLinks();
    if (_disposed || !mayScan()) return;
    folders.add(canonical);
    try {
      _watchers.putIfAbsent(
        canonical,
        () =>
            Directory(canonical)
                .watch(recursive: true)
                .listen((_) => _schedule(), onError: (Object _) => _schedule()),
      );
    } on FileSystemException {
      // 事件监听不可用时，运行期定时核对仍补偿遗漏。
    }
    _periodic ??= Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(rescan()),
    );
    await rescan();
  }

  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 900),
      () => unawaited(rescan()),
    );
  }

  Future<void> rescan() async {
    if (_disposed || !mayScan()) return;
    if (_scanning) {
      _again = true;
      return;
    }
    _scanning = true;
    notifyListeners();
    final problems = <String>{};
    try {
      for (final folder in folders.toList()) {
        final result = await importer.scan(folder);
        if (_disposed || !mayScan()) return;
        if (result.issue != null) problems.add(result.issue!);
        for (final entry in result.files.entries) {
          final previous = _items[entry.key];
          if (previous == null) {
            _items[entry.key] = entry.value;
          } else if (previous.version != entry.value.version) {
            entry.value.favorite = previous.favorite;
            _items[entry.key] = entry.value;
          } else {
            previous.local = true;
            previous.sourceMissing = false;
          }
        }
        final known = _knownByFolder.putIfAbsent(folder, () => {});
        if (result.complete) {
          for (final key in known.difference(result.files.keys.toSet())) {
            final item = _items[key];
            if (item != null) {
              item.local = false;
              item.sourceMissing = true;
            }
          }
        }
        known.addAll(result.files.keys);
      }
      issue = problems.isEmpty ? null : problems.join('；');
    } finally {
      _scanning = false;
      if (!_disposed) {
        notifyListeners();
        if (_again) {
          _again = false;
          _schedule();
        }
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _periodic?.cancel();
    _debounce?.cancel();
    for (final watcher in _watchers.values) {
      unawaited(watcher.cancel());
    }
    super.dispose();
  }
}
