import 'dart:io';
import 'dart:typed_data';

import 'package:encrypted_photo_shared/security/vault_crypto.dart';
import 'package:encrypted_photo_shared/sync/sync_format.dart';
import 'package:encrypted_photo_app/sync/windows_sync_service.dart';
import 'package:encrypted_photo_app/services/library/library_organization_service.dart';
import 'package:encrypted_photo_app/services/import/windows_import_service.dart';
import 'package:encrypted_photo_app/services/import/windows_source_reader.dart';

/// Plaintext is written only into the directory explicitly chosen for export.
/// Each item uses a fresh subdirectory; existing user files are never replaced.
final class WindowsMediaExport {
  WindowsMediaExport(this.imports, this.organization, this.sync);
  final WindowsImportService imports;
  final LibraryOrganizationService organization;
  final WindowsSyncService? sync;

  Future<String> export(
    String id,
    String destination,
    SourceCancellation token,
  ) async {
    final db = organization.catalog;
    final query = organization.query;
    void check() {
      token.check();
      if (organization.query != query ||
          organization.catalog.queryIds(query, within: [id]).isEmpty) {
        throw const SourceFailure(SourceFailureCode.cancelled);
      }
    }

    check();
    final record = db.mediaById(id)!;
    final version = record['version'] as String;
    final crypto = await VaultCrypto.load();
    check();
    final task = SyncFormat.newId(crypto);
    final directory = Directory('$destination/导出-$task');
    final key = 'export:$task';
    final files = <String, _ExportFile>{};
    var complete = false;
    db.putRecord('jobs', key, {
      'mediaId': id,
      'version': version,
      'destination': directory.path,
      'phase': 'preparing',
    });
    try {
      await WindowsSourceReader.withDirectory(destination, token, (_) async {
        check();
        if (await directory.exists())
          throw const SourceFailure(SourceFailureCode.unsafePath);
        await directory.create();
        await WindowsSourceReader.withDirectory(directory.path, token, (
          _,
        ) async {
          Future<void> consume(
            String role,
            String name,
            int size,
            String digest,
            Uint8List bytes,
          ) async {
            check();
            var file = files[role];
            if (file == null) {
              file = await _ExportFile.open(
                directory,
                '$role-${_safeName(name)}',
                size,
                digest,
              );
              files[role] = file;
            } else if (file.expectedSize != size ||
                file.expectedDigest != digest) {
              throw const SourceFailure(SourceFailureCode.changed);
            }
            await file.add(bytes);
            check();
          }

          if (record['local'] == true) {
            if (record['kind'] == 'livePhoto') {
              for (final part
                  in (record['resources'] as List).whereType<Map>()) {
                check();
                final original = db.mediaById(part['sourceMediaId'] as String);
                if (original == null || original['version'] != part['version'])
                  SyncFormat.invalid();
                final fields = (part['version'] as String).split(':');
                if (fields.length != 3 || fields[0] != 'blake2b-256')
                  SyncFormat.invalid();
                await imports.readLocalOriginal(
                  original['id'] as String,
                  part['version'] as String,
                  token,
                  (bytes) => consume(
                    part['role'] as String,
                    original['fileName'] as String,
                    original['size'] as int,
                    fields[2],
                    bytes,
                  ),
                );
              }
            } else {
              final parts = version.split(':');
              if (parts.length != 3 || parts[0] != 'blake2b-256')
                SyncFormat.invalid();
              await imports.readLocalOriginal(
                id,
                version,
                token,
                (bytes) => consume(
                  record['kind'] == 'video' ? 'video' : 'image',
                  record['fileName'] as String,
                  record['size'] as int,
                  parts[2],
                  bytes,
                ),
              );
            }
          } else {
            if (sync == null)
              throw const SourceFailure(SourceFailureCode.unavailable);
            await sync!.readRemoteOriginal(
              id,
              version,
              token,
              (resource, bytes) => consume(
                resource['role'] as String,
                resource['fileName'] is String
                    ? resource['fileName'] as String
                    : resource['role'] == 'pairedVideo'
                    ? '实况动态.mov'
                    : record['fileName'] as String,
                SyncFormat.count(resource['length'], minimum: 1),
                resource['digest'] as String,
                bytes,
              ),
            );
          }
          check();
          if (files.isEmpty)
            throw const SourceFailure(SourceFailureCode.unavailable);
          for (final file in files.values) {
            await file.verify(crypto, check);
          }
          check();
          db.putRecord('jobs', key, {
            'mediaId': id,
            'version': version,
            'destination': directory.path,
            'phase': 'publishing',
          });
          for (final file in files.values) {
            check();
            await file.publish(token);
          }
          check();
          db.putRecord('jobs', key, {
            'mediaId': id,
            'version': version,
            'destination': directory.path,
            'phase': 'complete',
            'files': files.values.map((file) => file.finalFile.path).toList(),
          });
          complete = true;
        });
      });
      return directory.path;
    } finally {
      for (final file in files.values) {
        await file.close();
      }
      if (!complete) {
        // Preserve any already published files after an interrupted multi-part
        // export; only our own unfinished files are cleaned up.
        for (final file in files.values) {
          await file.removePartial();
        }
        try {
          db.putRecord('jobs', key, {
            'mediaId': id,
            'version': version,
            'destination': directory.path,
            'phase': 'incomplete',
            'published': files.values
                .where((f) => f.published)
                .map((f) => f.finalFile.path)
                .toList(),
          });
        } catch (_) {
          /* A locked catalog leaves the durable preparing marker. */
        }
      }
    }
  }

