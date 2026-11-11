import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium_sumo.dart';

import 'package:encrypted_photo_shared/security/photo_password.dart';
import 'package:encrypted_photo_shared/security/protected_record_store.dart';
import 'package:encrypted_photo_shared/security/security_failure.dart';
import 'package:encrypted_photo_shared/security/vault_bootstrap_record.dart';
import 'package:encrypted_photo_shared/security/vault_bootstrap_store.dart';
import 'package:encrypted_photo_shared/security/vault_crypto.dart';
import 'package:encrypted_photo_shared/security/vault_recovery_record.dart';

part 'vault_media_crypto.dart';
part 'vault_remote_recovery.dart';

/// An authenticated key session, NOT App access authorization or a PIN bypass.
/// Platform protection, retry state and App wiring follow in tasks 1.4–2.5.
final class VaultCredentialSession {
  VaultCredentialSession._(
    this._record,
    this._master,
    this._catalog,
    this._crypto, {
    bool photoAuthenticated = true,
  }) : _photoAuthenticated = photoAuthenticated;

  final VaultBootstrapRecord _record;
  final SecureKey _master;
  final SecureKey _catalog;
  final VaultCrypto _crypto;
  final bool _photoAuthenticated;
  bool _photoProofConsumed = false;
  final Set<VaultResourceSession> _resources = {};
  final Set<void Function()> _closeListeners = {};
  bool _closed = false;

  Uint8List get vaultId => _record.vaultId;
  Uint8List get catalogId => _record.catalogId;
  int get generation => _record.generation;
  bool get isClosed => _closed;
  bool get authenticatedByPhotoPassword => !_closed && _photoAuthenticated;

  Uint8List recoveryMaterial() {
    _requireOpen();
    return VaultRecoveryRecord.fromBootstrap(_record).toBytes();
  }

  void consumePhotoAuthenticationProof() {
    _requireOpen();
    if (!_photoAuthenticated || _photoProofConsumed) {
      throw const SecurityFailure(SecurityFailureCode.photoPasswordRequired);
    }
    _photoProofConsumed = true;
  }

  /// Trusted storage adapter only: synchronous connection setup; the temporary
  /// key copy is wiped on return and must never be retained or logged.
  void configureCatalogConnection(void Function(Uint8List key) configure) {
    _requireOpen();
    _catalog.runUnlockedSync((bytes) {
      final copy = Uint8List.fromList(bytes);
      try {
        configure(copy);
      } finally {
        copy.fillRange(0, copy.length, 0);
      }
    });
    _requireOpen();
  }

  void Function() onClose(void Function() listener) {
    _requireOpen();
    _closeListeners.add(listener);
    return () => _closeListeners.remove(listener);
  }

  Future<void> saveAuxiliary(
    ProtectedRecordStore store,
    Uint8List binding,
  ) async {
    _requireOpen();
    if (!_photoAuthenticated)
      throw const SecurityFailure(SecurityFailureCode.photoPasswordRequired);
    final clear = Uint8List(
      VaultBootstrapRecord.byteLength + VaultCrypto.keyBytes,
    )..setRange(0, VaultBootstrapRecord.byteLength, _record.toBytes());
    try {
      _master.runUnlockedSync(
        (key) =>
            clear.setRange(VaultBootstrapRecord.byteLength, clear.length, key),
      );
      await store.write('auxiliary', clear, binding);
      _requireOpen();
    } finally {
      clear.fillRange(0, clear.length, 0);
    }
  }

  void _requireOpen() {
    if (_closed) throw const SecurityFailure(SecurityFailureCode.cancelled);
  }

  VaultResourceSession createResource(Uint8List context) {
    _requireOpen();
    final aad = _mediaAad('resource-key', vaultId, [context]);
    final key = _crypto.randomKey();
    SecureKey? wrapper;
    try {
      wrapper = _crypto.purposeKey(_master, 1);
      final nonce = _crypto.randomBytes(VaultCrypto.nonceBytes);
      final envelope = VaultCiphertext(
        nonce: nonce,
        ciphertext: _crypto.wrap(
          material: key,
          wrappingKey: wrapper,
          nonce: nonce,
          aad: aad,
        ),
      );
      final resource = VaultResourceSession._(this, key, context, envelope);
      _resources.add(resource);
      return resource;
    } catch (_) {
      key.dispose();
      rethrow;
    } finally {
      wrapper?.dispose();
    }
  }

