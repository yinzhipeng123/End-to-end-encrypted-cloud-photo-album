// Real, isolated validation for task 1.2. All credentials are artificial.
// This is not an App entry point, a replacement backend, or an access gate.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../support/tool_paths.dart';

import 'dart:typed_data';

import 'package:encrypted_photo_shared/security/photo_password.dart';
import 'package:encrypted_photo_shared/security/security_failure.dart';
import 'package:encrypted_photo_shared/security/vault_bootstrap_record.dart';
import 'package:encrypted_photo_shared/security/vault_bootstrap_store.dart';
import 'package:encrypted_photo_shared/security/vault_credentials.dart';
import 'package:encrypted_photo_shared/security/vault_crypto.dart';

const _password = 'synthetic lantern river carpet 2026';
const _wrong = 'synthetic different river carpet 2026';
final _passed = <String>[];

void _check(bool condition, String name) {
  if (!condition) throw StateError('Failed: $name');
  _passed.add(name);
}

Future<void> _failure(
  Future<Object?> action,
  SecurityFailureCode code,
  String name,
) async {
  try {
    final result = await action;
    if (result is VaultCredentialSession) result.close();
  } on SecurityFailure catch (error) {
    _check(error.code == code, name);
    return;
  }
  throw StateError('Expected failure: $name');
}

Uint8List _hex(String text) => Uint8List.fromList([
  for (var i = 0; i < text.length; i += 2)
    int.parse(text.substring(i, i + 2), radix: 16),
]);

Future<Process> _child(List<String> args) {
  // Target the VM itself so termination tests never kill only a Dart launcher.
  final vm = File(
    '${File(Platform.resolvedExecutable).parent.path}/${Platform.isWindows ? 'dartvm.exe' : 'dartvm'}',
  );
  return Process.start(
    vm.existsSync() ? vm.path : Platform.resolvedExecutable,
    ['--disable-dart-dev', Platform.script.toFilePath(), ...args],
  );
}

Future<void> _waitForKdf(VaultCrypto crypto) async {
  final watch = Stopwatch()..start();
  while (!crypto.isDeriving && watch.elapsed < const Duration(seconds: 10)) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  if (!crypto.isDeriving) throw StateError('KDF did not begin');
}

Future<void> main(List<String> args) async {
  try {
    if (args.isNotEmpty && args.first == 'child') {
      await _runChild(args.sublist(1));
      return;
    }
    await _run();
  } catch (error) {
    // Never print arbitrary exception content or a native stack with input.
    stdout.writeln(
      jsonEncode({
        'status': 'failed',
        'error_type': error.runtimeType.toString(),
        if (error is SecurityFailure) 'code': error.code.name,
        'passed': _passed,
      }),
    );
    exitCode = 1;
  }
}

Future<void> _runChild(List<String> args) async {
  final crypto = await VaultCrypto.load();
  final store = VaultBootstrapStore(File(args[1]));
  final credentials = VaultCredentials(store);
  try {
    switch (args[0]) {
      case 'open':
        final descriptor = await store.read();
        final session = await credentials.unlock(
          password: _password,
          expectedVaultId: descriptor.vaultId,
        );
        stdout.writeln(
          jsonEncode({
            'opened': !session.isClosed,
            'version': crypto.nativeVersion,
          }),
        );
      case 'create':
        stdout.writeln('ready:$pid');
        await credentials.initialize(
          password: _password,
          confirmation: _password,
        );
        stdout.writeln('committed');
        await stdin
            .first; // Parent kills a real process, never a test callback.
      case 'limited-memory':
        stdout.writeln('ready:$pid');
        await stdin.first;
        try {
          await credentials.initialize(
            password: _password,
            confirmation: _password,
          );
          stdout.writeln('unexpected-success');
          exitCode = 1;
        } on SecurityFailure catch (error) {
          stdout.writeln(
            jsonEncode({
              'code': error.code.name,
              'file_exists': await store.file.exists(),
            }),
          );
          if (error.code != SecurityFailureCode.backendFailure ||
              await store.file.exists())
            exitCode = 1;
        }
      default:
        throw StateError('Unknown isolated test mode');
    }
  } finally {
    credentials.revoke();
  }
}

