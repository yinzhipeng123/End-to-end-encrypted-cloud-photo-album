import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:encrypted_photo_shared/security/security_failure.dart';
import 'package:encrypted_photo_shared/security/vault_bootstrap_record.dart';
import 'package:encrypted_photo_shared/security/vault_bootstrap_store.dart';
import 'package:encrypted_photo_shared/security/vault_credentials.dart';
import 'package:encrypted_photo_shared/security/vault_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

const testPassword = 'synthetic lantern river carpet 2026';
const wrongPassword = 'synthetic different river carpet 2026';

Matcher failure(SecurityFailureCode code) =>
    throwsA(isA<SecurityFailure>().having((error) => error.code, 'code', code));

void main() {
  late Directory directory;
  late File file;
  late VaultBootstrapStore store;
  late VaultCredentials credentials;
  late VaultCrypto crypto;

  setUpAll(() async => crypto = await VaultCrypto.load());
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('epa-credentials-test-');
    file = File('${directory.path}/vault.bootstrap');
    store = VaultBootstrapStore(file);
    credentials = VaultCredentials(store);
  });
  tearDown(() async {
    credentials.revoke();
    await directory.delete(recursive: true);
  });

  Future<VaultCredentialSession> create() => credentials.initialize(
    password: testPassword,
    confirmation: testPassword,
  );

  test('uses the approved actual native backend', () {
    expect(crypto.nativeVersion, '1.0.22');
  });

  test('persists authenticated material; a new service reopens it', () async {
    final initial = await create();
    final id = initial.vaultId;
    final catalogId = initial.catalogId;
    expect(await file.length(), VaultBootstrapRecord.byteLength);
    final before = await file.readAsBytes();
    expect(latin1.decode(before), isNot(contains(testPassword)));
    credentials.revoke();
    expect(initial.isClosed, isTrue);

    final second = VaultCredentials(VaultBootstrapStore(file));
    try {
      final opened = await second.unlock(
        password: testPassword,
        expectedVaultId: id,
      );
      expect(opened.vaultId, id);
      expect(opened.catalogId, catalogId);
      expect(opened.generation, 1);
      expect(opened.isClosed, isFalse);
      expect(await file.readAsBytes(), before);
      second.revoke();
      expect(opened.isClosed, isTrue);
    } finally {
      second.revoke();
    }
  });

  test('invalid or mismatched input creates no file', () async {
    await expectLater(
      credentials.initialize(password: 'short', confirmation: 'short'),
      failure(SecurityFailureCode.invalidPassword),
    );
    await expectLater(
      credentials.initialize(
        password: testPassword,
        confirmation: wrongPassword,
      ),
      failure(SecurityFailureCode.passwordMismatch),
    );
    expect(await file.exists(), isFalse);
  });

  test(
    'wrong password fails real authentication and closes old session',
    () async {
      final old = await create();
      final before = await file.readAsBytes();
      await expectLater(
        credentials.unlock(
          password: wrongPassword,
          expectedVaultId: old.vaultId,
        ),
        failure(SecurityFailureCode.authenticationFailed),
      );
      expect(old.isClosed, isTrue);
      expect(await file.readAsBytes(), before);
      final opened = await credentials.unlock(
        password: testPassword,
        expectedVaultId: old.vaultId,
      );
      expect(opened.isClosed, isFalse);
    },
  );

  test('rejects another expected vault identity', () async {
    await create();
    await expectLater(
      credentials.unlock(
        password: testPassword,
        expectedVaultId: Uint8List(16),
      ),
      failure(SecurityFailureCode.identityMismatch),
    );
  });

  test(
    'new vaults use different identities, salts, nonces and wraps',
    () async {
      await create();
      final first = await store.read();
      final otherStore = VaultBootstrapStore(File('${directory.path}/second'));
      final other = VaultCredentials(otherStore);
      try {
        await other.initialize(
          password: testPassword,
          confirmation: testPassword,
        );
        final second = await otherStore.read();
        for (final pair in [
          [first.vaultId, second.vaultId],
          [first.catalogId, second.catalogId],
          [first.salt, second.salt],
          [first.masterNonce, second.masterNonce],
          [first.catalogNonce, second.catalogNonce],
          [first.wrappedMaster, second.wrappedMaster],
          [first.wrappedCatalog, second.wrappedCatalog],
        ]) {
          expect(pair[0], isNot(orderedEquals(pair[1])));
        }
      } finally {
        other.revoke();
      }
    },
  );

  test(
    'never overwrites existing valid, empty or truncated material',
    () async {
      await create();
      final valid = await file.readAsBytes();
      for (final bytes in [valid, Uint8List(0), valid.sublist(0, 83)]) {
        await file.writeAsBytes(bytes, flush: true);
        await expectLater(create(), failure(SecurityFailureCode.alreadyExists));
        expect(await file.readAsBytes(), bytes);
        if (bytes.length < VaultBootstrapRecord.byteLength) {
          await expectLater(
            store.read(),
            failure(SecurityFailureCode.incompleteMaterial),
          );
        }
      }
    },
  );

  test(
    'malicious sizes and KDF parameters are rejected before derivation',
    () async {
      await create();
      final bytes = await file.readAsBytes();
      for (final offset in [0, 8, 10, 11, 12, 13, 14, 16, 20, 22, 128]) {
        final invalid = Uint8List.fromList(bytes)..[offset] ^= 0xff;
        await file.writeAsBytes(invalid, flush: true);
        await expectLater(
          store.read(),
          failure(SecurityFailureCode.unsupportedFormat),
        );
      }
      await file.writeAsBytes([...bytes, 0], flush: true);
      await expectLater(
        store.read(),
        failure(SecurityFailureCode.invalidLength),
      );
      final oversized = await file.open(mode: FileMode.write);
      await oversized.truncate(16 * 1024 * 1024);
      await oversized.close();
      await expectLater(
        store.read(),
        failure(SecurityFailureCode.invalidLength),
      );
    },
  );

  test(
    'authenticates generation, identity, salt, both nonces and both tags',
    () async {
      final first = await create();
      final bytes = await file.readAsBytes();
      for (final offset in [24, 48, 64, 80, 104, 132, 179, 180, 227]) {
        final corrupt = Uint8List.fromList(bytes);
        corrupt[offset] ^= 2;
        await file.writeAsBytes(corrupt, flush: true);
        await expectLater(
          credentials.unlock(
            password: testPassword,
            expectedVaultId: first.vaultId,
          ),
          failure(SecurityFailureCode.authenticationFailed),
        );
      }
      await file.writeAsBytes(bytes, flush: true);
      expect(
        (await credentials.unlock(
          password: testPassword,
          expectedVaultId: first.vaultId,
        )).isClosed,
        isFalse,
      );
    },
  );

  test('file errors have no secret/path and do not return success', () async {
    final other = VaultCredentials(
      VaultBootstrapStore(File('${directory.path}/missing/credentials')),
    );
    try {
      await other.initialize(
        password: testPassword,
        confirmation: testPassword,
      );
      fail('missing parent was accepted');
    } on SecurityFailure catch (error) {
      expect(error.code, SecurityFailureCode.storageFailure);
      expect(error.toString(), isNot(contains(directory.path)));
      expect(error.toString(), isNot(contains(testPassword)));
    } finally {
      other.revoke();
    }
    expect(await directory.list().isEmpty, isTrue);
  });

  test(
    'revocation while KDF runs prevents late initialization success',
    () async {
      var ticks = 0;
      // Waiting for the worker to own the derivation gate makes this a real
      // in-flight cancellation, not merely a pre-start cancellation.
      final password = crypto.protect(
        Uint8List.fromList(utf8.encode(testPassword)),
      );
      final running = crypto.deriveWrappingKey(
        password,
        crypto.randomBytes(16),
      );
      final timer = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => ticks++,
      );
      try {
        await expectLater(
          crypto.deriveWrappingKey(password, crypto.randomBytes(16)),
          failure(SecurityFailureCode.busy),
        );
        final key = await running;
        key.dispose();
        expect(ticks, greaterThan(0));
      } finally {
        timer.cancel();
        password.dispose();
      }

      final pending = expectLater(
        create(),
        failure(SecurityFailureCode.cancelled),
      );
      final wait = Stopwatch()..start();
      while (!crypto.isDeriving && wait.elapsed < const Duration(seconds: 10)) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(crypto.isDeriving, isTrue);
      credentials.revoke();
      await pending;
      expect(await file.exists(), isFalse);
    },
  );

  test('one service rejects overlapping operations', () async {
    final pending = create();
    await expectLater(create(), failure(SecurityFailureCode.busy));
    await pending;
    expect(await file.length(), VaultBootstrapRecord.byteLength);
  });

  test('concurrent OS-level creators cannot overwrite one another', () async {
    final record = VaultBootstrapRecord.newHeader(crypto);
    // This store test writes a structurally valid but unauthenticated record;
    // it is not claimed to be an initialized vault.
    final outcomes = await Future.wait(
      List.generate(4, (_) async {
        try {
          await VaultBootstrapStore(file).create(record);
          return 'created';
        } on SecurityFailure catch (error) {
          return error.code.name;
        }
      }),
    );
    expect(outcomes.where((value) => value == 'created').length, 1);
    expect(outcomes.where((value) => value == 'alreadyExists').length, 3);
    expect(await file.readAsBytes(), record.toBytes());
  });
}
