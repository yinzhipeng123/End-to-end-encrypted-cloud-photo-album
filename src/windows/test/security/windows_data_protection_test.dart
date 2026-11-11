import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:encrypted_photo_shared/security/security_failure.dart';
import 'package:encrypted_photo_app/security/windows_data_protection.dart';
import 'package:encrypted_photo_app/security/windows_protected_store.dart';
import 'package:flutter_test/flutter_test.dart';

Matcher failure(SecurityFailureCode code) =>
    throwsA(isA<SecurityFailure>().having((e) => e.code, 'code', code));

void main() {
  if (!Platform.isWindows) return;
  late Directory scratch;
  late Directory private;
  late WindowsDataProtection native;
  late WindowsProtectedStore store;
  final clear = Uint8List.fromList(List.generate(96, (i) => i + 7));
  final binding = Uint8List.fromList(List.generate(48, (i) => i));

  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('epa-dpapi-test-');
    private = Directory('${scratch.path}/private');
    native = WindowsDataProtection();
    store = WindowsProtectedStore(private, native);
    await store.initialize();
  });
  tearDown(() async {
    await scratch.delete(recursive: true);
  });

  test(
    'real DPAPI seals and authenticates bytes in current Windows user scope',
    () {
      final sealed = native.seal(clear, binding);
      expect(sealed, isNot(clear));
      expect(native.unseal(sealed, binding), clear);
      expect(native.currentUserSid, startsWith('S-1-'));
      final second = native.seal(clear, binding);
      expect(second, isNot(sealed));
    },
  );

  test('wrong binding and modified protected bytes fail without returning plaintext', () {
    final sealed = native.seal(clear, binding);
    final changed = Uint8List.fromList(binding)..[0] ^= 1;
    expect(
      () => native.unseal(sealed, changed),
      failure(SecurityFailureCode.authenticationFailed),
    );
    sealed[sealed.length - 1] ^= 1;
    expect(
      () => native.unseal(sealed, binding),
      failure(SecurityFailureCode.authenticationFailed),
    );
  });

  test(
    'real persisted records reopen and namespaces cannot be swapped',
    () async {
      await store.write('pin', clear, binding);
      final second = WindowsProtectedStore(private, WindowsDataProtection());
      expect(await second.read('pin', binding), clear);
      final file = File('${private.path}/pin.sealed');
      expect(await file.readAsBytes(), isNot(clear));
      await File('${private.path}/state.sealed')
          .writeAsBytes(await file.readAsBytes(), flush: true);
      await expectLater(
        second.read('state', binding),
        failure(SecurityFailureCode.authenticationFailed),
      );
      final changed = Uint8List.fromList(binding)..[1] ^= 1;
      await expectLater(
        second.read('pin', changed),
        failure(SecurityFailureCode.authenticationFailed),
      );
    },
  );

  test(
    'updates replace a sealed file, invalid update preserves prior material',
    () async {
      await store.write('state', clear, binding);
      final next = Uint8List.fromList(clear)..[0] ^= 3;
      await store.write('state', next, binding);
      expect(await store.read('state', binding), next);
      final file = File('${private.path}/state.sealed');
      final before = await file.readAsBytes();
      await expectLater(
        store.write('state', Uint8List(0), binding),
        failure(SecurityFailureCode.invalidLength),
      );
      expect(await file.readAsBytes(), before);
      expect(
        await private.list().where((e) => e.path.endsWith('.pending')).toList(),
        isEmpty,
      );
    },
  );

  test(
    'missing or removed system material never produces a default unlock value',
    () async {
      expect(await store.read('missing', binding), isNull);
      await store.write('auxiliary', clear, binding);
      await store.remove('auxiliary');
      expect(await store.read('auxiliary', binding), isNull);
      expect(await File('${private.path}/auxiliary.sealed').exists(), isFalse);
    },
  );

  test('private root and child ACLs are checked; ordinary inherited root is rejected', () async {
    native.validatePrivatePath(private.path, directory: true);
    await store.write('state', clear, binding);
    native.validatePrivatePath('${private.path}/state.sealed');
    final public = await Directory('${scratch.path}/ordinary').create();
    expect(
      () => native.validatePrivatePath(public.path, directory: true),
      failure(SecurityFailureCode.storageFailure),
    );
    final old = File('${public.path}/sentinel')
      ..writeAsStringSync('artificial sentinel');
    expect(
      () => native.preparePrivateDirectory(public.path),
      failure(SecurityFailureCode.storageFailure),
    );
    expect(await old.readAsString(), 'artificial sentinel');
  });

  test(
    'unsafe names, overlong records and corrupt material fail closed',
    () async {
      await expectLater(
        store.write('../other', clear, binding),
        failure(SecurityFailureCode.invalidLength),
      );
      await File('${private.path}/state.sealed')
          .writeAsBytes(Uint8List(1024 * 1024 + 2), flush: true);
      await expectLater(
        store.read('state', binding),
        failure(SecurityFailureCode.invalidLength),
      );
      expect(
        () => native.seal(clear, Uint8List(0)),
        failure(SecurityFailureCode.invalidLength),
      );
    },
  );

  test('actual anonymous Windows token cannot decrypt current-user sealed material', () {
    final sealed = native.seal(clear, binding);
    final kernel = DynamicLibrary.open('kernel32.dll');
    final advapi = DynamicLibrary.open('advapi32.dll');
    final thread = kernel
        .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
          'GetCurrentThread',
        );
    final impersonate = advapi
        .lookupFunction<
          Int32 Function(Pointer<Void>),
          int Function(Pointer<Void>)
        >('ImpersonateAnonymousToken');
    final revert = advapi.lookupFunction<Int32 Function(), int Function()>(
      'RevertToSelf',
    );
    expect(impersonate(thread()), isNot(0));
    Object? failureResult;
    var restored = false;
    try {
      try {
        native.unseal(sealed, binding);
      } catch (error) {
        failureResult = error;
      }
    } finally {
      restored = revert() != 0;
    }
    // No await, filesystem or test-framework callback while impersonating.
    expect(restored, isTrue);
    expect(
      failureResult,
      isA<SecurityFailure>().having(
        (e) => e.code,
        'code',
        SecurityFailureCode.authenticationFailed,
      ),
    );
    expect(native.unseal(sealed, binding), clear);
  });

  test('Windows monotonic clock advances and has millisecond units', () async {
    final before = native.monotonicMilliseconds();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(native.monotonicMilliseconds() - before, inInclusiveRange(30, 5000));
  });
}
