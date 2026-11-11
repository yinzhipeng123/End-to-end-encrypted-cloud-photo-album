import 'dart:io';
import 'dart:typed_data';

import 'package:encrypted_photo_app/security/windows_data_protection.dart';
import 'package:encrypted_photo_shared/sync/sync_format.dart';

/// App-owned ciphertext only; caller checkpoints its random IDs in SQLCipher.
final class SyncObjectStore {
  SyncObjectStore(Directory dataDirectory, this.checkAccess)
    : directory = Directory('${dataDirectory.path}/sync-staging') {
    _platform.validatePrivatePath(dataDirectory.path, directory: true);
    _platform.preparePrivateDirectory(directory.path);
  }
  final Directory directory;
  final void Function() checkAccess;
  final _platform = WindowsDataProtection();
  static const reserveBytes = 256 * 1024 * 1024;
  static const budgetBytes = 512 * 1024 * 1024;

  Directory _task(String taskId) {
    SyncFormat.id(taskId);
    checkAccess();
    _platform.validatePrivatePath(directory.path, directory: true);
    return Directory('${directory.path}/$taskId');
  }

  Future<void> prepare(String taskId, int requiredBytes) async {
    checkAccess();
    var used = 0;
    // Count actual ciphertext, including interrupted .part files. Never follow
    // a reparse point or a path from metadata while accounting for disk usage.
    await for (final task in directory.list(followLinks: false)) {
      checkAccess();
      if (task is! Directory ||
          !RegExp(r'^[a-f0-9]{32}$')
              .hasMatch(task.uri.pathSegments.where((s) => s.isNotEmpty).last))
        SyncFormat.invalid();
      _platform.validatePrivatePath(task.path, directory: true);
      await for (final object in task.list(followLinks: false)) {
        checkAccess();
        if (object is! File) SyncFormat.invalid();
        _platform.validatePrivatePath(object.path);
        used += await object.length();
        if (used > budgetBytes) break;
      }
    }
    if ((requiredBytes > budgetBytes && used != 0) ||
        (requiredBytes <= budgetBytes && used + requiredBytes > budgetBytes)) {
      throw const SyncFailure(SyncFailureCode.space);
    }
    if (requiredBytes < 0 ||
        _platform.availableDiskBytes(directory.path) <
            requiredBytes + reserveBytes) {
      throw const SyncFailure(SyncFailureCode.space);
    }
    _platform.preparePrivateDirectory(_task(taskId).path);
  }

  File file(String taskId, String objectId) {
    SyncFormat.id(objectId);
    final task = _task(taskId);
    _platform.validatePrivatePath(task.path, directory: true);
    return File('${task.path}/$objectId.bin');
  }

  Future<void> write(String taskId, String objectId, Uint8List bytes) async {
    checkAccess();
    if (bytes.isEmpty ||
        bytes.length > SyncFormat.chunkBytes + SyncFormat.overhead)
      SyncFormat.invalid();
    final target = file(taskId, objectId);
    if (await target.exists())
      throw const SyncFailure(SyncFailureCode.conflict);
    if (_platform.availableDiskBytes(directory.path) <
        bytes.length + reserveBytes)
      throw const SyncFailure(SyncFailureCode.space);
    final partial = File('${target.path}.part');
    await partial.create(exclusive: true);
    _platform.validatePrivatePath(partial.path);
    final handle = await partial.open(mode: FileMode.writeOnly);
    try {
      checkAccess();
      await handle.writeFrom(bytes);
      await handle.flush();
      checkAccess();
    } finally {
      await handle.close();
    }
    checkAccess();
    if (await partial.length() != bytes.length)
      throw const SyncFailure(SyncFailureCode.integrity);
    await partial.rename(target.path);
    checkAccess();
    _platform.validatePrivatePath(target.path);
  }

  Future<Uint8List> read(
    String taskId,
    String objectId,
    int expectedLength,
  ) async {
    checkAccess();
    if (expectedLength < 1 ||
        expectedLength > SyncFormat.chunkBytes + SyncFormat.overhead)
      SyncFormat.invalid();
    final source = file(taskId, objectId);
    _platform.validatePrivatePath(source.path);
    final handle = await source.open();
    try {
      if (await handle.length() != expectedLength)
        throw const SyncFailure(SyncFailureCode.integrity);
      final bytes = await handle.read(expectedLength + 1);
      checkAccess();
      if (bytes.length != expectedLength)
        throw const SyncFailure(SyncFailureCode.integrity);
      return bytes;
    } finally {
      await handle.close();
    }
  }

  Future<void> removeTask(String taskId) async {
    final task = _task(taskId); // strict random ID, never a source/user path
    if (!await task.exists()) return;
    _platform.validatePrivatePath(task.path, directory: true);
    // Do not recurse through reparse points or foreign nested directories.
    await for (final entity in task.list(followLinks: false)) {
      checkAccess();
      if (entity is! File ||
          !RegExp(r'^[a-f0-9]{32}\.bin(\.part)?$')
              .hasMatch(entity.uri.pathSegments.last))
        SyncFormat.invalid();
      _platform.validatePrivatePath(entity.path);
      await entity.delete();
    }
    checkAccess();
    await task.delete();
  }
}
