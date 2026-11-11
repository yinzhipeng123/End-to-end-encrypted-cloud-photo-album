import 'dart:convert';
import 'dart:typed_data';

import 'package:encrypted_photo_shared/security/security_failure.dart';
import 'package:encrypted_photo_shared/security/vault_crypto.dart';

/// A local key bootstrap, not the remote repository or media storage format.
/// No filenames, paths, album data, password verifier or platform tokens.
final class VaultBootstrapRecord {
  VaultBootstrapRecord._(this._bytes);

  static const byteLength = 228;
  static const headerLength = 132;
  static final _magic = ascii.encode('EPAVLT01');
  final Uint8List _bytes;

  factory VaultBootstrapRecord.newHeader(VaultCrypto crypto) {
    final bytes = Uint8List(byteLength);
    bytes.setRange(0, 8, _magic);
    final data = ByteData.sublistView(bytes);
    data.setUint16(8, 1, Endian.little);
    bytes[10] = 1; // XChaCha20-Poly1305 suite.
    bytes[11] = 1; // Fixed Argon2id parameter set.
    bytes[12] = 0x13;
    bytes[13] = 1; // One lane.
    data.setUint16(14, VaultCrypto.operations, Endian.little);
    data.setUint32(16, VaultCrypto.memoryBytes, Endian.little);
    data.setUint16(20, VaultCrypto.keyBytes, Endian.little);
    data.setUint16(22, VaultCrypto.wrappedKeyBytes, Endian.little);
    data.setUint64(24, 1, Endian.little); // Initial wrapping generation.
    bytes.setRange(32, 48, crypto.randomBytes(16));
    bytes.setRange(48, 64, crypto.randomBytes(16));
    bytes.setRange(64, 80, crypto.randomBytes(16));
    bytes.setRange(80, 104, crypto.randomBytes(24));
    bytes.setRange(104, 128, crypto.randomBytes(24));
    data.setUint32(128, 96, Endian.little);
    return VaultBootstrapRecord._(bytes);
  }

  factory VaultBootstrapRecord.parse(Uint8List input) {
    if (input.length < byteLength) {
      throw const SecurityFailure(SecurityFailureCode.incompleteMaterial);
    }
    if (input.length != byteLength) {
      throw const SecurityFailure(SecurityFailureCode.invalidLength);
    }
    // Snapshot before checking so a caller cannot mutate accepted parameters.
    final bytes = Uint8List.fromList(input);
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i < _magic.length; i++) {
      if (bytes[i] != _magic[i]) {
        throw const SecurityFailure(SecurityFailureCode.unsupportedFormat);
      }
    }
    if (data.getUint16(8, Endian.little) != 1 ||
        bytes[10] != 1 ||
        bytes[11] != 1 ||
        bytes[12] != 0x13 ||
        bytes[13] != 1 ||
        data.getUint16(14, Endian.little) != VaultCrypto.operations ||
        data.getUint32(16, Endian.little) != VaultCrypto.memoryBytes ||
        data.getUint16(20, Endian.little) != VaultCrypto.keyBytes ||
        data.getUint16(22, Endian.little) != VaultCrypto.wrappedKeyBytes ||
        data.getUint64(24, Endian.little) < 1 ||
        data.getUint32(128, Endian.little) != 96) {
      throw const SecurityFailure(SecurityFailureCode.unsupportedFormat);
    }
    return VaultBootstrapRecord._(bytes);
  }

  /// A new local catalog for an authenticated remote vault, never a copy of
  /// another device's catalog key or PIN. Wrappings are filled by credentials.
  factory VaultBootstrapRecord.recoveryHeader(
    VaultCrypto crypto,
    Uint8List vaultId,
    int generation,
  ) {
    if (vaultId.length != 16 ||
        generation < 1 ||
        generation > 0x7fffffffffffffff) {
      throw const SecurityFailure(SecurityFailureCode.invalidLength);
    }
    final fresh = VaultBootstrapRecord.newHeader(crypto);
    fresh._bytes.setRange(32, 48, vaultId);
    ByteData.sublistView(fresh._bytes).setUint64(24, generation, Endian.little);
    return fresh;
  }

  Uint8List get vaultId => _slice(32, 48);
  Uint8List get catalogId => _slice(48, 64);
  Uint8List get salt => _slice(64, 80);
  Uint8List get masterNonce => _slice(80, 104);
  Uint8List get catalogNonce => _slice(104, 128);
  Uint8List get wrappedMaster => _slice(132, 180);
  Uint8List get wrappedCatalog => _slice(180, 228);
  int get generation =>
      ByteData.sublistView(_bytes).getUint64(24, Endian.little);
  Uint8List toBytes() => Uint8List.fromList(_bytes);

  VaultBootstrapRecord nextPasswordHeader(VaultCrypto crypto) {
    if (generation >= 0x7fffffffffffffff) {
      throw const SecurityFailure(SecurityFailureCode.unsupportedFormat);
    }
    final bytes = toBytes();
    ByteData.sublistView(bytes).setUint64(24, generation + 1, Endian.little);
    bytes.setRange(64, 80, crypto.randomBytes(16));
    bytes.setRange(80, 104, crypto.randomBytes(24));
    bytes.setRange(104, 128, crypto.randomBytes(24));
    bytes.fillRange(headerLength, byteLength, 0);
    return VaultBootstrapRecord._(bytes);
  }

  Uint8List _slice(int start, int end) =>
      Uint8List.fromList(_bytes.sublist(start, end));

  Uint8List masterAad() => Uint8List.fromList([
    ...ascii.encode('EPA/bootstrap/master/v1\x00'),
    ..._bytes.take(headerLength),
  ]);

  Uint8List catalogAad() => Uint8List.fromList([
    ...ascii.encode('EPA/bootstrap/catalog/v1\x00'),
    ..._bytes.take(180), // Also binds the exact master wrapping.
  ]);

  VaultBootstrapRecord withMaster(Uint8List ciphertext) =>
      _withWrapped(132, ciphertext);

  VaultBootstrapRecord withCatalog(Uint8List ciphertext) =>
      _withWrapped(180, ciphertext);

  VaultBootstrapRecord _withWrapped(int start, Uint8List ciphertext) {
    if (ciphertext.length != VaultCrypto.wrappedKeyBytes) {
      throw const SecurityFailure(SecurityFailureCode.invalidLength);
    }
    final bytes = toBytes();
    bytes.setRange(start, start + ciphertext.length, ciphertext);
    return VaultBootstrapRecord._(bytes);
  }
}
