import 'dart:io';
import 'dart:typed_data';

import 'package:encrypted_photo_shared/security/vault_crypto.dart';
import 'package:encrypted_photo_app/security/windows_data_protection.dart';
import 'package:encrypted_photo_app/storage/library_catalog.dart';
import 'package:encrypted_photo_shared/sync/sync_format.dart';

/// Bounded ciphertext-only demand cache. References and access times are kept
/// in SQLCipher; filenames are ciphertext digests, never media fingerprints.
final class SyncCipherCache {
  SyncCipherCache(
    Directory data,
    this.catalog,
    this.crypto,
    this.check, {
    this.budget = 512 * 1024 * 1024,
  }) : directory = Directory('${data.path}/sync-cache') {
    _platform.validatePrivatePath(data.path, directory: true);
    _platform.preparePrivateDirectory(directory.path);
  }
  final Directory directory;
  final LibraryCatalog Function() catalog;
  final VaultCrypto crypto;
  final void Function() check;
  final int budget;
  final _platform = WindowsDataProtection();
  bool _reconciled = false;

  File _file(String digest) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) SyncFormat.invalid();
    check();
    _platform.validatePrivatePath(directory.path, directory: true);
    return File('${directory.path}/$digest.bin');
  }

  Future<void> _reconcile() async {
    if (_reconciled) return;
    await for (final entry in directory.list(followLinks: false)) {
      check();
      final name = entry.uri.pathSegments.last;
      if (entry is! File ||
          !RegExp(r'^[a-f0-9]{64}\.bin(\.part)?$').hasMatch(name)) {
        SyncFormat.invalid();
      }
      _platform.validatePrivatePath(entry.path);
      if (name.endsWith('.part') ||
          catalog().record(
                'replicas',
                'cipher-cache:${name.substring(0, 64)}',
              ) ==
              null) {
        await entry.delete();
      }
    }
    _reconciled = true;
  }

  Future<Uint8List?> read(Map<String, Object?> ref) async {
    await _reconcile();
    final digest = ref['digest'] as String;
    final size = SyncFormat.count(
      ref['length'],
      minimum: 48,
      maximum: SyncFormat.chunkBytes + SyncFormat.overhead,
    );
    final file = _file(digest);
    if (!await file.exists()) return null;
    _platform.validatePrivatePath(file.path);
    final handle = await file.open();
    Uint8List? result;
    try {
      if (await handle.length() == size) result = await handle.read(size + 1);
    } finally {
      await handle.close();
    }
    check();
    if (result == null ||
        result.length != size ||
        await SyncFormat.digest(crypto, result) != digest) {
      check();
      await file.delete();
      catalog().deleteRecordPrefix('replicas', 'cipher-cache:$digest');
      return null;
    }
    check();
    catalog().putRecord('replicas', 'cipher-cache:$digest', {
      'digest': digest,
      'size': size,
      'usedAt': DateTime.now().microsecondsSinceEpoch,
    });
    return result;
  }

  Future<void> write(Map<String, Object?> ref, Uint8List ciphertext) async {
    await _reconcile();
    check();
    final digest = ref['digest'] as String;
    if (ciphertext.length != SyncFormat.count(ref['length']) ||
        ciphertext.length > SyncFormat.chunkBytes + SyncFormat.overhead ||
        await SyncFormat.digest(crypto, ciphertext) != digest)
      SyncFormat.invalid();
    if (ciphertext.length > budget) return;
    final file = _file(digest);
    if (await file.exists()) return;
    while (catalog().cipherCacheBytes + ciphertext.length > budget) {
      final oldest = catalog().oldestCipherCache;
      if (oldest == null) SyncFormat.invalid();
      final victim = _file(oldest['digest'] as String);
      if (await victim.exists()) {
        _platform.validatePrivatePath(victim.path);
        await victim.delete();
      }
      check();
      catalog().deleteRecordPrefix(
        'replicas',
        'cipher-cache:${oldest['digest']}',
      );
    }
    if (_platform.availableDiskBytes(directory.path) <
        ciphertext.length + 256 * 1024 * 1024) {
      throw const SyncFailure(SyncFailureCode.space);
    }
    final partial = File('${file.path}.part');
    if (await partial.exists()) {
      _platform.validatePrivatePath(partial.path);
      await partial.delete();
    }
    await partial.create(exclusive: true);
    _platform.validatePrivatePath(partial.path);
    final handle = await partial.open(mode: FileMode.writeOnly);
    try {
      check();
      await handle.writeFrom(ciphertext);
      await handle.flush();
    } finally {
      await handle.close();
    }
    check();
    await partial.rename(file.path);
    check();
    catalog().putRecord('replicas', 'cipher-cache:$digest', {
      'digest': digest,
      'size': ciphertext.length,
      'usedAt': DateTime.now().microsecondsSinceEpoch,
    });
  }
}
