import 'dart:io';

/// Only acceptance tools import this helper. It never opens the user's vault.
abstract final class ToolPaths {
  static final Directory host = _findHost();

  static Directory _findHost() {
    final explicit = Platform.environment['EPA_WINDOWS_ROOT'];
    final candidates = <Directory>[
      if (explicit != null) Directory(explicit),
      File(Platform.resolvedExecutable).parent,
      if (Platform.script.scheme == 'file')
        File.fromUri(Platform.script).parent,
      Directory.current,
    ];
    for (final candidate in candidates) {
      var cursor = candidate.absolute;
      while (true) {
        final pubspec = File('${cursor.path}/pubspec.yaml');
        if (pubspec.existsSync() &&
            Directory('${cursor.path}/windows').existsSync() &&
            RegExp(
              r'^name:\s*encrypted_photo_app\s*$',
              multiLine: true,
            ).hasMatch(pubspec.readAsStringSync())) {
          _rejectLinks(cursor.path);
          return cursor;
        }
        final parent = cursor.parent;
        if (parent.path == cursor.path) break;
        cursor = parent;
      }
      if (explicit != null && candidate == candidates.first) {
        throw StateError('EPA_WINDOWS_ROOT does not identify the Windows host');
      }
    }
    throw StateError('Run from the Windows host or set EPA_WINDOWS_ROOT');
  }

  static String _normalized(String path) =>
      File(path).absolute.uri.normalizePath().toFilePath();

  static void _rejectLinks(String path) {
    var cursor = Directory(_normalized(path));
    while (true) {
      if (FileSystemEntity.typeSync(cursor.path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw StateError('Redirected acceptance path rejected');
      }
      final parent = cursor.parent;
      if (parent.path == cursor.path) break;
      cursor = parent;
    }
  }

  static String checkedPath(
    String path,
    String boundary, {
    bool allowBoundary = false,
  }) {
    final full = _normalized(path);
    final base = _normalized(boundary);
    final a = Platform.isWindows ? full.toLowerCase() : full;
    final b = Platform.isWindows ? base.toLowerCase() : base;
    if (!(a.startsWith('$b${Platform.pathSeparator}') ||
        (allowBoundary && a == b))) {
      throw StateError('Path is outside the isolated acceptance boundary');
    }
    _rejectLinks(full);
    return full;
  }

  static Directory _local(String kind, String name) {
    final base = '${host.parent.path}/.local/$kind';
    return Directory(checkedPath('$base/$name', base));
  }

  static Directory data(String name) => _local('acceptance', name);
  static Directory reports(String name) => _local('reports', name);
  static Future<Directory> freshData(String scope, String prefix) async {
    final parent = data(scope);
    await parent.create(recursive: true);
    return parent.createTemp(prefix);
  }

  static File reportFile(String scope, String name) {
    final parent = reports(scope);
    parent.createSync(recursive: true);
    return File(checkedPath('${parent.path}/$name', parent.path));
  }

  static File buildFile(String name) =>
      File(checkedPath('${host.path}/build/$name', '${host.path}/build'));
  static File fixture(String name) => File(
    checkedPath(
      '${data('media-fixtures').path}/$name',
      data('media-fixtures').path,
    ),
  );

  static Directory requireData(String path, String scope) =>
      Directory(checkedPath(path, data(scope).path));
}
