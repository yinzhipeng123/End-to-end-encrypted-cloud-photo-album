import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:encrypted_photo_app/repositories/github_connection.dart';
import 'package:encrypted_photo_shared/security/pin_gate.dart';
import 'package:encrypted_photo_shared/security/reverification_gate.dart';
import 'package:encrypted_photo_shared/security/vault_bootstrap_store.dart';
import 'package:encrypted_photo_shared/security/vault_credentials.dart';
import 'package:encrypted_photo_shared/security/vault_crypto.dart';
import 'package:encrypted_photo_shared/security/vault_recovery_record.dart';
import 'package:encrypted_photo_app/security/windows_data_protection.dart';
import 'package:encrypted_photo_app/security/windows_protected_store.dart';
import 'package:encrypted_photo_app/security/windows_security_clock.dart';
import 'package:encrypted_photo_app/storage/library_catalog.dart';
import 'package:encrypted_photo_app/sync/github_sync_repository.dart';
import 'package:encrypted_photo_shared/sync/sync_format.dart';
import 'package:encrypted_photo_app/sync/sync_object_store.dart';

final class RepositoryRecoveryPreview {
  const RepositoryRecoveryPreview(
    this.repositoryId,
    this.repositoryName,
    this.vaultId,
    this.digest,
  );
  final int repositoryId;
  final String repositoryName, vaultId, digest;
}

abstract final class RepositoryVaultRecovery {
  static Future<({String commit, Uint8List bytes})> _material(
    GitHubGitAccess access,
  ) async {
    await access.verifyTarget();
    final head = await access.head();
    if (head == null) throw const SyncFailure(SyncFailureCode.notInitialized);
    final sha = await access.fileSha(
      head,
      '${SyncFormat.directory}/recovery.bin',
    );
    if (sha == null) throw const SyncFailure(SyncFailureCode.notInitialized);
    return (
      commit: head,
      bytes: await access.blob(sha, maximum: VaultRecoveryRecord.byteLength),
    );
  }

  static Future<RepositoryRecoveryPreview> inspect(
    GitHubGitAccess access,
  ) async {
    final material = await _material(access);
    final record = VaultRecoveryRecord.parse(material.bytes);
    final crypto = await VaultCrypto.load();
    access.operation.check();
    return RepositoryRecoveryPreview(
      access.target.id,
      access.target.fullName,
      SyncFormat.hex(record.vaultId),
      await SyncFormat.digest(crypto, material.bytes),
    );
  }

  /// New directory only: remote wrapping + user password create independent
  /// catalog, PIN, installation binding and DPAPI material. No sender DB,
  /// cached plaintext, auxiliary keys or OAuth credentials are copied.
  static Future<void> install({
    required GitHubGitAccess access,
    required RepositoryRecoveryPreview expected,
    required Directory destination,
    required String password,
    required String pin,
    required void Function() check,
  }) async {
    check();
    PinGate.validate(pin);
    final material = await _material(access);
    final remote = VaultRecoveryRecord.parse(material.bytes);
    final crypto = await VaultCrypto.load();
    check();
    if (access.target.id != expected.repositoryId ||
        SyncFormat.hex(remote.vaultId) != expected.vaultId ||
        await SyncFormat.digest(crypto, material.bytes) != expected.digest) {
      throw const SyncFailure(SyncFailureCode.conflict);
    }
    final platform = WindowsDataProtection();
    platform.validateLocalDirectoryChain(destination.parent.path);
    platform.preparePrivateDirectory(destination.path, requireNew: true);
    final credentials = VaultCredentials(
      VaultBootstrapStore(
        File('${destination.path}/vault.bootstrap'),
        commitReplacement: platform.replacePrivateFile,
      ),
    );
    LibraryCatalog? catalog;
    try {
      final session = await credentials.restoreFromRepository(
        recovery: material.bytes,
        password: password,
        expectedVaultId: remote.vaultId,
      );
      check();
      catalog = LibraryCatalog.create(
        File('${destination.path}/catalog.db'),
        session,
      );
      final target = 'github:${access.target.id}:${expected.vaultId}';
      catalog.putRecord('preferences', 'sync:$target', {
        'recoveryDigest': expected.digest,
        'localGeneration': session.generation,
      });
      final repository = GitHubSyncRepository(
        access: access,
        catalog: () => catalog!,
        session: session,
        objects: SyncObjectStore(destination, check),
        crypto: crypto,
        checkAccess: check,
      );
      final snapshot = await repository.snapshot();
      if (snapshot == null)
        throw const SyncFailure(SyncFailureCode.notInitialized);
      await repository.refreshMediaCatalog(snapshot);
      check();
      catalog.putRecord('preferences', 'recovery-origin', {
        'repositoryId': expected.repositoryId,
        'repositoryName': expected.repositoryName,
        'vaultId': expected.vaultId,
        'commit': snapshot.commit,
      });
      catalog.verifyIntegrity();
      final protected = WindowsProtectedStore(destination, platform);
      await protected.initialize();
      final installation = crypto.randomBytes(32);
      await protected.write(
        'installation',
        installation,
        Uint8List.fromList(ascii.encode('EPA/installation/v1')),
      );
      check();
      final gate = ReverificationGate(
        store: protected,
        credentials: credentials,
        pinGate: PinGate(protected, installation),
        clock: WindowsSecurityClock(platform),
        binding: installation,
        vaultId: session.vaultId,
        wrappingGeneration: session.generation,
      );
      await gate.pinGate.configure(pin);
      check();
      await gate.recordPhotoAuthentication(session);
      check();
      gate.lock();
    } finally {
      catalog?.close();
      credentials.revoke();
      // Wrong password creates no bootstrap: remove only this empty directory.
      // Any interrupted encrypted materials are retained for inspection.
      if (!await File('${destination.path}/vault.bootstrap').exists() &&
          await destination.list(followLinks: false).isEmpty) {
        platform.validatePrivatePath(destination.path, directory: true);
        await destination.delete();
      }
    }
  }
}
