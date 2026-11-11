import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:encrypted_photo_shared/security/security_failure.dart';
import 'package:encrypted_photo_shared/security/vault_bootstrap_store.dart';
import 'package:encrypted_photo_shared/security/vault_credentials.dart';
import 'package:encrypted_photo_shared/security/vault_crypto.dart';
import 'package:encrypted_photo_shared/security/vault_recovery_record.dart';
import 'package:encrypted_photo_app/services/import/windows_source_reader.dart';
import 'package:encrypted_photo_shared/sync/sync_format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const password = 'isolated WSR-1 test password';
  late Directory directory;
  late VaultCredentials credentials;
  late VaultCredentialSession session;
  late VaultCrypto crypto;
  final owned = <VaultCredentials>[];
  setUpAll(() async {
    crypto = await VaultCrypto.load();
    if (Platform.isWindows)
      WindowsSourceReader.setTestLibrary(
        File('build/source-reader/Release/epa_source_reader.dll').absolute.path,
      );
  });
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('epa-sync-format-');
    credentials = VaultCredentials(
      VaultBootstrapStore(File('${directory.path}/source.bootstrap')),
    );
    session = await credentials.initialize(
      password: password,
      confirmation: password,
    );
  });
  tearDown(() async {
    credentials.revoke();
    for (final c in owned) {
      c.revoke();
    }
    owned.clear();
    await directory.delete(recursive: true);
  });
  VaultCredentials receiver(String name) {
    final value = VaultCredentials(
      VaultBootstrapStore(File('${directory.path}/$name.bootstrap')),
    );
    owned.add(value);
    return value;
  }

  Uint8List context() =>
      SyncFormat.resourceContext('01' * 16, '02' * 16, '03' * 16);

  test('remote projection omits catalog wrap; fresh device authenticates original resources with its own catalog', () async {
    final remote = session.recoveryMaterial();
    final original = await File('${directory.path}/source.bootstrap')
        .readAsBytes();
    expect(remote.length, 188);
    expect(remote.sublist(8), original.sublist(0, 180));
    final media = session.createResource(context());
    final envelope = media.envelope;
    final encrypted = media.encrypt(
      Uint8List.fromList([1, 2, 3]),
      unitContext: SyncFormat.chunkContext(0, 1, 3, 3),
    );
    final oldCatalog = session.catalogId;
    final id = session.vaultId;
    credentials.revoke();
    // No source bootstrap, catalog, auxiliary material or original bytes needed.
    await File('${directory.path}/source.bootstrap').delete();
    final restore = receiver('restored');
    final opened = await restore.restoreFromRepository(
      recovery: remote,
      password: password,
      expectedVaultId: id,
    );
    expect(opened.vaultId, id);
    expect(opened.catalogId, isNot(oldCatalog));
    expect(
      opened
          .openResource(context(), envelope)
          .decrypt(encrypted, unitContext: SyncFormat.chunkContext(0, 1, 3, 3)),
      [1, 2, 3],
    );
    restore.revoke();
    final reopened = await restore.unlock(
      password: password,
      expectedVaultId: id,
    );
    expect(reopened.vaultId, id);
  });

  test('wrong password, wrong vault and malformed recovery never create a local bootstrap', () async {
    final remote = session.recoveryMaterial();
    final restore = receiver('rejected');
    await expectLater(
      restore.restoreFromRepository(
        recovery: remote,
        password: 'different isolated password',
        expectedVaultId: session.vaultId,
      ),
      throwsA(
        isA<SecurityFailure>().having(
          (e) => e.code,
          'code',
          SecurityFailureCode.authenticationFailed,
        ),
      ),
    );
    expect(File('${directory.path}/rejected.bootstrap').existsSync(), false);
    await expectLater(
      restore.restoreFromRepository(
        recovery: remote,
        password: password,
        expectedVaultId: Uint8List(16),
      ),
      throwsA(isA<SecurityFailure>()),
    );
    for (final bytes in [
      Uint8List(0),
      remote.sublist(1),
      Uint8List.fromList([...remote, 0]),
      Uint8List.fromList(remote)..[8 + 16] ^= 1,
    ]) {
      expect(
        () => VaultRecoveryRecord.parse(bytes),
        throwsA(isA<SecurityFailure>()),
      );
    }
    expect(File('${directory.path}/rejected.bootstrap').existsSync(), false);
    await expectLater(
      credentials.restoreFromRepository(
        recovery: remote,
        password: password,
        expectedVaultId: session.vaultId,
      ),
      throwsA(isA<SecurityFailure>()),
    );
  });

  test('strict canonical metadata rejects duplicate keys, malformed counts, deep nesting and foreign purpose', () {
    final value = <String, Object?>{
      'z': '中文',
      'a': ['0', true, null],
    };
    final clear = SyncFormat.encodeJson(value);
    expect(utf8.decode(clear), '{"a":["0",true,null],"z":"中文"}');
    expect(SyncFormat.decodeJson(clear), value);
    for (final bad in [
      '{"a":"1","a":"2"}',
      '{ "a":"1"}',
      '{"n":1}',
      '{"a":${'[' * 34}null${']' * 34}}',
    ]) {
      expect(
        () => SyncFormat.decodeJson(Uint8List.fromList(utf8.encode(bad))),
        throwsA(isA<SyncFailure>()),
      );
    }
    for (final count in ['01', '-1', '1.0', '9223372036854775808']) {
      expect(() => SyncFormat.count(count), throwsA(isA<SyncFailure>()));
    }
    final encoded = SyncFormat.encryptMetadata(
      session,
      'media',
      '01' * 16,
      value,
    );
    expect(
      SyncFormat.decryptMetadata(session, 'media', '01' * 16, encoded),
      value,
    );
    expect(
      () => SyncFormat.decryptMetadata(session, 'page', '01' * 16, encoded),
      throwsA(isA<SecurityFailure>()),
    );
    expect(
      () => SyncFormat.decryptMetadata(session, 'media', '02' * 16, encoded),
      throwsA(isA<SecurityFailure>()),
    );
    expect(
      () => SyncFormat.decryptMetadata(
        session,
        'media',
        '01' * 16,
        encoded..[40] ^= 1,
      ),
      throwsA(isA<SecurityFailure>()),
    );
  });

  for (final size in [
    1,
    SyncFormat.chunkBytes - 1,
    SyncFormat.chunkBytes,
    SyncFormat.chunkBytes + 1,
  ]) {
    test(
      'actual file roundtrip at plaintext size $size; exact wire length and swapped chunk rejection',
      () async {
        final original = File('${directory.path}/source.bin');
        final handle = await original.open(mode: FileMode.write);
        final bytes = Uint8List.fromList(List.generate(65536, (i) => i % 251));
        var remaining = size;
        while (remaining > 0) {
          final n = remaining < bytes.length ? remaining : bytes.length;
          await handle.writeFrom(bytes, 0, n);
          remaining -= n;
        }
        await handle.close();
        final key = session.createResource(context());
        final blocks = <File>[];
        final encoder = ResourceBlockEncoder(
          resource: key,
          totalBytes: size,
          checkAccess: () {},
          writeBlock: (index, length, cipher) async {
            expect(cipher.length, length + 48);
            expect(cipher.length, lessThanOrEqualTo(4194352));
            final file = File('${directory.path}/$index.bin');
            await file.writeAsBytes(cipher, flush: true);
            blocks.add(file);
          },
        );
        await for (final part in original.openRead()) {
          await encoder.add(Uint8List.fromList(part));
        }
        encoder.finish();
        final recovered = File('${directory.path}/restored.bin').openWrite();
        for (var i = 0; i < blocks.length; i++) {
          final cipher = await blocks[i].readAsBytes();
          final clear = decryptResourceBlock(
            key,
            cipher,
            index: i,
            totalBytes: size,
          );
          recovered.add(clear);
          await recovered.flush();
          clear.fillRange(0, clear.length, 0);
          if (blocks.length > 1) {
            expect(
              () => decryptResourceBlock(
                key,
                cipher,
                index: 1 - i,
                totalBytes: size,
              ),
              throwsA(anything),
            );
          }
        }
        await recovered.close();
        expect(
          await File('${directory.path}/restored.bin').readAsBytes(),
          await original.readAsBytes(),
        );
        key.close();
      },
    );
  }

  test('truncated, oversized and cancelled streams cannot finish or emit further blocks', () async {
    final key = session.createResource(context());
    var calls = 0;
    final encoder = ResourceBlockEncoder(
      resource: key,
      totalBytes: 3,
      checkAccess: () {},
      writeBlock: (_, _, _) async {
        calls++;
      },
    );
    await encoder.add(Uint8List.fromList([1, 2]));
    expect(encoder.finish, throwsA(isA<SyncFailure>()));
    expect(calls, 0);
    final tooLong = ResourceBlockEncoder(
      resource: key,
      totalBytes: 2,
      checkAccess: () {},
      writeBlock: (_, _, _) async {
        calls++;
      },
    );
    await expectLater(tooLong.add(Uint8List(3)), throwsA(isA<SyncFailure>()));
    expect(calls, 0);
    final revoked = ResourceBlockEncoder(
      resource: key,
      totalBytes: 3,
      checkAccess: () {},
      writeBlock: (_, _, _) async {
        calls++;
      },
    );
    credentials.revoke();
    await expectLater(
      revoked.add(Uint8List(3)),
      throwsA(isA<SecurityFailure>()),
    );
    expect(calls, 0);
  });

  test('stable native handle streams a real >50 MB resource, with no whole-file plaintext allocation', () async {
    if (!Platform.isWindows) return;
    const size = 50000001;
    final source = File('${directory.path}/large-test.png');
    final output = await source.open(mode: FileMode.write);
    final block = Uint8List(1024 * 1024);
    block.setRange(0, 8, [137, 80, 78, 71, 13, 10, 26, 10]);
    var remaining = size;
    while (remaining > 0) {
      final n = remaining < block.length ? remaining : block.length;
      await output.writeFrom(block, 0, n);
      remaining -= n;
      block.fillRange(0, block.length, 57);
    }
    await output.close();
    final key = session.createResource(context());
    ResourceBlockEncoder? encoder;
    final files = <File>[];
    final token = SourceCancellation();
    final snapshot = await WindowsSourceReader().withSnapshot(
      source.path,
      directory.path,
      token,
      (s) {
        encoder!.finish();
        return s;
      },
      onOpen: (total) {
        encoder = ResourceBlockEncoder(
          resource: key,
          totalBytes: total,
          checkAccess: token.check,
          writeBlock: (index, length, cipher) async {
            final file = File('${directory.path}/large-$index.bin');
            await file.writeAsBytes(cipher, flush: true);
            files.add(file);
          },
        );
      },
      onBlock: (bytes) => encoder!.add(bytes),
    );
    expect(snapshot.size, size);
    expect(files.length, 12);
    final hash = crypto.contentHasher();
    for (var i = 0; i < files.length; i++) {
      final cipher = await files[i].readAsBytes();
      expect(cipher.length, lessThan(50000000));
      final clear = decryptResourceBlock(
        key,
        cipher,
        index: i,
        totalBytes: size,
      );
      hash.add(clear);
      clear.fillRange(0, clear.length, 0);
    }
    expect(SyncFormat.hex(await hash.close()), snapshot.fingerprint);
    key.close();
  });
}
