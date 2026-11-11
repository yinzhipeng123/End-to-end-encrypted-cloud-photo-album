import 'dart:io';
import 'dart:typed_data';

import 'package:encrypted_photo_shared/security/security_failure.dart';
import 'package:encrypted_photo_shared/security/vault_bootstrap_record.dart';
import 'package:encrypted_photo_shared/security/vault_bootstrap_store.dart';
import 'package:encrypted_photo_shared/security/vault_credentials.dart';
import 'package:encrypted_photo_app/security/windows_data_protection.dart';
import 'package:flutter_test/flutter_test.dart';

Matcher failure(SecurityFailureCode code) =>
    throwsA(isA<SecurityFailure>().having((e) => e.code, 'code', code));

void main() {
  if (!Platform.isWindows) return;
  late Directory scratch;
  late File file;
  late WindowsDataProtection platform;
  late VaultCredentials credentials;
  late Uint8List id;
  const oldPassword = 'artificial old password river';
  const newPassword = 'artificial new password lantern';
  setUp(() async {
    scratch = await Directory.systemTemp.createTemp(
      'epa-password-change-test-',
    );
    platform = WindowsDataProtection();
    final root = Directory('${scratch.path}/private');
    platform.preparePrivateDirectory(root.path);
    file = File('${root.path}/vault.bootstrap');
    credentials = VaultCredentials(
      VaultBootstrapStore(file, commitReplacement: platform.replacePrivateFile),
    );
    id = (await credentials.initialize(
      password: oldPassword,
      confirmation: oldPassword,
    )).vaultId;
  });
  tearDown(() async {
    credentials.revoke();
    await scratch.delete(recursive: true);
  });

  Future<VaultCredentialSession> change({String old = oldPassword}) =>
      credentials.changePassword(
        oldPassword: old,
        newPassword: newPassword,
        confirmation: newPassword,
        expectedVaultId: id,
      );

  test('password changes rewrap unchanged resource keys and increment authenticated generation', () async {
    final old = await credentials.unlock(
      password: oldPassword,
      expectedVaultId: id,
    );
    final context = Uint8List.fromList([1, 2, 3]);
    final unit = Uint8List.fromList([0]);
    final resource = old.createResource(context);
    final encrypted = resource.encrypt(
      Uint8List.fromList([9, 8, 7]),
      unitContext: unit,
    );
    final envelope = resource.envelope;
    final oldBytes = await file.readAsBytes();
    final updated = await change();
    expect(old.isClosed, isTrue);
    expect(updated.generation, 2);
    expect(updated.vaultId, id);
    expect(
      updated
          .openResource(context, envelope)
          .decrypt(encrypted, unitContext: unit),
      [9, 8, 7],
    );
    expect(await file.readAsBytes(), isNot(oldBytes));
    await expectLater(
      credentials.unlock(password: oldPassword, expectedVaultId: id),
      failure(SecurityFailureCode.authenticationFailed),
    );
    final reopened = await credentials.unlock(
      password: newPassword,
      expectedVaultId: id,
    );
    expect(reopened.generation, 2);
  });

  test('wrong old password or mismatching new confirmation leaves original bytes intact', () async {
    final before = await file.readAsBytes();
    await expectLater(
      change(old: 'artificial incorrect password'),
      failure(SecurityFailureCode.authenticationFailed),
    );
    expect(await file.readAsBytes(), before);
    await expectLater(
      credentials.changePassword(
        oldPassword: oldPassword,
        newPassword: newPassword,
        confirmation: 'artificial mismatch password',
        expectedVaultId: id,
      ),
      failure(SecurityFailureCode.passwordMismatch),
    );
    expect(await file.readAsBytes(), before);
    expect(
      (await credentials.unlock(
        password: oldPassword,
        expectedVaultId: id,
      )).isClosed,
      isFalse,
    );
  });

  test('actual staged write with injected commit failure preserves the recoverable old file', () async {
    final before = await file.readAsBytes();
    credentials.revoke();
    var validatedCandidate = false;
    credentials = VaultCredentials(
      VaultBootstrapStore(
        file,
        commitReplacement: (source, destination) {
          expect(File(source).existsSync(), isTrue);
          expect(
            VaultBootstrapRecord.parse(File(source).readAsBytesSync())
                .generation,
            2,
          );
          validatedCandidate = true;
          throw const SecurityFailure(SecurityFailureCode.storageFailure);
        },
      ),
    );
    await expectLater(change(), failure(SecurityFailureCode.storageFailure));
    expect(validatedCandidate, isTrue);
    expect(await file.readAsBytes(), before);
    expect(
      (await credentials.unlock(
        password: oldPassword,
        expectedVaultId: id,
      )).isClosed,
      isFalse,
    );
  });

  test(
    'cancellation during derivation does not replace existing wrapping',
    () async {
      final before = await file.readAsBytes();
      final pending = change();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      credentials.revoke();
      await expectLater(pending, failure(SecurityFailureCode.cancelled));
      expect(await file.readAsBytes(), before);
    },
  );

  test('late cancellation after atomic commit reports no session while preserving new recoverable material', () async {
    credentials.revoke();
    credentials = VaultCredentials(
      VaultBootstrapStore(
        file,
        commitReplacement: (source, destination) {
          platform.replacePrivateFile(source, destination);
          credentials.revoke();
        },
      ),
    );
    await expectLater(change(), failure(SecurityFailureCode.cancelled));
    expect(
      (await credentials.unlock(
        password: newPassword,
        expectedVaultId: id,
      )).generation,
      2,
    );
  });

  test('copied old wrapping still authenticates with old password, with no false revocation claim', () async {
    final copied = File('${file.parent.path}/copied-old.bootstrap');
    await copied.writeAsBytes(await file.readAsBytes(), flush: true);
    await change();
    final independent = VaultCredentials(VaultBootstrapStore(copied));
    try {
      expect(
        (await independent.unlock(
          password: oldPassword,
          expectedVaultId: id,
        )).generation,
        1,
      );
    } finally {
      independent.revoke();
    }
  });
}
