import 'dart:typed_data';

import 'package:sodium/sodium_sumo.dart';

import 'package:encrypted_photo_shared/security/security_failure.dart';

/// The approved backend only. No software fallback or adjustable KDF cost.
final class VaultCrypto {
  VaultCrypto._(this._sodium);

  static const memoryBytes = 67108864;
  static const operations = 3;
  static const keyBytes = 32;
  static const saltBytes = 16;
  static const nonceBytes = 24;
  static const wrappedKeyBytes = 48;
  static Future<VaultCrypto>? _instance;
  // All service instances in the application isolate share this admission gate.
  static bool _deriving = false;
  final SodiumSumo _sodium;

  static Future<VaultCrypto> load() => _instance ??= _load();

  static Future<VaultCrypto> _load() async {
    try {
      final sodium = await SodiumSumoInit.init();
      final aead = sodium.crypto.aeadXChaCha20Poly1305IETF;
      if (sodium.version.toString() != '1.0.22' ||
          aead.keyBytes != keyBytes ||
          aead.nonceBytes != nonceBytes ||
          aead.aBytes != 16 ||
          sodium.crypto.pwhash.saltBytes != saltBytes ||
          sodium.crypto.kdf.contextBytes != 8) {
        throw const SecurityFailure(SecurityFailureCode.backendUnavailable);
      }
      return VaultCrypto._(sodium);
    } catch (_) {
      throw const SecurityFailure(SecurityFailureCode.backendUnavailable);
    }
  }

  String get nativeVersion => _sodium.version.toString();
  bool get isDeriving => _deriving;

  SecureKey randomKey() => _sodium.secureRandom(keyBytes);
  Uint8List randomBytes(int length) => _sodium.randombytes.buf(length);
  // WIR-1 TD11-W: local content version only, never a key or public identifier.
  GenericHashConsumer contentHasher() =>
      _sodium.crypto.genericHash.createConsumer(outLen: 32);
  SecureKey protect(Uint8List bytes) => _sodium.secureCopy(bytes);

  /// The caller owns [password] and the returned key; neither is cached here.
  Future<SecureKey> deriveWrappingKey(
    SecureKey password,
    Uint8List salt,
  ) async {
    if (salt.length != saltBytes ||
        password.length == 0 ||
        password.length > 512) {
      throw const SecurityFailure(SecurityFailureCode.invalidLength);
    }
    if (_deriving) throw const SecurityFailure(SecurityFailureCode.busy);
    _deriving = true;
    try {
      // The callback captures only a public salt, never the caller's key/string.
      return await _sodium.runIsolated(
        _deriveInWorker(Uint8List.fromList(salt)),
        secureKeys: [password],
      );
    } catch (error) {
      if (error is SecurityFailure) rethrow;
      throw const SecurityFailure(SecurityFailureCode.backendFailure);
    } finally {
      _deriving = false;
    }
  }

  SecureKey catalogWrappingKey(SecureKey masterKey) => purposeKey(masterKey, 3);

  SecureKey purposeKey(SecureKey masterKey, int purpose) {
    if (masterKey.length != keyBytes || purpose < 1 || purpose > 3) {
      throw const SecurityFailure(SecurityFailureCode.invalidLength);
    }
    return _sodium.crypto.kdf.deriveFromKey(
      masterKey: masterKey,
      context: 'EPAKDF01',
      subkeyId: BigInt.from(purpose),
      subkeyLen: keyBytes,
    );
  }

  Uint8List encrypt({
    required Uint8List clear,
    required SecureKey key,
    required Uint8List nonce,
    required Uint8List aad,
  }) {
    _checkAead(key, nonce);
    try {
      return _sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(
        message: clear,
        nonce: nonce,
        key: key,
        additionalData: aad,
      );
    } on SodiumException {
      throw const SecurityFailure(SecurityFailureCode.backendFailure);
    }
  }

  Uint8List decrypt({
    required Uint8List cipher,
    required SecureKey key,
    required Uint8List nonce,
    required Uint8List aad,
  }) {
    _checkAead(key, nonce);
    if (cipher.length < 16) {
      throw const SecurityFailure(SecurityFailureCode.invalidLength);
    }
    try {
      return _sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
        cipherText: cipher,
        nonce: nonce,
        key: key,
        additionalData: aad,
      );
    } on SodiumException {
      throw const SecurityFailure(SecurityFailureCode.authenticationFailed);
    }
  }

  void _checkAead(SecureKey key, Uint8List nonce) {
    if (key.length != keyBytes || nonce.length != nonceBytes) {
      throw const SecurityFailure(SecurityFailureCode.invalidLength);
    }
  }

  Uint8List wrap({
    required SecureKey material,
    required SecureKey wrappingKey,
    required Uint8List nonce,
    required Uint8List aad,
  }) {
    if (material.length != keyBytes ||
        wrappingKey.length != keyBytes ||
        nonce.length != nonceBytes) {
      throw const SecurityFailure(SecurityFailureCode.invalidLength);
    }
    return material.runUnlockedSync(
      (bytes) => _sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(
        message: bytes,
        nonce: nonce,
        key: wrappingKey,
        additionalData: aad,
      ),
    );
  }

  SecureKey unwrap({
    required Uint8List wrapped,
    required SecureKey wrappingKey,
    required Uint8List nonce,
    required Uint8List aad,
  }) {
    if (wrapped.length != wrappedKeyBytes ||
        nonce.length != nonceBytes ||
        wrappingKey.length != keyBytes) {
      throw const SecurityFailure(SecurityFailureCode.invalidLength);
    }
    Uint8List clear;
    try {
      clear = _sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
        cipherText: wrapped,
        nonce: nonce,
        key: wrappingKey,
        additionalData: aad,
      );
    } on SodiumException {
      throw const SecurityFailure(SecurityFailureCode.authenticationFailed);
    }
    try {
      return _sodium.secureCopy(clear);
    } finally {
      clear.fillRange(0, clear.length, 0);
    }
  }

  bool sameBytes(Uint8List a, Uint8List b) =>
      a.length == b.length && _sodium.memcmp(a, b);

  Uint8List pinTag(SecureKey key, Uint8List message) {
    if (key.length != keyBytes) {
      throw const SecurityFailure(SecurityFailureCode.invalidLength);
    }
    return _sodium.crypto.genericHash(message: message, key: key, outLen: 32);
  }
}

SodiumIsolateCallback<SecureKey> _deriveInWorker(Uint8List salt) =>
    (keys, _) async {
      final sodium = await SodiumSumoInit.init();
      if (sodium.version.toString() != '1.0.22') {
        throw const SecurityFailure(SecurityFailureCode.backendUnavailable);
      }
      // runIsolated releases its transferred password copy in finally.
      return keys.single.runUnlockedSync(
        (bytes) => sodium.crypto.pwhash.callRaw(
          outLen: VaultCrypto.keyBytes,
          password: Int8List.sublistView(bytes),
          salt: salt,
          opsLimit: VaultCrypto.operations,
          memLimit: VaultCrypto.memoryBytes,
          alg: CryptoPwhashAlgorithm.argon2id13,
        ),
      );
    };
