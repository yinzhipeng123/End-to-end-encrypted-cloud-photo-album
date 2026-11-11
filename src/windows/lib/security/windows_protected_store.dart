import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:encrypted_photo_shared/security/security_failure.dart';
import 'package:encrypted_photo_shared/security/protected_record_store.dart';
import 'package:encrypted_photo_shared/security/vault_crypto.dart';
import 'package:encrypted_photo_app/security/windows_data_protection.dart';

/// Small system-sealed records; not a media or plaintext metadata database.
final class WindowsProtectedStore implements ProtectedRecordStore {
  WindowsProtectedStore(this.directory, this.platform);
  final Directory directory;
  final WindowsDataProtection platform;

  Future<void> initialize() async =>
      platform.preparePrivateDirectory(directory.path);

  File _file(String name) {
    if (!RegExp(r'^[a-z][a-z0-9-]{0,63}$').hasMatch(name)) {
      throw const SecurityFailure(SecurityFailureCode.invalidLength);
    }
    return File('${directory.path}/$name.sealed');
  }

  Uint8List _binding(String name, Uint8List binding) => Uint8List.fromList([
    ...ascii.encode('EPA/platform-record/v1\x00$name\x00'),
    ...binding,
  ]);

  Future<Uint8List?> read(String name, Uint8List binding) async {
    try {
      platform.validatePrivatePath(directory.path, directory: true);
      final file = _file(name);
      if (!await file.exists()) return null;
      platform.validatePrivatePath(file.path);
      final handle = await file.open();
      late Uint8List sealed;
      try {
        sealed = await handle.read(1024 * 1024 + 1);
      } finally {
        await handle.close();
      }
      return platform.unseal(sealed, _binding(name, binding));
    } on SecurityFailure {
      rethrow;
    } catch (_) {
      throw const SecurityFailure(SecurityFailureCode.storageFailure);
    }
  }

  Future<void> write(String name, Uint8List clear, Uint8List binding) async {
    File? temporary;
    try {
      platform.validatePrivatePath(directory.path, directory: true);
      final destination = _file(name);
      final recordBinding = _binding(name, binding);
      final sealed = platform.seal(clear, recordBinding);
      final crypto = await VaultCrypto.load();
      final suffix = crypto
          .randomBytes(16)
          .map((v) => v.toRadixString(16).padLeft(2, '0'))
          .join();
      temporary = File('${destination.path}.$suffix.pending');
      await temporary.create(exclusive: true);
      platform.validatePrivatePath(temporary.path);
      await temporary.writeAsBytes(sealed, flush: true);
      // Check the sealed candidate before replacing a last usable record.
      final checked = platform.unseal(
        await temporary.readAsBytes(),
        recordBinding,
      );
      try {
        if (!crypto.sameBytes(checked, clear))
          throw const SecurityFailure(SecurityFailureCode.authenticationFailed);
      } finally {
        checked.fillRange(0, checked.length, 0);
      }
      platform.replacePrivateFile(temporary.path, destination.path);
      temporary = null;
    } on SecurityFailure {
      rethrow;
    } catch (_) {
      throw const SecurityFailure(SecurityFailureCode.storageFailure);
    } finally {
      if (temporary != null) {
        try {
          await temporary.delete();
        } catch (_) {
          /* Only sealed residue. */
        }
      }
    }
  }

  Future<void> remove(String name) async {
    try {
      platform.validatePrivatePath(directory.path, directory: true);
      final file = _file(name);
      if (await file.exists()) {
        platform.validatePrivatePath(file.path);
        await file.delete();
      }
    } on SecurityFailure {
      rethrow;
    } catch (_) {
      throw const SecurityFailure(SecurityFailureCode.storageFailure);
    }
  }
}
