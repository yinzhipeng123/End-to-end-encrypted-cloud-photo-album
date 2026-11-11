import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:encrypted_photo_shared/security/security_failure.dart';
import 'package:encrypted_photo_app/security/windows_data_protection.dart';
import 'package:encrypted_photo_app/security/windows_protected_store.dart';

/// The startup locator is available before photo-password authentication, so it
/// uses the approved user-scope DPAPI store, never a plaintext path preference.
final class VaultLocationStore {
  VaultLocationStore(this.defaultDirectory);

  final Directory defaultDirectory;
  final _platform = WindowsDataProtection();
  late final _store = WindowsProtectedStore(defaultDirectory, _platform);
  static final _binding = Uint8List.fromList(
    ascii.encode('EPA/data-location/v1'),
  );
  RandomAccessFile? _lock;

  Future<Directory> open() async {
    await _store.initialize();
    final file = File('${defaultDirectory.path}/location.lock');
    _lock = await file.open(mode: FileMode.append);
    _platform.validatePrivatePath(file.path);
    try {
      await _lock!.lock(FileLock.exclusive);
    } catch (_) {
      await close();
      throw const SecurityFailure(SecurityFailureCode.busy);
    }
    final locatorType = FileSystemEntity.typeSync(
      '${defaultDirectory.path}/data-location.sealed',
      followLinks: false,
    );
    if (locatorType != FileSystemEntityType.file &&
        locatorType != FileSystemEntityType.notFound) {
      throw const SecurityFailure(SecurityFailureCode.storageFailure);
    }
    final bytes = await _store.read('data-location', _binding);
    if (bytes == null) return defaultDirectory;
    try {
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map ||
          value['version'] != 1 ||
          value['directory'] is! String) {
        throw const SecurityFailure(SecurityFailureCode.unsupportedFormat);
      }
      final path = value['directory'] as String;
      _platform.validateLocalDirectoryChain(path);
      _platform.validatePrivatePath(path, directory: true);
      // A recorded location denotes an initialization attempt, not permission
      // to create a replacement vault if its disk or files disappear.
      for (final name in ['vault.bootstrap', 'catalog.db']) {
        _platform.validatePrivatePath('$path/$name');
      }
      return Directory(path);
    } on SecurityFailure {
      rethrow;
    } catch (_) {
      throw const SecurityFailure(SecurityFailureCode.storageFailure);
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  Directory candidate(String parent) {
    _platform.validateLocalDirectoryChain(parent);
    final target = Directory(
      Directory('$parent/EncryptedPhotoApp').absolute.uri
          .normalizePath()
          .toFilePath(),
    );
    if (sameDirectory(target, defaultDirectory)) return defaultDirectory;
    if (FileSystemEntity.typeSync(target.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const SecurityFailure(SecurityFailureCode.alreadyExists);
    }
    return target;
  }

  void prepareNew(Directory directory) {
    _platform.validateLocalDirectoryChain(directory.parent.path);
    if (FileSystemEntity.typeSync(directory.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const SecurityFailure(SecurityFailureCode.alreadyExists);
    }
    _platform.preparePrivateDirectory(directory.path, requireNew: true);
  }

  Future<void> save(Directory directory) async {
    if (_lock == null) {
      throw const SecurityFailure(SecurityFailureCode.accessDenied);
    }
    final bytes = Uint8List.fromList(
      utf8.encode(jsonEncode({'version': 1, 'directory': directory.path})),
    );
    try {
      await _store.write('data-location', bytes, _binding);
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  static bool sameDirectory(Directory first, Directory second) =>
      first.absolute.uri.normalizePath().toString().toLowerCase() ==
      second.absolute.uri.normalizePath().toString().toLowerCase();

  Future<void> close() async {
    final handle = _lock;
    _lock = null;
    await handle?.close();
  }
}