  VaultResourceSession openResource(
    Uint8List context,
    VaultCiphertext envelope,
  ) {
    _requireOpen();
    final aad = _mediaAad('resource-key', vaultId, [context]);
    final wrapper = _crypto.purposeKey(_master, 1);
    try {
      final key = _crypto.unwrap(
        wrapped: envelope._ciphertext,
        wrappingKey: wrapper,
        nonce: envelope._nonce,
        aad: aad,
      );
      final resource = VaultResourceSession._(this, key, context, envelope);
      _resources.add(resource);
      return resource;
    } finally {
      wrapper.dispose();
    }
  }

  VaultCiphertext encryptRecoveryMetadata(Uint8List clear, Uint8List context) {
    _requireOpen();
    final aad = _mediaAad('recovery-metadata', vaultId, [context]);
    final key = _crypto.purposeKey(_master, 2);
    try {
      final nonce = _crypto.randomBytes(VaultCrypto.nonceBytes);
      return VaultCiphertext(
        nonce: nonce,
        ciphertext: _crypto.encrypt(
          clear: clear,
          key: key,
          nonce: nonce,
          aad: aad,
        ),
      );
    } finally {
      key.dispose();
    }
  }

  Uint8List decryptRecoveryMetadata(
    VaultCiphertext encrypted,
    Uint8List context,
  ) {
    _requireOpen();
    final aad = _mediaAad('recovery-metadata', vaultId, [context]);
    final key = _crypto.purposeKey(_master, 2);
    try {
      return _crypto.decrypt(
        cipher: encrypted._ciphertext,
        key: key,
        nonce: encrypted._nonce,
        aad: aad,
      );
    } finally {
      key.dispose();
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final listener in _closeListeners.toList()) {
      try {
        listener();
      } catch (_) {
        /* Continue revoking every key/handle. */
      }
    }
    _closeListeners.clear();
    for (final resource in _resources.toList()) {
      resource.close();
    }
    _master.dispose();
    _catalog.dispose();
  }
}

/// Local first-credential creation and authenticated reopening only.
final class VaultCredentials {
  VaultCredentials(this._store);

  final VaultBootstrapStore _store;
  bool _busy = false;
  int _generation = 0;
  VaultCredentialSession? _session;

  /// Immediately invalidates handles and any pending operation's late result.
  /// An in-flight native KDF finishes but its result will be destroyed.
  void revoke() {
    _generation++;
    _session?.close();
    _session = null;
  }

  Future<VaultCredentialSession> initialize({
    required String password,
    required String confirmation,
  }) => _run(password, confirmation: confirmation, create: true);

  Future<VaultCredentialSession> unlock({
    required String password,
    required Uint8List expectedVaultId,
  }) => _run(password, create: false, expectedVaultId: expectedVaultId);

  Future<VaultCredentialSession> changePassword({
    required String oldPassword,
    required String newPassword,
    required String confirmation,
    required Uint8List expectedVaultId,
  }) => _run(
    oldPassword,
    create: false,
    expectedVaultId: expectedVaultId,
    newPassword: newPassword,
    newConfirmation: confirmation,
  );

