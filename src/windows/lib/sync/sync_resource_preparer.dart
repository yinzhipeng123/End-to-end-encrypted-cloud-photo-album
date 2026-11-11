import 'dart:convert';

import 'package:encrypted_photo_shared/security/vault_credentials.dart';
import 'package:encrypted_photo_shared/security/vault_crypto.dart';
import 'package:encrypted_photo_app/services/import/windows_import_service.dart';
import 'package:encrypted_photo_app/services/import/windows_source_reader.dart';
import 'package:encrypted_photo_app/storage/library_catalog.dart';
import 'package:encrypted_photo_shared/sync/sync_format.dart';
import 'package:encrypted_photo_app/sync/sync_object_store.dart';

/// Durable real-source encryption. Half-prepared resources are not publishable.
final class SyncResourcePreparer {
  SyncResourcePreparer({
    required this.catalog,
    required this.session,
    required this.imports,
    required this.objects,
    required this.checkAccess,
    this.onProgress,
  });
  final LibraryCatalog Function() catalog;
  final VaultCredentialSession Function() session;
  final WindowsImportService imports;
  final SyncObjectStore objects;
  final void Function() checkAccess;
  final void Function(int done, int total)? onProgress;
  static String chunkKey(String taskId, int index) =>
      'chunk:$taskId:${index.toString().padLeft(20, '0')}';

  Future<Map<String, Object?>> prepare(
    String taskId,
    Map<String, Object?> media,
    String revisionId,
    SourceCancellation token,
  ) => imports.withContentRead(() async {
    checkAccess();
    token.check();
    final mediaId = media['id'] as String;
    SyncFormat.id(mediaId);
    SyncFormat.id(taskId);
    SyncFormat.id(revisionId);
    if (media['local'] != true || !{'photo', 'video'}.contains(media['kind'])) {
      throw const SyncFailure(SyncFailureCode.sourceChanged);
    }
    final path = media['path'] as String;
    final root = catalog().mediaRoot(
      media['sourceMediaId'] as String? ?? mediaId,
      path,
    );
    if (root == null) throw const SyncFailure(SyncFailureCode.sourceChanged);
    final crypto = await VaultCrypto.load();
    token.check();
    checkAccess();
    final resourceId = SyncFormat.newId(crypto);
    final resource = session().createResource(
      SyncFormat.resourceContext(mediaId, revisionId, resourceId),
    );
    ResourceBlockEncoder? encoder;
    var blockCount = 0;
    try {
      return await WindowsSourceReader().withSnapshot(
        path,
        root,
        token,
        (snapshot) {
          checkAccess();
          token.check();
          encoder!.finish();
          if (snapshot.version != media['version'] ||
              snapshot.size != media['size']) {
            throw const SyncFailure(SyncFailureCode.sourceChanged);
          }
          final descriptor = <String, Object?>{
            'format': '1',
            'mediaId': mediaId,
            'revisionId': revisionId,
            'resourceId': resourceId,
            'role':
                media['role'] ?? (media['kind'] == 'photo' ? 'image' : 'video'),
            'length': '${snapshot.size}',
            'digest': snapshot.fingerprint,
            'blockCount': '$blockCount',
            'keyNonce': base64Encode(resource.envelope.nonce),
            'keyCipher': base64Encode(resource.envelope.ciphertext),
          };
          catalog().putRecord('jobs', 'resource:$taskId', descriptor);
          return descriptor;
        },
        onOpen: (size) async {
          checkAccess();
          token.check();
          if (size != media['size'])
            throw const SyncFailure(SyncFailureCode.sourceChanged);
          final count =
              (size + SyncFormat.chunkBytes - 1) ~/ SyncFormat.chunkBytes;
          await objects.prepare(taskId, size + count * SyncFormat.overhead);
          checkAccess();
          token.check();
          encoder = ResourceBlockEncoder(
            resource: resource,
            totalBytes: size,
            checkAccess: () {
              checkAccess();
              token.check();
            },
            writeBlock: (index, length, cipher) async {
              final objectId = SyncFormat.newId(crypto);
              await objects.write(taskId, objectId, cipher);
              final digest = await SyncFormat.digest(crypto, cipher);
              checkAccess();
              token.check();
              catalog().putRecord('jobs', chunkKey(taskId, index), {
                'objectId': objectId,
                'length': '${cipher.length}',
                'digest': digest,
                'index': '$index',
                'clearLength': '$length',
                'sha': null,
                'verified': false,
              });
              blockCount++;
              onProgress?.call(index * SyncFormat.chunkBytes + length, size);
            },
          );
        },
        onBlock: (bytes) => encoder!.add(bytes),
      );
    } finally {
      encoder?.close();
      resource.close();
    }
  });
}
