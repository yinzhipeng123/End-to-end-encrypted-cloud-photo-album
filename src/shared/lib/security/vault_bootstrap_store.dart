import 'dart:io';
import 'dart:typed_data';

import 'package:encrypted_photo_shared/security/security_failure.dart';
import 'package:encrypted_photo_shared/security/vault_bootstrap_record.dart';

/// Owns a single local bootstrap path in an existing application directory.
/// Creation never overwrites. Approved password changes use a separately
/// verified atomic replacement, never truncate-in-place or automatic repair.
final class VaultBootstrapStore {
  const VaultBootstrapStore(this.file, {this.commitReplacement});

  final File file;
  final void Function(String source, String destination)? commitReplacement;

  Future<void> replaceAuthenticated({
    required VaultBootstrapRecord expected,
    required VaultBootstrapRecord replacement,
    required void Function(VaultBootstrapRecord) authenticate,
    required void Function() requireCurrent,
  }) async {
    final commit = commitReplacement;
    if (commit == null)
      throw const SecurityFailure(SecurityFailureCode.backendUnavailable);
    RandomAccessFile? lock;
    File? temporary;
    try {
      lock = await File('${file.path}.update-lock').open(mode: FileMode.append);
      await lock.lock(FileLock.exclusive);
      requireCurrent();
      if (!_equal((await read()).toBytes(), expected.toBytes())) {
        throw const SecurityFailure(SecurityFailureCode.identityMismatch);
      }
      final suffix = replacement.masterNonce
          .map((v) => v.toRadixString(16).padLeft(2, '0'))
          .join();
      temporary = File('${file.path}.$suffix.pending');
      final candidate = VaultBootstrapStore(temporary);
      await candidate.create(replacement);
      final checked = await candidate.read();
      authenticate(checked);
      requireCurrent();
      if (!_equal((await read()).toBytes(), expected.toBytes())) {
        throw const SecurityFailure(SecurityFailureCode.identityMismatch);
      }
      requireCurrent();
      commit(temporary.path, file.path);
      temporary = null;
      authenticate(await read());
      requireCurrent();
    } on SecurityFailure {
      rethrow;
    } on FileSystemException {
      throw const SecurityFailure(SecurityFailureCode.storageFailure);
    } finally {
      await lock?.close();
      if (temporary != null) {
        try {
          await temporary.delete();
        } catch (_) {
          /* Encrypted candidate only. */
        }
      }
    }
  }

  bool _equal(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a[i] ^ b[i];
    }
    return difference == 0;
  }

  Future<void> requireAbsent() async {
    try {
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const SecurityFailure(SecurityFailureCode.alreadyExists);
      }
    } on FileSystemException {
      throw const SecurityFailure(SecurityFailureCode.storageFailure);
    }
  }

  Future<VaultBootstrapRecord> read() async {
    try {
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        throw const SecurityFailure(SecurityFailureCode.notFound);
      }
      if (type != FileSystemEntityType.file) {
        throw const SecurityFailure(SecurityFailureCode.storageFailure);
      }
      final handle = await file.open();
      try {
        final length = await handle.length();
        if (length < VaultBootstrapRecord.byteLength) {
          throw const SecurityFailure(SecurityFailureCode.incompleteMaterial);
        }
        if (length != VaultBootstrapRecord.byteLength) {
          throw const SecurityFailure(SecurityFailureCode.invalidLength);
        }
        // Read at most the fixed format size plus one byte; never readAsBytes.
        final bytes = Uint8List(VaultBootstrapRecord.byteLength + 1);
        var read = 0;
        while (read < bytes.length) {
          final count = await handle.readInto(bytes, read);
          if (count == 0) break;
          read += count;
        }
        return VaultBootstrapRecord.parse(
          Uint8List.sublistView(bytes, 0, read),
        );
      } finally {
        await handle.close();
      }
    } on FileSystemException {
      throw const SecurityFailure(SecurityFailureCode.storageFailure);
    }
  }

  Future<void> create(VaultBootstrapRecord record) async {
    // Validate even internal input before touching the filesystem.
    final bytes = VaultBootstrapRecord.parse(record.toBytes()).toBytes();
    try {
      // The OS, not a preceding exists() check, arbitrates concurrent creators.
      await file.create(exclusive: true);
    } on FileSystemException {
      await requireAbsent(); // Distinguish existing material without its path.
      throw const SecurityFailure(SecurityFailureCode.storageFailure);
    }
    try {
      // Append mode cannot truncate a file if another writer changed it.
      final handle = await file.open(mode: FileMode.writeOnlyAppend);
      try {
        await handle.lock(FileLock.exclusive);
        if (await handle.length() != 0) {
          throw const SecurityFailure(SecurityFailureCode.alreadyExists);
        }
        await handle.writeFrom(bytes);
        await handle.flush();
      } finally {
        // Closing releases the file lock, including on write/flush failure.
        await handle.close();
      }
    } on FileSystemException {
      // Leave incomplete material intact. No automatic retry by overwriting it.
      throw const SecurityFailure(SecurityFailureCode.storageFailure);
    }
  }
}