  /// Called only after PIN and deadline checks by the access coordinator.
  Future<VaultCredentialSession> unlockWithAuxiliary({
    required ProtectedRecordStore store,
    required Uint8List binding,
    required Uint8List expectedVaultId,
  }) async {
    if (_busy) throw const SecurityFailure(SecurityFailureCode.busy);
    _busy = true;
    revoke();
    final revision = _generation;
    Uint8List? clear;
    SecureKey? master;
    SecureKey? catalog;
    SecureKey? wrapper;
    try {
      final crypto = await VaultCrypto.load();
      clear = await store.read('auxiliary', binding);
      _requireCurrent(revision);
      if (clear == null ||
          clear.length !=
              VaultBootstrapRecord.byteLength + VaultCrypto.keyBytes) {
        throw const SecurityFailure(SecurityFailureCode.photoPasswordRequired);
      }
      final record = await _store.read();
      _requireCurrent(revision);
      if (!crypto.sameBytes(record.vaultId, expectedVaultId) ||
          !crypto.sameBytes(
            record.toBytes(),
            Uint8List.sublistView(clear, 0, VaultBootstrapRecord.byteLength),
          )) {
        throw const SecurityFailure(SecurityFailureCode.identityMismatch);
      }
      master = crypto.protect(
        Uint8List.sublistView(clear, VaultBootstrapRecord.byteLength),
      );
      wrapper = crypto.catalogWrappingKey(master);
      catalog = crypto.unwrap(
        wrapped: record.wrappedCatalog,
        wrappingKey: wrapper,
        nonce: record.catalogNonce,
        aad: record.catalogAad(),
      );
      _requireCurrent(revision);
      final opened = VaultCredentialSession._(
        record,
        master,
        catalog,
        crypto,
        photoAuthenticated: false,
      );
      master = null;
      catalog = null;
      _session = opened;
      return opened;
    } on SecurityFailure {
      rethrow;
    } catch (_) {
      throw const SecurityFailure(SecurityFailureCode.backendFailure);
    } finally {
      clear?.fillRange(0, clear.length, 0);
      master?.dispose();
      catalog?.dispose();
      wrapper?.dispose();
      _busy = false;
    }
  }

  Future<VaultCredentialSession> _run(
    String password, {
    String? confirmation,
    required bool create,
    Uint8List? expectedVaultId,
    String? newPassword,
    String? newConfirmation,
  }) async {
    if (_busy) throw const SecurityFailure(SecurityFailureCode.busy);
    _busy = true;
    revoke();
    final operationGeneration = _generation;
    SecureKey? passwordKey;
    SecureKey? wrappingKey;
    VaultCredentialSession? opened;
    Uint8List? encoded;
    try {
      final expected = expectedVaultId == null
          ? null
          : Uint8List.fromList(expectedVaultId);
      if (!create && expected?.length != 16) {
        throw const SecurityFailure(SecurityFailureCode.invalidLength);
      }
      encoded = PhotoPassword.encode(password, confirmation: confirmation);
      final crypto = await VaultCrypto.load();
      _requireCurrent(operationGeneration);
      passwordKey = crypto.protect(encoded);
      encoded.fillRange(0, encoded.length, 0);
      encoded = null;

      VaultBootstrapRecord record;
      if (create) {
        await _store.requireAbsent();
        record = VaultBootstrapRecord.newHeader(crypto);
      } else {
        record = await _store.read();
        if (!crypto.sameBytes(record.vaultId, expected!)) {
          throw const SecurityFailure(SecurityFailureCode.identityMismatch);
        }
      }
      _requireCurrent(operationGeneration);
      wrappingKey = await crypto.deriveWrappingKey(passwordKey, record.salt);
      passwordKey.dispose();
      passwordKey = null;
      _requireCurrent(operationGeneration);

      if (create) {
        record = _makeRecord(crypto, record, wrappingKey);
        _requireCurrent(operationGeneration);
        await _store.create(record);
        _requireCurrent(operationGeneration);
        final persisted = await _store.read();
        if (!crypto.sameBytes(record.toBytes(), persisted.toBytes())) {
          throw const SecurityFailure(SecurityFailureCode.authenticationFailed);
        }
        record = persisted;
      }
      _requireCurrent(operationGeneration);
      // Both wraps are actually authenticated after persistence, before success.
      opened = _authenticate(crypto, record, wrappingKey);
      _requireCurrent(operationGeneration);
      if (newPassword != null) {
        encoded = PhotoPassword.encode(
          newPassword,
          confirmation: newConfirmation,
        );
        passwordKey = crypto.protect(encoded);
        encoded.fillRange(0, encoded.length, 0);
        encoded = null;
        wrappingKey.dispose();
        wrappingKey = null;
        var next = record.nextPasswordHeader(crypto);
        wrappingKey = await crypto.deriveWrappingKey(passwordKey, next.salt);
        passwordKey.dispose();
        passwordKey = null;
        _requireCurrent(operationGeneration);
        next = next.withMaster(
          crypto.wrap(
            material: opened._master,
            wrappingKey: wrappingKey,
            nonce: next.masterNonce,
            aad: next.masterAad(),
          ),
        );
        final catalogWrapper = crypto.catalogWrappingKey(opened._master);
        try {
          next = next.withCatalog(
            crypto.wrap(
              material: opened._catalog,
              wrappingKey: catalogWrapper,
              nonce: next.catalogNonce,
              aad: next.catalogAad(),
            ),
          );
        } finally {
          catalogWrapper.dispose();
        }
        final newWrapper = wrappingKey;
        await _store.replaceAuthenticated(
          expected: record,
          replacement: next,
          authenticate: (candidate) {
            _requireCurrent(operationGeneration);
            if (!crypto.sameBytes(candidate.toBytes(), next.toBytes())) {
              throw const SecurityFailure(
                SecurityFailureCode.authenticationFailed,
              );
            }
            _authenticate(crypto, candidate, newWrapper).close();
          },
          requireCurrent: () => _requireCurrent(operationGeneration),
        );
        _requireCurrent(operationGeneration);
        opened.close();
        opened = _authenticate(crypto, next, wrappingKey);
      }
      _session = opened;
      final result = opened;
      opened = null; // Ownership transfers only after all gates succeed.
      return result;
    } on SecurityFailure {
      rethrow;
    } catch (_) {
      throw const SecurityFailure(SecurityFailureCode.backendFailure);
    } finally {
      encoded?.fillRange(0, encoded.length, 0);
      passwordKey?.dispose();
      wrappingKey?.dispose();
      opened?.close();
      _busy = false;
    }
  }

