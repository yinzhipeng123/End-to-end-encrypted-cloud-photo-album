import 'dart:io';
import 'dart:typed_data';

import 'package:encrypted_photo_shared/security/pin_gate.dart';
import 'package:encrypted_photo_shared/security/reverification_gate.dart';
import 'package:encrypted_photo_shared/security/security_failure.dart';
import 'package:encrypted_photo_shared/security/vault_bootstrap_store.dart';
import 'package:encrypted_photo_shared/security/vault_credentials.dart';
import 'package:encrypted_photo_app/security/windows_data_protection.dart';
import 'package:encrypted_photo_app/security/windows_protected_store.dart';
import 'package:flutter_test/flutter_test.dart';

Matcher failure(SecurityFailureCode code) =>
    throwsA(isA<SecurityFailure>().having((e) => e.code, 'code', code));

void main() {
  if (!Platform.isWindows) return;
  late Directory scratch;
  late WindowsProtectedStore store;
  late VaultCredentials credentials;
  late PinGate pins;
  late ReverificationGate gate;
  late _Clock clock;
  late Uint8List vaultId;
  final binding = Uint8List.fromList(List.generate(32, (i) => i));
  const password = 'artificial river lantern carpet';
  const pin = '7392';

  ReverificationGate freshGate({Uint8List? identity, int generation = 1}) =>
      ReverificationGate(
        store: store,
        credentials: credentials,
        pinGate: pins,
        clock: clock,
        binding: identity ?? binding,
        vaultId: vaultId,
        wrappingGeneration: generation,
      );

  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('epa-reverification-test-');
    store = WindowsProtectedStore(
      Directory('${scratch.path}/private'),
      WindowsDataProtection(),
    );
    await store.initialize();
    credentials = VaultCredentials(
      VaultBootstrapStore(File('${store.directory.path}/vault.bootstrap')),
    );
    final session = await credentials.initialize(
      password: password,
      confirmation: password,
    );
    vaultId = session.vaultId;
    clock = _Clock();
    pins = PinGate(store, binding);
    await pins.configure(pin);
    gate = freshGate();
    await gate.recordPhotoAuthentication(session);
    gate.lock();
  });
  tearDown(() async {
    gate.lock();
    await scratch.delete(recursive: true);
  });

  test('real DPAPI auxiliary opens only after actual PIN and cannot prove photo authentication', () async {
    final expiration = gate.state!.expiresAt;
    final session = await gate.unlockWithPin(pin);
    expect(session.isClosed, isFalse);
    expect(session.authenticatedByPhotoPassword, isFalse);
    expect(gate.session, same(session));
    await expectLater(
      gate.recordPhotoAuthentication(session),
      failure(SecurityFailureCode.photoPasswordRequired),
    );
    expect(gate.state!.expiresAt, expiration);
    gate.lock();
    expect(session.isClosed, isTrue);
    expect(() => gate.session, failure(SecurityFailureCode.accessDenied));
  });

  test(
    'fresh service load and PIN do not extend the stored 72-hour deadline',
    () async {
      final expires = gate.state!.expiresAt;
      clock.advance(10000);
      gate = freshGate();
      await gate.load();
      expect(gate.requiresPhotoPassword, isFalse);
      expect(() => gate.session, failure(SecurityFailureCode.accessDenied));
      await gate.unlockWithPin(pin);
      expect(gate.state!.expiresAt, expires);
    },
  );

  test(
    'deadline boundary revokes actual sessions and clears auxiliary material',
    () async {
      clock.advance(ReverificationGate.durationMillis - 1);
      final session = await gate.unlockWithPin(pin);
      clock.advance(1);
      await expectLater(
        gate.checkpoint(),
        failure(SecurityFailureCode.photoPasswordRequired),
      );
      expect(session.isClosed, isTrue);
      expect(
        await File('${store.directory.path}/auxiliary.sealed').exists(),
        isFalse,
      );
      await expectLater(
        gate.unlockWithPin(pin),
        failure(SecurityFailureCode.photoPasswordRequired),
      );
    },
  );

  test(
    'expired service requires real correct photo password before a new period',
    () async {
      clock.advance(ReverificationGate.durationMillis);
      await expectLater(
        gate.checkpoint(),
        failure(SecurityFailureCode.photoPasswordRequired),
      );
      await expectLater(
        gate.authenticatePhotoPassword('artificial incorrect password'),
        failure(SecurityFailureCode.authenticationFailed),
      );
      expect(gate.requiresPhotoPassword, isTrue);
      final authenticated = await gate.authenticatePhotoPassword(password);
      await gate.recordPhotoAuthentication(authenticated);
      await pins.clearFailuresAfterPhotoAuthentication();
      gate.lock();
      expect(() => gate.session, failure(SecurityFailureCode.accessDenied));
      await gate.unlockWithPin(pin);
      expect(gate.state!.lastPhotoAuthentication, clock.utc);
      expect(
        gate.state!.expiresAt,
        clock.utc + ReverificationGate.durationMillis,
      );
    },
  );

  test(
    'one old photo-password result cannot repeatedly extend the deadline',
    () async {
      final authenticated = await gate.authenticatePhotoPassword(password);
      await gate.recordPhotoAuthentication(authenticated);
      final deadline = gate.state!.expiresAt;
      clock.advance(10000);
      await expectLater(
        gate.recordPhotoAuthentication(authenticated),
        failure(SecurityFailureCode.photoPasswordRequired),
      );
      expect(gate.state!.expiresAt, deadline);
    },
  );

  test('large UTC rollback and runtime monotonic disagreement force a photo password', () async {
    final session = await gate.unlockWithPin(pin);
    clock.utc -= 60001;
    expect(gate.requiresPhotoPassword, isTrue);
    expect(session.isClosed, isTrue);
    clock.utc += 60001;
    await expectLater(
      gate.unlockWithPin(pin),
      failure(SecurityFailureCode.photoPasswordRequired),
    );
  });

  test(
    'small rollback never decreases maximum observed UTC or extends expiration',
    () async {
      clock.advance(40000);
      await gate.checkpoint();
      final maximum = gate.state!.maximumUtc;
      final expiration = gate.state!.expiresAt;
      clock.utc -= 30000;
      await gate.checkpoint();
      expect(gate.state!.maximumUtc, maximum);
      expect(gate.state!.expiresAt, expiration);
    },
  );

  test('negative or stalled monotonic clock and changed bootstrap generation deny PIN access', () async {
    clock.ticks += 60001;
    await expectLater(
      gate.checkpoint(),
      failure(SecurityFailureCode.photoPasswordRequired),
    );
    gate = freshGate(generation: 2);
    await gate.load();
    expect(gate.requiresPhotoPassword, isTrue);
  });

  test('missing or corrupt deadline and changed installation binding never create a fresh period', () async {
    await store.remove('access-state');
    gate = freshGate();
    await gate.load();
    expect(gate.requiresPhotoPassword, isTrue);
    await expectLater(
      gate.unlockWithPin(pin),
      failure(SecurityFailureCode.photoPasswordRequired),
    );
    await store.write('access-state', Uint8List.fromList([1, 2, 3]), binding);
    gate = freshGate();
    await gate.load();
    expect(gate.requiresPhotoPassword, isTrue);
    gate = freshGate(identity: Uint8List.fromList(binding)..[0] ^= 1);
    await gate.load();
    expect(gate.requiresPhotoPassword, isTrue);
  });

  test('correct PIN with missing or damaged auxiliary requires photo authentication', () async {
    await store.remove('auxiliary');
    await expectLater(
      gate.unlockWithPin(pin),
      failure(SecurityFailureCode.photoPasswordRequired),
    );
    expect(gate.requiresPhotoPassword, isTrue);
    expect(() => gate.session, failure(SecurityFailureCode.accessDenied));
  });

  test(
    'photo-password retry limits persist and use exact capped delays',
    () async {
      for (var attempt = 1; attempt <= 11; attempt++) {
        await expectLater(
          gate.authenticatePhotoPassword('artificial wrong password'),
          failure(SecurityFailureCode.authenticationFailed),
        );
        if (attempt >= 5) {
          final seconds = attempt >= 10 ? 900 : 30 * (1 << (attempt - 5));
          await expectLater(
            gate.authenticatePhotoPassword(password),
            failure(SecurityFailureCode.retryLater),
          );
          clock.advance(seconds * 1000);
        }
      }
      final authenticated = await gate.authenticatePhotoPassword(password);
      expect(authenticated.authenticatedByPhotoPassword, isTrue);
    },
  );

  test(
    'lock during actual password derivation rejects the late result',
    () async {
      final pending = gate.authenticatePhotoPassword(password);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      gate.lock();
      await expectLater(pending, failure(SecurityFailureCode.cancelled));
      expect(() => gate.session, failure(SecurityFailureCode.accessDenied));
    },
  );
}

/// Deterministic boundary clock only. Credential, DPAPI and disk work are real;
/// production uses Windows GetTickCount64, not this test implementation.
final class _Clock implements SecurityClock {
  int utc = 1700000000000;
  int ticks = 100000;
  @override
  int utcMilliseconds() => utc;
  @override
  int monotonicMilliseconds() => ticks;
  void advance(int milliseconds) {
    utc += milliseconds;
    ticks += milliseconds;
  }
}