  static String _safeName(String name) {
    var result = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_');
    if (result.length > 160) result = result.substring(result.length - 160);
    result = result.replaceAll(RegExp(r'[. ]+$'), '');
    return result.isEmpty ? 'media' : result;
  }
}

final class _ExportFile {
  _ExportFile(
    this.partial,
    this.finalFile,
    this._handle,
    this.expectedSize,
    this.expectedDigest,
  );
  final File partial, finalFile;
  RandomAccessFile? _handle;
  final int expectedSize;
  final String expectedDigest;
  int _size = 0;
  bool published = false;
  static Future<_ExportFile> open(
    Directory directory,
    String name,
    int size,
    String digest,
  ) async {
    final partial = File('${directory.path}/$name.partial');
    await partial.create(exclusive: true);
    return _ExportFile(
      partial,
      File('${directory.path}/$name'),
      await partial.open(mode: FileMode.writeOnly),
      size,
      digest,
    );
  }

  Future<void> add(Uint8List bytes) async {
    if (_size + bytes.length > expectedSize)
      throw const SourceFailure(SourceFailureCode.changed);
    await _handle!.writeFrom(bytes);
    _size += bytes.length;
  }

  Future<void> verify(VaultCrypto crypto, void Function() check) async {
    await _handle!.flush();
    await close();
    if (_size != expectedSize)
      throw const SourceFailure(SourceFailureCode.changed);
    final input = await partial.open();
    final hash = crypto.contentHasher();
    var closed = false, size = 0;
    try {
      while (true) {
        check();
        final bytes = await input.read(1024 * 1024);
        try {
          if (bytes.isEmpty) break;
          hash.add(bytes);
          size += bytes.length;
        } finally {
          bytes.fillRange(0, bytes.length, 0);
        }
      }
      final digest = SyncFormat.hex(await hash.close());
      closed = true;
      check();
      if (size != expectedSize || digest != expectedDigest)
        throw const SourceFailure(SourceFailureCode.changed);
    } finally {
      await input.close();
      if (!closed) await hash.close();
    }
  }

  Future<void> publish(SourceCancellation token) async {
    // Use the non-replacing native handle rename, not File.rename (which may
    // replace a file created after an existence check). Hold validated content
    // and ancestor handles until publication has completed.
    await WindowsSourceReader().withSnapshot(
      partial.path,
      partial.parent.path,
      token,
      (snapshot) {
        if (snapshot.version != 'blake2b-256:$expectedSize:$expectedDigest') {
          throw const SourceFailure(SourceFailureCode.changed);
        }
      },
      moveTo: finalFile.path,
    );
    published = true;
  }

  Future<void> close() async {
    final handle = _handle;
    _handle = null;
    await handle?.close();
  }

  Future<void> removePartial() async {
    if (published) return;
    try {
      if (await partial.exists()) await partial.delete();
    } catch (_) {}
  }
}
