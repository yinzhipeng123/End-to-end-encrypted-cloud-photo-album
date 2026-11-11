import 'dart:convert';
import 'dart:typed_data';

import 'package:encrypted_photo_shared/security/security_failure.dart';
import 'package:encrypted_photo_shared/security/vault_bootstrap_record.dart';
import 'package:encrypted_photo_shared/security/vault_crypto.dart';

/// WSR-1 remote master wrapping only. Never contains a local catalog key wrap.
final class VaultRecoveryRecord {
  VaultRecoveryRecord._(this._projection);
  static const byteLength = 188;
  final Uint8List _projection;

  factory VaultRecoveryRecord.fromBootstrap(VaultBootstrapRecord record) =>
      VaultRecoveryRecord._(
        Uint8List.fromList(record.toBytes().take(180).toList()),
      );

  factory VaultRecoveryRecord.parse(Uint8List input) {
    if (input.length != byteLength ||
        ascii.decode(input.sublist(0, 8), allowInvalid: true) != 'EPAREC01') {
      throw const SecurityFailure(SecurityFailureCode.unsupportedFormat);
    }
    final p = Uint8List.fromList(input.sublist(8));
    final data = ByteData.sublistView(p);
    // Validate the projection as its own type, never pad into a local bootstrap.
    if (ascii.decode(p.sublist(0, 8), allowInvalid: true) != 'EPAVLT01' ||
        data.getUint16(8, Endian.little) != 1 ||
        p[10] != 1 ||
        p[11] != 1 ||
        p[12] != 0x13 ||
        p[13] != 1 ||
        data.getUint16(14, Endian.little) != VaultCrypto.operations ||
        data.getUint32(16, Endian.little) != VaultCrypto.memoryBytes ||
        data.getUint16(20, Endian.little) != VaultCrypto.keyBytes ||
        data.getUint16(22, Endian.little) != VaultCrypto.wrappedKeyBytes ||
        data.getUint64(24, Endian.little) < 1 ||
        data.getUint64(24, Endian.little) > 0x7fffffffffffffff ||
        data.getUint32(128, Endian.little) != 96) {
      throw const SecurityFailure(SecurityFailureCode.unsupportedFormat);
    }
    return VaultRecoveryRecord._(p);
  }

  Uint8List get vaultId => Uint8List.fromList(_projection.sublist(32, 48));
  Uint8List get salt => Uint8List.fromList(_projection.sublist(64, 80));
  Uint8List get nonce => Uint8List.fromList(_projection.sublist(80, 104));
  Uint8List get wrappedMaster =>
      Uint8List.fromList(_projection.sublist(132, 180));
  int get generation =>
      ByteData.sublistView(_projection).getUint64(24, Endian.little);
  Uint8List get aad => Uint8List.fromList([
    ...ascii.encode('EPA/bootstrap/master/v1\x00'),
    ..._projection.take(132),
  ]);
  Uint8List toBytes() =>
      Uint8List.fromList([...ascii.encode('EPAREC01'), ..._projection]);
}
