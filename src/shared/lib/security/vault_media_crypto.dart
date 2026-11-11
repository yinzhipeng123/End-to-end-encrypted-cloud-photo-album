part of 'vault_credentials.dart';

/// Authenticated bytes only, not a repository or multi-part file format.
final class VaultCiphertext {
  VaultCiphertext({required Uint8List nonce, required Uint8List ciphertext})
    : _nonce = Uint8List.fromList(nonce),
      _ciphertext = Uint8List.fromList(ciphertext) {
    if (nonce.length != VaultCrypto.nonceBytes || ciphertext.length < 16) {
      throw const SecurityFailure(SecurityFailureCode.invalidLength);
    }
  }

  final Uint8List _nonce;
  final Uint8List _ciphertext;
  Uint8List get nonce => Uint8List.fromList(_nonce);
  Uint8List get ciphertext => Uint8List.fromList(_ciphertext);
}

/// A random key for one caller-defined immutable resource version.
/// The owner closes every child when access is revoked. No key bytes escape.
final class VaultResourceSession {
  VaultResourceSession._(
    this._owner,
    this._key,
    Uint8List context,
    this.envelope,
  ) : _context = Uint8List.fromList(context);

  final VaultCredentialSession _owner;
  final SecureKey _key;
  final Uint8List _context;
  final VaultCiphertext envelope;
  bool _closed = false;

  void _requireOpen() {
    _owner._requireOpen();
    if (_closed) throw const SecurityFailure(SecurityFailureCode.cancelled);
  }

  VaultCiphertext encrypt(Uint8List clear, {required Uint8List unitContext}) {
    _requireOpen();
    final aad = _mediaAad('media-unit', _owner.vaultId, [
      _context,
      unitContext,
    ]);
    final nonce = _owner._crypto.randomBytes(VaultCrypto.nonceBytes);
    return VaultCiphertext(
      nonce: nonce,
      ciphertext: _owner._crypto.encrypt(
        clear: clear,
        key: _key,
        nonce: nonce,
        aad: aad,
      ),
    );
  }

  /// Authenticates the entire supplied unit before releasing any clear bytes.
  /// The later transfer protocol must also authenticate the complete resource.
  Uint8List decrypt(VaultCiphertext cipher, {required Uint8List unitContext}) {
    _requireOpen();
    final aad = _mediaAad('media-unit', _owner.vaultId, [
      _context,
      unitContext,
    ]);
    return _owner._crypto.decrypt(
      cipher: cipher._ciphertext,
      key: _key,
      nonce: cipher._nonce,
      aad: aad,
    );
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _key.dispose();
    _owner._resources.remove(this);
  }
}

Uint8List _mediaAad(
  String purpose,
  Uint8List vaultId,
  List<Uint8List> contexts,
) {
  if (vaultId.length != 16 ||
      contexts.any((part) => part.isEmpty || part.length > 4096)) {
    throw const SecurityFailure(SecurityFailureCode.invalidLength);
  }
  final bytes = BytesBuilder(copy: true)
    ..add(ascii.encode('EPA/$purpose/v1\x00'))
    ..add(vaultId);
  for (final context in contexts) {
    final length = ByteData(4)..setUint32(0, context.length, Endian.little);
    bytes
      ..add(length.buffer.asUint8List())
      ..add(context);
  }
  return bytes.takeBytes();
}
