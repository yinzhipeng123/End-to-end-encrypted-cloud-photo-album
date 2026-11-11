import 'dart:io';
import 'dart:typed_data';

import 'package:encrypted_photo_shared/security/pin_gate.dart';
import 'package:encrypted_photo_shared/security/protected_record_store.dart';
import 'package:encrypted_photo_shared/security/security_failure.dart';
import 'package:encrypted_photo_app/security/windows_data_protection.dart';
import 'package:encrypted_photo_app/security/windows_protected_store.dart';
import 'package:flutter_test/flutter_test.dart';

Matcher failure(SecurityFailureCode code) =>
    throwsA(isA<SecurityFailure>().having((e) => e.code, 'code', code));

void main() {
  if (!Platform.isWindows) return;
  late Directory scratch;
  late WindowsProtectedStore store;
  late PinGate gate;
  final binding = Uint8List.fromList(List.generate(32, (i) => i));
  const pin = '7392';
  const now = 1700000000000;
  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('epa-pin-test-');
    store = WindowsProtectedStore(
      Directory('${scratch.path}/private'),
      WindowsDataProtection(),
    );
    await store.initialize();
    gate = PinGate(store, binding);
    await gate.configure(pin);
  });
  tearDown(() async {
    await scratch.delete(recursive: true);
  });

  test('real PIN verifier accepts exactly configured ASCII digits and rejects wrong PIN', () async {
    await gate.verify(pin, now);
    await expectLater(
      gate.verify('1111', now),
      failure(SecurityFailureCode.authenticationFailed),
    );
    expect((await gate.retryState()).attempts, 1);
    await gate.verify(pin, now);
    expect((await gate.retryState()).attempts, 0);
    for (final invalid in ['123', '12345', '１２３４', '12a4', ' 1234']) {
      await expectLater(
        gate.verify(invalid, now),
        failure(SecurityFailureCode.invalidPin),
      );
    }
    expect((await gate.retryState()).attempts, 0);
  });

  test('5th through 9th errors persist exact increasing delays and 10th requires photo password', () async {
    var time = now;
    for (var attempt = 1; attempt <= 10; attempt++) {
      await expectLater(
        gate.verify('0000', time),
        failure(
          attempt == 10
              ? SecurityFailureCode.photoPasswordRequired
              : SecurityFailureCode.authenticationFailed,
        ),
      );
      final persisted = PinGate(store, binding);
      final state = await persisted.retryState();
      expect(state.attempts, attempt);
      if (attempt >= 5 && attempt < 10) {
        expect(state.retryAtUtcMillis - time, 30000 * (1 << (attempt - 5)));
        await expectLater(
          persisted.verify(pin, state.retryAtUtcMillis - 1),
          failure(SecurityFailureCode.retryLater),
        );
        expect((await persisted.retryState()).attempts, attempt);
        time = state.retryAtUtcMillis;
      }
      gate = persisted;
    }
    await expectLater(
      gate.verify(pin, time + 999999),
      failure(SecurityFailureCode.photoPasswordRequired),
    );
  });

  test('correct PIN on the 10th admitted attempt clears failures; waiting never admits an attempt', () async {
    var time = now;
    for (var i = 0; i < 9; i++) {
      await expectLater(
        gate.verify('0000', time),
        failure(SecurityFailureCode.authenticationFailed),
      );
      time = (await gate.retryState()).retryAtUtcMillis > time
          ? (await gate.retryState()).retryAtUtcMillis
          : time;
    }
    await gate.verify(pin, time);
    expect((await gate.retryState()).attempts, 0);
  });

  test(
    'PIN reset changes actual verifier and preserves unrelated sealed records',
    () async {
      await store.write('unrelated', Uint8List.fromList([1, 2, 3]), binding);
      await gate.configure('8642');
      await expectLater(
        gate.verify(pin, now),
        failure(SecurityFailureCode.authenticationFailed),
      );
      await gate.verify('8642', now);
      expect(await store.read('unrelated', binding), [1, 2, 3]);
      final verifier = await store.read('pin', binding);
      expect(verifier!.length, 88);
      // The verifier is keyed BLAKE2b data, not a stored PIN string.
      expect(String.fromCharCodes(verifier), isNot(contains('8642')));
      verifier.fillRange(0, verifier.length, 0);
    },
  );

  test(
    'missing verifier or retry state cannot reset into PIN access',
    () async {
      await store.remove('pin-retry');
      await expectLater(
        gate.verify(pin, now),
        failure(SecurityFailureCode.photoPasswordRequired),
      );
      await gate.configure(pin);
      await store.remove('pin');
      await expectLater(
        gate.verify(pin, now),
        failure(SecurityFailureCode.photoPasswordRequired),
      );
    },
  );

  test('attempt-state write failure denies even a correct PIN', () async {
    gate = PinGate(_FaultStore(store, failWrite: true), binding);
    await expectLater(
      gate.verify(pin, now),
      failure(SecurityFailureCode.storageFailure),
    );
    expect((await PinGate(store, binding).retryState()).attempts, 0);
  });

  test(
    'revoked in-flight PIN cannot release a successful verification',
    () async {
      final wrapper = _FaultStore(store);
      gate = PinGate(wrapper, binding);
      wrapper.afterWrite = gate.revoke;
      await expectLater(
        gate.verify(pin, now),
        failure(SecurityFailureCode.cancelled),
      );
      expect((await PinGate(store, binding).retryState()).attempts, 1);
    },
  );
}

/// Fault injection around real disk/DPAPI, only in isolated tests.
final class _FaultStore implements ProtectedRecordStore {
  _FaultStore(this.real, {this.failWrite = false});
  final ProtectedRecordStore real;
  final bool failWrite;
  void Function()? afterWrite;
  @override
  Future<Uint8List?> read(String name, Uint8List binding) =>
      real.read(name, binding);
  @override
  Future<void> remove(String name) => real.remove(name);
  @override
  Future<void> write(String name, Uint8List clear, Uint8List binding) async {
    if (failWrite)
      throw const SecurityFailure(SecurityFailureCode.storageFailure);
    await real.write(name, clear, binding);
    afterWrite?.call();
  }
}