Future<void> _run() async {
  final crypto = await VaultCrypto.load();
  _check(crypto.nativeVersion == '1.0.22', 'actual libsodium version');
  final dir = await ToolPaths.freshData('security', 'epa-security-probe-');
  final file = File('${dir.path}/vault.bootstrap');
  final store = VaultBootstrapStore(file);
  final credentials = VaultCredentials(store);
  final report = <String, Object?>{};
  try {
    final fixture = jsonDecode(
      await File(
        '${ToolPaths.host.path}/test/fixtures/security/bootstrap-v1.json',
      ).readAsString(),
    ) as Map<String, dynamic>;
    final bytes = PhotoPassword.encode(fixture['password'] as String);
    final passwordKey = crypto.protect(bytes);
    bytes.fillRange(0, bytes.length, 0);
    try {
      final derived = await crypto.deriveWrappingKey(
        passwordKey,
        _hex(fixture['salt_hex']),
      );
      try {
        _check(
          derived.runUnlockedSync(
            (data) => crypto.sameBytes(data, _hex(fixture['wrapping_key_hex'])),
          ),
          'independent Argon2id vector',
        );
        final record = VaultBootstrapRecord.parse(
          _hex(fixture['bootstrap_hex']),
        );
        final master = crypto.unwrap(
          wrapped: record.wrappedMaster,
          wrappingKey: derived,
          nonce: record.masterNonce,
          aad: record.masterAad(),
        );
        try {
          _check(
            master.runUnlockedSync(
              (data) => crypto.sameBytes(data, _hex(fixture['master_hex'])),
            ),
            'independent XChaCha master unwrap',
          );
          final wrapper = crypto.catalogWrappingKey(master);
          try {
            _check(
              wrapper.runUnlockedSync(
                (data) => crypto.sameBytes(
                  data,
                  _hex(fixture['catalog_wrapping_key_hex']),
                ),
              ),
              'independent BLAKE2b KDF vector',
            );
            final catalog = crypto.unwrap(
              wrapped: record.wrappedCatalog,
              wrappingKey: wrapper,
              nonce: record.catalogNonce,
              aad: record.catalogAad(),
            );
            try {
              _check(
                catalog.runUnlockedSync(
                  (data) =>
                      crypto.sameBytes(data, _hex(fixture['catalog_hex'])),
                ),
                'independent XChaCha catalog unwrap',
              );
              _check(
                crypto.sameBytes(
                  crypto.wrap(
                    material: catalog,
                    wrappingKey: wrapper,
                    nonce: record.catalogNonce,
                    aad: record.catalogAad(),
                  ),
                  record.wrappedCatalog,
                ),
                'independent XChaCha encryption result',
              );
            } finally {
              catalog.dispose();
            }
          } finally {
            wrapper.dispose();
          }
        } finally {
          master.dispose();
        }
      } finally {
        derived.dispose();
      }
    } finally {
      passwordKey.dispose();
    }

    for (final invalid in [
      'short',
      'a' * 12,
      ' ' * 12,
      'abcdefghijkl\u0000',
      'abcdefghijkl\ud800',
      '${'🌄' * 128}🌅',
    ]) {
      await _failure(
        credentials.initialize(password: invalid, confirmation: invalid),
        SecurityFailureCode.invalidPassword,
        'invalid password rejected',
      );
    }
    await _failure(
      credentials.initialize(password: _password, confirmation: _wrong),
      SecurityFailureCode.passwordMismatch,
      'confirmation rejected',
    );
    _check(!await file.exists(), 'invalid input leaves no file');
    final initial = await credentials.initialize(
      password: _password,
      confirmation: _password,
    );
    final id = initial.vaultId;
    final original = await file.readAsBytes();
    _check(original.length == 228, 'real fixed-size persisted bootstrap');
    _check(
      !latin1.decode(original).contains(_password),
      'no plaintext artificial password in persisted bytes',
    );
    credentials.revoke();
    _check(initial.isClosed, 'session revoked');
    final fixtureStore = VaultBootstrapStore(File('${dir.path}/reference'));
    final fixtureService = VaultCredentials(fixtureStore);
    try {
      final fixtureRecord = VaultBootstrapRecord.parse(
        _hex(fixture['bootstrap_hex']),
      );
      await fixtureStore.file.writeAsBytes(
        fixtureRecord.toBytes(),
        flush: true,
      );
      final opened = await fixtureService.unlock(
        password: fixture['password'],
        expectedVaultId: fixtureRecord.vaultId,
      );
      _check(
        !opened.isClosed,
        'independent fixture opens through credential service',
      );
      await _failure(
        fixtureService.unlock(
          password: (fixture['password'] as String).trim(),
          expectedVaultId: fixtureRecord.vaultId,
        ),
        SecurityFailureCode.authenticationFailed,
        'whitespace remains part of the password',
      );
    } finally {
      fixtureService.revoke();
    }

    final secondStore = VaultBootstrapStore(File('${dir.path}/second'));
    final secondService = VaultCredentials(secondStore);
    try {
      await secondService.initialize(
        password: _password,
        confirmation: _password,
      );
      final a = VaultBootstrapRecord.parse(original);
      final b = await secondStore.read();
      final publicAndWrappedFields = [
        [a.vaultId, b.vaultId],
        [a.catalogId, b.catalogId],
        [a.salt, b.salt],
        [a.masterNonce, b.masterNonce],
        [a.catalogNonce, b.catalogNonce],
        [a.wrappedMaster, b.wrappedMaster],
        [a.wrappedCatalog, b.wrappedCatalog],
      ];
      _check(
        publicAndWrappedFields.every(
          (pair) => !crypto.sameBytes(pair[0], pair[1]),
        ),
        'fresh vaults randomize IDs, salt, nonces and wraps',
      );
      await file.writeAsBytes(
        a.withCatalog(b.wrappedCatalog).toBytes(),
        flush: true,
      );
      await _failure(
        credentials.unlock(password: _password, expectedVaultId: id),
        SecurityFailureCode.authenticationFailed,
        'foreign catalog wrap rejected',
      );
      await file.writeAsBytes(original, flush: true);
    } finally {
      secondService.revoke();
    }
    await _failure(
      credentials.unlock(password: _wrong, expectedVaultId: id),
      SecurityFailureCode.authenticationFailed,
      'wrong password authenticates nothing',
    );
    await _failure(
      credentials.unlock(password: _password, expectedVaultId: Uint8List(16)),
      SecurityFailureCode.identityMismatch,
      'wrong vault identity rejected',
    );
    final child = await _child(['child', 'open', file.path]);
    final childText = child.stdout.transform(utf8.decoder).join();
    final childErr = child.stderr.drain<void>();
    _check(await child.exitCode == 0, 'separate process unlock exit');
    _check(
      jsonDecode(await childText)['opened'] == true,
      'separate process real unlock',
    );
    await childErr;
    _check(
      crypto.sameBytes(original, await file.readAsBytes()),
      'unlock does not change material',
    );

    for (final offset in [0, 8, 10, 11, 12, 13, 14, 16, 20, 22, 128]) {
      final bad = Uint8List.fromList(original)..[offset] ^= 0xff;
      await file.writeAsBytes(bad, flush: true);
      await _failure(
        store.read(),
        SecurityFailureCode.unsupportedFormat,
        'unsupported header byte $offset',
      );
    }
    for (final offset in [24, 48, 64, 80, 104, 132, 179, 180, 227]) {
      final bad = Uint8List.fromList(original)..[offset] ^= 2;
      await file.writeAsBytes(bad, flush: true);
      await _failure(
        credentials.unlock(password: _password, expectedVaultId: id),
        SecurityFailureCode.authenticationFailed,
        'authenticated header/ciphertext byte $offset',
      );
    }
    for (final length in [0, 1, 131, 180, 227]) {
      final partial = original.sublist(0, length);
      await file.writeAsBytes(partial, flush: true);
      await _failure(
        store.read(),
        SecurityFailureCode.incompleteMaterial,
        'truncated file $length',
      );
      await _failure(
        credentials.initialize(password: _password, confirmation: _password),
        SecurityFailureCode.alreadyExists,
        'partial material not overwritten $length',
      );
      _check(
        crypto.sameBytes(await file.readAsBytes(), partial),
        'partial bytes preserved $length',
      );
    }
    await file.writeAsBytes([...original, 0], flush: true);
    await _failure(
      store.read(),
      SecurityFailureCode.invalidLength,
      'trailing byte rejected',
    );
    final oversized = await file.open(mode: FileMode.write);
    await oversized.truncate(16 * 1024 * 1024);
    await oversized.close();
    await _failure(
      store.read(),
      SecurityFailureCode.invalidLength,
      'oversized file rejected without full allocation',
    );
    await file.writeAsBytes(original, flush: true);
    await _failure(
      credentials.initialize(password: _password, confirmation: _password),
      SecurityFailureCode.alreadyExists,
      'valid existing material not overwritten',
    );

    final badStore = VaultCredentials(
      VaultBootstrapStore(File('${dir.path}/missing/vault')),
    );
    try {
      await _failure(
        badStore.initialize(password: _password, confirmation: _password),
        SecurityFailureCode.storageFailure,
        'actual filesystem failure has no success',
      );
    } finally {
      badStore.revoke();
    }

    final cancelledFile = File('${dir.path}/cancelled');
    final cancelled = VaultCredentials(VaultBootstrapStore(cancelledFile));
    try {
      final pending = _failure(
        cancelled.initialize(password: _password, confirmation: _password),
        SecurityFailureCode.cancelled,
        'late KDF result cannot authorize',
      );
      await _waitForKdf(crypto);
      await _failure(
        cancelled.initialize(password: _password, confirmation: _password),
        SecurityFailureCode.busy,
        'overlapping credential operation rejected',
      );
      final probePassword = crypto.protect(PhotoPassword.encode(_password));
      try {
        await _failure(
          crypto.deriveWrappingKey(probePassword, crypto.randomBytes(16)),
          SecurityFailureCode.busy,
          'client KDF gate rejects concurrent derivation',
        );
      } finally {
        probePassword.dispose();
      }
      cancelled.revoke();
      await pending;
      _check(!await cancelledFile.exists(), 'cancelled KDF creates no file');
    } finally {
      cancelled.revoke();
    }

    final raceStore = VaultBootstrapStore(File('${dir.path}/race'));
    final raceRecord = VaultBootstrapRecord.parse(original);
    final results = await Future.wait(
      List.generate(8, (_) async {
        try {
          await raceStore.create(raceRecord);
          return 'created';
        } on SecurityFailure catch (error) {
          return error.code.name;
        }
      }),
    );
    _check(
      results.where((r) => r == 'created').length == 1 &&
          results.where((r) => r == 'alreadyExists').length == 7,
      'OS exclusive creation has exactly one winner',
    );
    _check(
      crypto.sameBytes(await raceStore.file.readAsBytes(), original),
      'concurrent creation preserves winning bytes',
    );

    final interruptionResults = <Map<String, Object?>>[];
    for (final delay in [0, 10, 80, 200, 600]) {
      final path = '${dir.path}/interrupted-$delay';
      final worker = await _child(['child', 'create', path]);
      final ready = Completer<void>();
      final output = <String>[];
      final sub = worker.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            output.add(line);
            if (line.startsWith('ready:') && !ready.isCompleted) {
              if (line == 'ready:${worker.pid}') {
                ready.complete();
              } else {
                ready.completeError(
                  StateError('Termination target is not the actual VM'),
                );
              }
            }
          });
      final errors = worker.stderr.drain<void>();
      try {
        await ready.future.timeout(const Duration(seconds: 20));
        await Future<void>.delayed(Duration(milliseconds: delay));
        worker.kill();
        await worker.exitCode;
        final interrupted = File(path);
        final length = await interrupted.exists()
            ? await interrupted.length()
            : null;
        if (length != null) {
          final before = await interrupted.readAsBytes();
          final service = VaultCredentials(VaultBootstrapStore(interrupted));
          try {
            await _failure(
              service.initialize(password: _password, confirmation: _password),
              SecurityFailureCode.alreadyExists,
              'interrupted material is never replaced $delay',
            );
            _check(
              crypto.sameBytes(before, await interrupted.readAsBytes()),
              'interrupted bytes preserved $delay',
            );
            if (length == 228) {
              final descriptor = await VaultBootstrapStore(interrupted).read();
              final session = await service.unlock(
                password: _password,
                expectedVaultId: descriptor.vaultId,
              );
              _check(
                !session.isClosed,
                'committed material survives process termination $delay',
              );
            }
          } finally {
            service.revoke();
          }
        }
        interruptionResults.add({
          'delay_ms': delay,
          'persisted_bytes': length,
          'child_reported_commit': output.contains('committed'),
        });
      } finally {
        worker.kill();
        await sub.cancel();
        await errors;
      }
    }
    report['process_interruption'] = interruptionResults;

    final durations = <double>[];
    final encoded = PhotoPassword.encode(_password);
    final protected = crypto.protect(encoded);
    encoded.fillRange(0, encoded.length, 0);
    var ticks = 0;
    final timer = Timer.periodic(
      const Duration(milliseconds: 5),
      (_) => ticks++,
    );
    final rssBefore = ProcessInfo.currentRss;
    try {
      for (var i = 0; i < 20; i++) {
        final watch = Stopwatch()..start();
        final key = await crypto.deriveWrappingKey(
          protected,
          crypto.randomBytes(16),
        );
        durations.add(watch.elapsedMicroseconds / 1000);
        key.dispose();
      }
      _check(ticks > 0, 'event loop runs during KDF');
      final sorted = [...durations]..sort();
      _check(sorted[18] <= 5000, 'Windows 20-sample p95 <= 5 seconds');
      report['kdf'] = {
        'count': 20,
        'milliseconds': durations,
        'p95_ms': sorted[18],
        'rss_before_bytes': rssBefore,
        'process_peak_rss_bytes': ProcessInfo.maxRss,
        'event_loop_ticks': ticks,
      };
    } finally {
      timer.cancel();
      protected.dispose();
    }
    report.addAll({
      'status': 'passed',
      'scope': 'Windows isolated real credential service only',
      'native_version': crypto.nativeVersion,
      'os': Platform.operatingSystemVersion,
      'dart': Platform.version,
      'passed_count': _passed.length,
      'passed': _passed,
      'ios': 'not executed',
      'flutter_app_integration': 'not executed',
    });
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
  } finally {
    credentials.revoke();
    // Only the exact temporary directory created by this invocation is removed.
    await dir.delete(recursive: true);
  }
}