  void _requireCurrent(int generation) {
    if (generation != _generation) {
      throw const SecurityFailure(SecurityFailureCode.cancelled);
    }
  }

  static VaultBootstrapRecord _makeRecord(
    VaultCrypto crypto,
    VaultBootstrapRecord record,
    SecureKey wrappingKey,
  ) {
    final master = crypto.randomKey();
    SecureKey? catalog;
    SecureKey? catalogWrapper;
    try {
      catalog = crypto.randomKey();
      record = record.withMaster(
        crypto.wrap(
          material: master,
          wrappingKey: wrappingKey,
          nonce: record.masterNonce,
          aad: record.masterAad(),
        ),
      );
      catalogWrapper = crypto.catalogWrappingKey(master);
      return record.withCatalog(
        crypto.wrap(
          material: catalog,
          wrappingKey: catalogWrapper,
          nonce: record.catalogNonce,
          aad: record.catalogAad(),
        ),
      );
    } finally {
      master.dispose();
      catalog?.dispose();
      catalogWrapper?.dispose();
    }
  }

  static VaultCredentialSession _authenticate(
    VaultCrypto crypto,
    VaultBootstrapRecord record,
    SecureKey wrappingKey,
  ) {
    SecureKey? master;
    SecureKey? catalog;
    SecureKey? catalogWrapper;
    try {
      master = crypto.unwrap(
        wrapped: record.wrappedMaster,
        wrappingKey: wrappingKey,
        nonce: record.masterNonce,
        aad: record.masterAad(),
      );
      catalogWrapper = crypto.catalogWrappingKey(master);
      catalog = crypto.unwrap(
        wrapped: record.wrappedCatalog,
        wrappingKey: catalogWrapper,
        nonce: record.catalogNonce,
        aad: record.catalogAad(),
      );
      final session = VaultCredentialSession._(record, master, catalog, crypto);
      master = null;
      catalog = null;
      return session;
    } finally {
      catalogWrapper?.dispose();
      master?.dispose();
      catalog?.dispose();
    }
  }
}
