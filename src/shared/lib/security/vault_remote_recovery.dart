part of 'vault_credentials.dart';

extension VaultRemoteRecovery on VaultCredentials {
  /// Authenticate the current repository password and rewrap this device's own
  /// catalog. The remote master must actually unwrap the existing catalog key;
  /// a matching public vault ID alone is never sufficient.
  Future<VaultCredentialSession> adoptRepositoryPassword({
    required Uint8List recovery,
    required String password,
    required Uint8List expectedVaultId,
  }) async {
    if (_busy) throw const SecurityFailure(SecurityFailureCode.busy);
    _busy = true;
    revoke();
    final revision = _generation;
    SecureKey? passwordKey, wrapper, master, catalog, catalogWrapper;
    Uint8List? encoded;
    VaultCredentialSession? opened;
    try {
      final remote = VaultRecoveryRecord.parse(recovery);
      final crypto = await VaultCrypto.load();
      final prior = await _store.read();
      _requireCurrent(revision);
      if (!crypto.sameBytes(remote.vaultId, expectedVaultId) ||
          !crypto.sameBytes(prior.vaultId, expectedVaultId)) {
        throw const SecurityFailure(SecurityFailureCode.identityMismatch);
      }
      encoded = PhotoPassword.encode(password);
      passwordKey = crypto.protect(encoded);
      encoded.fillRange(0, encoded.length, 0);
      encoded = null;
      wrapper = await crypto.deriveWrappingKey(passwordKey, remote.salt);
      _requireCurrent(revision);
      master = crypto.unwrap(
        wrapped: remote.wrappedMaster,
        wrappingKey: wrapper,
        nonce: remote.nonce,
        aad: remote.aad,
      );
      catalogWrapper = crypto.catalogWrappingKey(master);
      catalog = crypto.unwrap(
        wrapped: prior.wrappedCatalog,
        wrappingKey: catalogWrapper,
        nonce: prior.catalogNonce,
        aad: prior.catalogAad(),
      );
      wrapper.dispose();
      wrapper = null;
      var next = prior.nextPasswordHeader(crypto);
      wrapper = await crypto.deriveWrappingKey(passwordKey, next.salt);
      passwordKey.dispose();
      passwordKey = null;
      _requireCurrent(revision);
      next = next.withMaster(
        crypto.wrap(
          material: master,
          wrappingKey: wrapper,
          nonce: next.masterNonce,
          aad: next.masterAad(),
        ),
      );
      next = next.withCatalog(
        crypto.wrap(
          material: catalog,
          wrappingKey: catalogWrapper,
          nonce: next.catalogNonce,
          aad: next.catalogAad(),
        ),
      );
      final replacement = next, newWrapper = wrapper;
      await _store.replaceAuthenticated(
        expected: prior,
        replacement: replacement,
        authenticate: (candidate) {
          _requireCurrent(revision);
          if (!crypto.sameBytes(candidate.toBytes(), replacement.toBytes())) {
            throw const SecurityFailure(
              SecurityFailureCode.authenticationFailed,
            );
          }
          VaultCredentials._authenticate(crypto, candidate, newWrapper).close();
        },
        requireCurrent: () => _requireCurrent(revision),
      );
      _requireCurrent(revision);
      opened = VaultCredentials._authenticate(crypto, replacement, wrapper);
      _session = opened;
      final result = opened;
      opened = null;
      return result;
    } finally {
      encoded?.fillRange(0, encoded.length, 0);
      passwordKey?.dispose();
      wrapper?.dispose();
      master?.dispose();
      catalog?.dispose();
      catalogWrapper?.dispose();
      opened?.close();
      _busy = false;
    }
  }

  /// Restore into a new local credential store only. This does not grant App
  /// access: callers must still establish PIN, deadline and encrypted catalog.
  Future<VaultCredentialSession> restoreFromRepository({
    required Uint8List recovery,
    required String password,
    required Uint8List expectedVaultId,
  }) async {
    if (_busy) throw const SecurityFailure(SecurityFailureCode.busy);
    _busy = true;
    revoke();
    final revision = _generation;
    SecureKey? passwordKey;
    SecureKey? wrapper;
    SecureKey? master;
    SecureKey? catalog;
    SecureKey? catalogWrapper;
    Uint8List? encoded;
    VaultCredentialSession? opened;
    try {
      final remote = VaultRecoveryRecord.parse(recovery);
      final crypto = await VaultCrypto.load();
      _requireCurrent(revision);
      if (!crypto.sameBytes(remote.vaultId, expectedVaultId)) {
        throw const SecurityFailure(SecurityFailureCode.identityMismatch);
      }
      await _store.requireAbsent();
      _requireCurrent(revision);
      encoded = PhotoPassword.encode(password);
      passwordKey = crypto.protect(encoded);
      encoded.fillRange(0, encoded.length, 0);
      encoded = null;
      wrapper = await crypto.deriveWrappingKey(passwordKey, remote.salt);
      _requireCurrent(revision);
      master = crypto.unwrap(
        wrapped: remote.wrappedMaster,
        wrappingKey: wrapper,
        nonce: remote.nonce,
        aad: remote.aad,
      );
      wrapper.dispose();
      wrapper = null;
      var local = VaultBootstrapRecord.recoveryHeader(
        crypto,
        remote.vaultId,
        remote.generation,
      );
      wrapper = await crypto.deriveWrappingKey(passwordKey, local.salt);
      passwordKey.dispose();
      passwordKey = null;
      _requireCurrent(revision);
      local = local.withMaster(
        crypto.wrap(
          material: master,
          wrappingKey: wrapper,
          nonce: local.masterNonce,
          aad: local.masterAad(),
        ),
      );
      catalog = crypto.randomKey();
      catalogWrapper = crypto.catalogWrappingKey(master);
      local = local.withCatalog(
        crypto.wrap(
          material: catalog,
          wrappingKey: catalogWrapper,
          nonce: local.catalogNonce,
          aad: local.catalogAad(),
        ),
      );
      _requireCurrent(revision);
      await _store.create(local);
      _requireCurrent(revision);
      final persisted = await _store.read();
      _requireCurrent(revision);
      if (!crypto.sameBytes(local.toBytes(), persisted.toBytes())) {
        throw const SecurityFailure(SecurityFailureCode.authenticationFailed);
      }
      opened = VaultCredentials._authenticate(crypto, persisted, wrapper);
      _requireCurrent(revision);
      _session = opened;
      final result = opened;
      opened = null;
      return result;
    } on SecurityFailure {
      rethrow;
    } catch (_) {
      throw const SecurityFailure(SecurityFailureCode.backendFailure);
    } finally {
      encoded?.fillRange(0, encoded.length, 0);
      passwordKey?.dispose();
      wrapper?.dispose();
      master?.dispose();
      catalog?.dispose();
      catalogWrapper?.dispose();
      opened?.close();
      _busy = false;
    }
  }
}
