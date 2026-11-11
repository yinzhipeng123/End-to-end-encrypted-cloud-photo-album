import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:encrypted_photo_shared/security/security_failure.dart';
import 'package:encrypted_photo_shared/security/vault_bootstrap_record.dart';
import 'package:encrypted_photo_shared/security/vault_bootstrap_store.dart';
import 'package:encrypted_photo_shared/security/vault_credentials.dart';
import 'package:encrypted_photo_shared/security/vault_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List hex(String value) => Uint8List.fromList([
  for (var i = 0; i < value.length; i += 2)
    int.parse(value.substring(i, i + 2), radix: 16),
]);
Matcher failure(SecurityFailureCode code) =>
    throwsA(isA<SecurityFailure>().having((e) => e.code, 'code', code));

void main() {
  late Directory directory;
  late VaultCredentials credentials;
  late VaultCredentialSession session;
  late Map<String, dynamic> fixture;
  late Map<String, dynamic> reference;
  Uint8List vector(String name) => hex(reference[name] as String);
  late VaultCrypto crypto;

  setUpAll(() async {
    crypto = await VaultCrypto.load();
    fixture = jsonDecode(
      await File('test/fixtures/security/bootstrap-v1.json').readAsString(),
    ) as Map<String, dynamic>;
    reference = fixture['media_reference'] as Map<String, dynamic>;
  });
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('epa-media-crypto-test-');
    final file = File('${directory.path}/vault.bootstrap');
    final bytes = hex(fixture['bootstrap_hex'] as String);
    await file.writeAsBytes(bytes, flush: true);
    credentials = VaultCredentials(VaultBootstrapStore(file));
    session = await credentials.unlock(
      password: fixture['password'] as String,
      expectedVaultId: VaultBootstrapRecord.parse(bytes).vaultId,
    );
  });
  tearDown(() async {
    credentials.revoke();
    await directory.delete(recursive: true);
  });

  test(
    'purpose keys and media encryption match independent Python vectors',
    () {
      final master = crypto.protect(hex(fixture['master_hex'] as String));
      final key = crypto.protect(vector('resource_key_hex'));
      try {
        for (final purpose in [1, 2, 3]) {
          final derived = crypto.purposeKey(master, purpose);
          try {
            derived.runUnlockedSync(
              (bytes) => expect(
                bytes,
                hex(
                  (reference['purpose_keys_hex'] as Map)['$purpose'] as String,
                ),
              ),
            );
          } finally {
            derived.dispose();
          }
        }
        expect(
          crypto.encrypt(
            clear: vector('plaintext_hex'),
            key: key,
            nonce: vector('nonce_hex'),
            aad: vector('media_aad_hex'),
          ),
          vector('media_ciphertext_hex'),
        );
      } finally {
        master.dispose();
        key.dispose();
      }
    },
  );

  test(
    'credential service opens independent resource and recovery vectors',
    () {
      final resource = session.openResource(
        vector('resource_context_hex'),
        VaultCiphertext(
          nonce: vector('nonce_hex'),
          ciphertext: vector('resource_wrap_hex'),
        ),
      );
      expect(
        resource.decrypt(
          VaultCiphertext(
            nonce: vector('nonce_hex'),
            ciphertext: vector('media_ciphertext_hex'),
          ),
          unitContext: vector('unit_context_hex'),
        ),
        vector('plaintext_hex'),
      );
      expect(
        session.decryptRecoveryMetadata(
          VaultCiphertext(
            nonce: vector('nonce_hex'),
            ciphertext: vector('recovery_ciphertext_hex'),
          ),
          vector('resource_context_hex'),
        ),
        vector('plaintext_hex'),
      );
    },
  );

  test(
    'actual files encrypt and reopen with byte-identical authenticated output',
    () async {
      final original = File('${directory.path}/artificial-source.bin');
      final clear = Uint8List.fromList(
        List.generate(1024 * 1024 + 19, (i) => i % 251),
      );
      await original.writeAsBytes(clear, flush: true);
      final context = vector('resource_context_hex');
      final resource = session.createResource(context);
      final envelope = resource.envelope;
      final encrypted = resource.encrypt(
        await original.readAsBytes(),
        unitContext: vector('unit_context_hex'),
      );
      final cipherFile = File('${directory.path}/ciphertext.bin');
      await cipherFile.writeAsBytes(encrypted.ciphertext, flush: true);
      final id = session.vaultId;
      credentials.revoke();
      session = await credentials.unlock(
        password: fixture['password'] as String,
        expectedVaultId: id,
      );
      final reopened = session.openResource(context, envelope);
      final recovered = reopened.decrypt(
        VaultCiphertext(
          nonce: encrypted.nonce,
          ciphertext: await cipherFile.readAsBytes(),
        ),
        unitContext: vector('unit_context_hex'),
      );
      final exported = File('${directory.path}/artificial-recovered.bin');
      await exported.writeAsBytes(recovered, flush: true);
      expect(await exported.readAsBytes(), clear);
      expect(await original.readAsBytes(), clear);
      expect(await cipherFile.readAsBytes(), isNot(clear));
      recovered.fillRange(0, recovered.length, 0);
    },
  );

  test(
    'wrong unit, resource, purpose, key, nonce, ciphertext and tag fail',
    () {
      final context = vector('resource_context_hex');
      final unit = vector('unit_context_hex');
      final resource = session.createResource(context);
      final other = session.createResource(context);
      final encrypted = resource.encrypt(
        vector('plaintext_hex'),
        unitContext: unit,
      );
      final authFailure = failure(SecurityFailureCode.authenticationFailed);
      expect(() => other.decrypt(encrypted, unitContext: unit), authFailure);
      expect(
        () =>
            resource.decrypt(encrypted, unitContext: Uint8List.fromList([99])),
        authFailure,
      );
      expect(
        () => session.openResource(Uint8List.fromList([99]), resource.envelope),
        authFailure,
      );
      expect(
        () => session.decryptRecoveryMetadata(encrypted, context),
        authFailure,
      );
      for (final offset in [0, encrypted.ciphertext.length - 1]) {
        final bytes = encrypted.ciphertext..[offset] ^= 1;
        expect(
          () => resource.decrypt(
            VaultCiphertext(nonce: encrypted.nonce, ciphertext: bytes),
            unitContext: unit,
          ),
          authFailure,
        );
      }
      final nonce = encrypted.nonce..[0] ^= 1;
      expect(
        () => resource.decrypt(
          VaultCiphertext(nonce: nonce, ciphertext: encrypted.ciphertext),
          unitContext: unit,
        ),
        authFailure,
      );
      expect(
        () => resource.decrypt(
          VaultCiphertext(
            nonce: encrypted.nonce,
            ciphertext: encrypted.ciphertext.sublist(1),
          ),
          unitContext: unit,
        ),
        authFailure,
      );
      expect(
        () => resource.decrypt(resource.envelope, unitContext: unit),
        authFailure,
      );
    },
  );

  test('foreign vault cannot open a resource envelope', () async {
    final foreign = VaultCredentials(
      VaultBootstrapStore(File('${directory.path}/other.bootstrap')),
    );
    try {
      final second = await foreign.initialize(
        password: 'artificial other vault password',
        confirmation: 'artificial other vault password',
      );
      final context = vector('resource_context_hex');
      expect(
        () => second.openResource(
          context,
          session.createResource(context).envelope,
        ),
        failure(SecurityFailureCode.authenticationFailed),
      );
    } finally {
      foreign.revoke();
    }
  });

  test('fresh keys and nonces, empty payload, immutable public buffers', () {
    final context = vector('resource_context_hex');
    final unit = vector('unit_context_hex');
    final a = session.createResource(context);
    final b = session.createResource(context);
    expect(a.envelope.ciphertext, isNot(b.envelope.ciphertext));
    final first = a.encrypt(Uint8List(0), unitContext: unit);
    final second = a.encrypt(Uint8List(0), unitContext: unit);
    expect(first.nonce, isNot(second.nonce));
    final exposed = first.nonce..[0] ^= 1;
    expect(first.nonce, isNot(exposed));
    expect(a.decrypt(first, unitContext: unit), isEmpty);
    final metadata = session.encryptRecoveryMetadata(
      vector('plaintext_hex'),
      context,
    );
    expect(
      session.decryptRecoveryMetadata(metadata, context),
      vector('plaintext_hex'),
    );
  });

  test(
    'closed resource and parent revocation reject every crypto operation',
    () {
      final context = vector('resource_context_hex');
      final unit = vector('unit_context_hex');
      final resource = session.createResource(context);
      final encrypted = resource.encrypt(
        vector('plaintext_hex'),
        unitContext: unit,
      );
      resource.close();
      expect(
        () => resource.decrypt(encrypted, unitContext: unit),
        failure(SecurityFailureCode.cancelled),
      );
      final child = session.createResource(context);
      credentials.revoke();
      expect(
        () => child.encrypt(Uint8List(0), unitContext: unit),
        failure(SecurityFailureCode.cancelled),
      );
      expect(
        () => session.createResource(context),
        failure(SecurityFailureCode.cancelled),
      );
      expect(
        () => session.openResource(context, child.envelope),
        failure(SecurityFailureCode.cancelled),
      );
      expect(
        () => session.decryptRecoveryMetadata(encrypted, context),
        failure(SecurityFailureCode.cancelled),
      );
    },
  );

  test('invalid public sizes and absent binding context are refused', () {
    expect(
      () => session.createResource(Uint8List(0)),
      failure(SecurityFailureCode.invalidLength),
    );
    expect(
      () => session.createResource(Uint8List(4097)),
      failure(SecurityFailureCode.invalidLength),
    );
    expect(
      () => VaultCiphertext(nonce: Uint8List(23), ciphertext: Uint8List(16)),
      failure(SecurityFailureCode.invalidLength),
    );
    expect(
      () => VaultCiphertext(nonce: Uint8List(24), ciphertext: Uint8List(15)),
      failure(SecurityFailureCode.invalidLength),
    );
  });
}
