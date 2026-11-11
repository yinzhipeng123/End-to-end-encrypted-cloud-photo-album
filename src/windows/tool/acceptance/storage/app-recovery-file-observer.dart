// Validation only. Delegates actual filesystem operations unchanged, then lets
// the parent terminate the runner at a selected boundary. Not imported by lib/.
import 'dart:io';
import 'dart:typed_data';

final class RecoveryFileObserver extends IOOverrides {
  RecoveryFileObserver(this.observe);
  final void Function(String path, String operation) observe;

  @override
  File createFile(String path) =>
      _ObservedFile(super.createFile(path), observe);
}

class _ObservedFile implements File {
  _ObservedFile(this.file, this.observe);
  final File file;
  final void Function(String path, String operation) observe;
  @override
  String get path => file.path;
  @override
  Uri get uri => file.uri;
  @override
  Directory get parent => file.parent;
  @override
  File get absolute => _ObservedFile(file.absolute, observe);
  @override
  Future<bool> exists() => file.exists();
  @override
  bool existsSync() => file.existsSync();
  @override
  void createSync({bool recursive = false, bool exclusive = false}) {
    observe(path, 'before-create');
    file.createSync(recursive: recursive, exclusive: exclusive);
    observe(path, 'created');
  }

  @override
  Future<File> create({bool recursive = false, bool exclusive = false}) async {
    observe(path, 'before-create');
    try {
      await file.create(recursive: recursive, exclusive: exclusive);
    } on FileSystemException catch (error) {
      observe(path, 'error-${error.osError?.errorCode}');
      rethrow;
    }
    observe(path, 'created');
    return this;
  }

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async {
    observe(path, mode == FileMode.read ? 'before-read' : 'before-open-write');
    return _ObservedHandle(await file.open(mode: mode), path, observe);
  }

  @override
  Future<Uint8List> readAsBytes() => file.readAsBytes();
  @override
  Uint8List readAsBytesSync() => file.readAsBytesSync();
  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) async {
    try {
      await file.writeAsBytes(bytes, mode: mode, flush: flush);
    } on FileSystemException catch (error) {
      observe(path, 'error-${error.osError?.errorCode}');
      rethrow;
    }
    observe(path, flush ? 'flushed' : 'written');
    return this;
  }

  @override
  Future<File> delete({bool recursive = false}) async {
    await file.delete(recursive: recursive);
    return this;
  }

  @override
  Future<int> length() => file.length();
  @override
  int lengthSync() => file.lengthSync();
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unobserved File operation ${invocation.memberName}',
  );
}

class _ObservedHandle implements RandomAccessFile {
  _ObservedHandle(this.handle, this.path, this.observe);
  final RandomAccessFile handle;
  final String path;
  final void Function(String path, String operation) observe;
  @override
  Future<void> close() => handle.close();
  @override
  Future<int> length() => handle.length();
  @override
  Future<Uint8List> read(int bytes) => handle.read(bytes);
  @override
  Future<int> readInto(List<int> buffer, [int start = 0, int? end]) =>
      handle.readInto(buffer, start, end);
  @override
  Future<RandomAccessFile> lock([
    FileLock mode = FileLock.exclusive,
    int start = 0,
    int end = -1,
  ]) async {
    await handle.lock(mode, start, end);
    return this;
  }

  @override
  Future<RandomAccessFile> writeFrom(
    List<int> buffer, [
    int start = 0,
    int? end,
  ]) async {
    await handle.writeFrom(buffer, start, end);
    return this;
  }

  @override
  Future<RandomAccessFile> flush() async {
    await handle.flush();
    observe(path, 'flushed');
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unobserved RandomAccessFile operation ${invocation.memberName}',
  );
}
