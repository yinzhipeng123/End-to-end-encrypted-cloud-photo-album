import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:encrypted_photo_app/services/import/windows_source_reader.dart';
import 'package:encrypted_photo_app/security/windows_data_protection.dart';

void main() {
  if (!Platform.isWindows) return;
  WindowsSourceReader.setTestLibrary(
    File('build/source-reader/Release/epa_source_reader.dll').absolute.path,
  );
  late Directory root;
  late File file;
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=',
  );
  final reader = WindowsSourceReader();
  Future<SourceSnapshot> read([File? value]) => reader.withSnapshot(
    (value ?? file).path,
    root.path,
    SourceCancellation(),
    (s) => s,
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('epa-source-reader-');
    file = File('${root.path}/真实 来源.png');
    await file.writeAsBytes(png);
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('actual full read records native identity, bytes and stable content version', () async {
    final one = await read();
    final two = await read();
    expect(one.identity, isNotNull);
    expect(one.identity, two.identity);
    expect(one.version, two.version);
    expect(one.size, png.length);
    expect(one.format, 'PNG');
    expect(one.fingerprint.length, 64);
    // Independent Python hashlib.blake2b(digest_size=32) reference.
    expect(
      one.fingerprint,
      '2b890b9ce1fd8f99a5d1658edbc62787ac00553ec3fa4d7f08476e1dd21eb8bc',
    );
    expect(await file.readAsBytes(), png);
  });
  test(
    'same-volume rename keeps identity; independent copy does not',
    () async {
      final before = await read();
      file = await file.rename('${root.path}/改名.png');
      final renamed = await read();
      final copied = await file.copy('${root.path}/副本.png');
      expect(renamed.identity, before.identity);
      expect((await read(copied)).identity, isNot(before.identity));
      expect((await read(copied)).fingerprint, before.fingerprint);
    },
  );
  test('active writable handle cannot be imported', () async {
    final writer = await file.open(mode: FileMode.append);
    try {
      await expectLater(
        read(),
        throwsA(
          isA<SourceFailure>().having(
            (e) => e.code,
            'code',
            SourceFailureCode.busy,
          ),
        ),
      );
    } finally {
      await writer.close();
    }
    expect((await read()).size, png.length);
  });
  test(
    'write and rename are prevented until encrypted-consumer boundary returns',
    () async {
      await reader.withSnapshot(file.path, root.path, SourceCancellation(), (
        s,
      ) async {
        await expectLater(
          file.open(mode: FileMode.append),
          throwsA(isA<FileSystemException>()),
        );
        await expectLater(
          file.rename('${root.path}/blocked.png'),
          throwsA(isA<FileSystemException>()),
        );
      });
      file = await file.rename('${root.path}/allowed.png');
      expect(await file.readAsBytes(), png);
    },
  );
  test(
    'multi-block stream cancellation closes handles and never publishes',
    () async {
      final bytes = Uint8List(5 * 1024 * 1024)..setRange(0, png.length, png);
      await file.writeAsBytes(bytes);
      final token = SourceCancellation();
      var consumed = false;
      await expectLater(
        reader.withSnapshot(file.path, root.path, token, (_) {
          consumed = true;
        }, onProgress: (_) => token.cancel()),
        throwsA(
          isA<SourceFailure>().having(
            (e) => e.code,
            'code',
            SourceFailureCode.cancelled,
          ),
        ),
      );
      expect(consumed, false);
      file = await file.rename('${root.path}/released.png');
      expect(await file.length(), bytes.length);
    },
  );
  test(
    'same-size replacement bytes have a different complete fingerprint',
    () async {
      final one = await read();
      final modified = Uint8List.fromList(png)..[30] ^= 1;
      await file.writeAsBytes(modified);
      final two = await read();
      expect(one.size, two.size);
      expect(one.fingerprint, isNot(two.fingerprint));
    },
  );
  test('multi-block full read matches independent BLAKE2b reference', () async {
    final bytes = Uint8List(6 * 1024 * 1024)..setRange(0, png.length, png);
    await file.writeAsBytes(bytes);
    final snapshot = await read();
    expect(snapshot.size, bytes.length);
    expect(
      snapshot.fingerprint,
      '034b0830d33ebfeb6b30effc5fceecf660a59f4bda2264a0f8fb875fa564ce91',
    );
  });

  test('consumer failure releases native handles', () async {
    await expectLater(
      reader.withSnapshot(
        file.path,
        root.path,
        SourceCancellation(),
        (_) => throw StateError('injected commit failure'),
      ),
      throwsStateError,
    );
    file = await file.rename('${root.path}/released-after-error.png');
    expect(await file.readAsBytes(), png);
  });
  test('zero length and extension disguise are not accepted', () async {
    await file.writeAsBytes([]);
    await expectLater(read(), throwsA(isA<SourceFailure>()));
    await file.writeAsString('not an image');
    await expectLater(
      read(),
      throwsA(
        isA<SourceFailure>().having(
          (e) => e.code,
          'code',
          SourceFailureCode.unsupported,
        ),
      ),
    );
  });
  test('root escape and device/network namespaces are rejected', () async {
    await expectLater(
      reader.withSnapshot(
        file.path,
        '${root.path}/elsewhere',
        SourceCancellation(),
        (_) {},
      ),
      throwsA(isA<SourceFailure>()),
    );
    expect(
      () => WindowsSourceReader.absolute(r'\\server\share\file.png'),
      throwsA(isA<SourceFailure>()),
    );
    expect(
      () => WindowsSourceReader.absolute('${file.path}:stream'),
      throwsA(isA<SourceFailure>()),
    );
  });
  test('capture is bounded and contains actual source bytes', () async {
    await reader.withSnapshot(file.path, root.path, SourceCancellation(), (s) {
      expect(s.previewBytes, png);
    }, captureLimit: png.length);
    await reader.withSnapshot(file.path, root.path, SourceCancellation(), (s) {
      expect(s.previewBytes, isNull);
    }, captureLimit: png.length - 1);
  });

  test(
    'actual NTFS deny-read permission fails without modifying source',
    () async {
      final sid = WindowsDataProtection().currentUserSid;
      final denied = await Process.run('icacls', [
        file.path,
        '/deny',
        '*$sid:(R)',
      ]);
      expect(denied.exitCode, 0);
      try {
        await expectLater(read(), throwsA(isA<SourceFailure>()));
      } finally {
        final restored = await Process.run('icacls', [
          file.path,
          '/remove:d',
          '*$sid',
        ]);
        expect(restored.exitCode, 0);
      }
      expect(await file.readAsBytes(), png);
    },
  );

  test('drive root can be validated without enumerating unrelated files', () {
    final drive = WindowsSourceReader.absolute(root.path).substring(0, 3);
    expect(WindowsSourceReader.validateDirectory(drive), drive);
  });

  test('large paused writer is rejected and real streaming cancellation releases within budget', () async {
    final writer = await file.open(mode: FileMode.write);
    final block = Uint8List(1024 * 1024)..setRange(0, png.length, png);
    try {
      for (var i = 0; i < 64; i++) {
        await writer.writeFrom(block);
      }
      await writer.flush();
      await expectLater(
        read(),
        throwsA(
          isA<SourceFailure>().having(
            (e) => e.code,
            'code',
            SourceFailureCode.busy,
          ),
        ),
      );
    } finally {
      await writer.close();
    }
    final token = SourceCancellation();
    final elapsed = Stopwatch();
    var largestRead = 0;
    await expectLater(
      reader.withSnapshot(
        file.path,
        root.path,
        token,
        (_) => fail('Cancelled large file must not publish'),
        onProgress: (bytes) {
          largestRead = bytes;
          elapsed.start();
          token.cancel();
        },
      ),
      throwsA(
        isA<SourceFailure>().having(
          (e) => e.code,
          'code',
          SourceFailureCode.cancelled,
        ),
      ),
    );
    elapsed.stop();
    expect(largestRead, WindowsSourceReader.blockSize);
    expect(elapsed.elapsed, lessThan(const Duration(seconds: 2)));
    file = await file.rename('${root.path}/cancelled-large.png');
  });

  test('hard links retain identity; a junction to outside the chosen root is rejected', () async {
    final hard = File('${root.path}/hard.png');
    final linked = await Process.run('fsutil', [
      'hardlink',
      'create',
      hard.path,
      file.path,
    ]);
    expect(linked.exitCode, 0);
    expect((await read(hard)).identity, (await read()).identity);
    final outside = await Directory.systemTemp.createTemp('epa-outside-');
    final junction = Link('${root.path}/junction');
    try {
      await File('${outside.path}/outside.png').writeAsBytes(png);
      final made = await Process.run('cmd', [
        '/c',
        'mklink',
        '/J',
        WindowsSourceReader.absolute(junction.path),
        WindowsSourceReader.absolute(outside.path),
      ]);
      expect(made.exitCode, 0);
      await expectLater(
        read(File('${junction.path}/outside.png')),
        throwsA(isA<SourceFailure>()),
      );
    } finally {
      if (await junction.exists()) await junction.delete();
      await outside.delete(recursive: true);
    }
  });
}
