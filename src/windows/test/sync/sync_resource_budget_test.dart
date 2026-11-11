import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:encrypted_photo_shared/security/vault_bootstrap_store.dart';
import 'package:encrypted_photo_shared/security/vault_credentials.dart';
import 'package:encrypted_photo_shared/security/vault_crypto.dart';
import 'package:encrypted_photo_app/security/windows_data_protection.dart';
import 'package:encrypted_photo_app/services/import/windows_import_service.dart';
import 'package:encrypted_photo_app/services/import/windows_source_reader.dart';
import 'package:encrypted_photo_app/storage/library_catalog.dart';
import 'package:encrypted_photo_shared/sync/sync_format.dart';
import 'package:encrypted_photo_app/sync/sync_object_store.dart';
import 'package:encrypted_photo_app/sync/sync_resource_preparer.dart';

import '../services/windows_import_service_test.dart' show until;

void main() {
  if (!Platform.isWindows) return;
  test('real >50 MB resource encryption, disk blocks, bytewise recovery and incremental RSS budget', () async {
    WindowsSourceReader.setTestLibrary(
      File('build/source-reader/Release/epa_source_reader.dll').absolute.path,
    );
    final scratch = await Directory.systemTemp.createTemp('epa-sync-budget-');
    final photos = await Directory('${scratch.path}/photos').create();
    final original = File('${photos.path}/artificial-video.avi');
    // Reproducible uncompressed RGB24 AVI; transport test, not codec acceptance.
    final output = await original.open(mode: FileMode.writeOnly);
    const length = 51905272;
    Uint8List ints(List<int> values) {
      final data = ByteData(values.length * 4);
      for (var i = 0; i < values.length; i++) {
        data.setUint32(i * 4, values[i], Endian.little);
      }
      return data.buffer.asUint8List();
    }

    Uint8List chunk(String tag, List<int> data) => Uint8List.fromList([
      ...ascii.encode(tag),
      ...ints([data.length]),
      ...data,
      if (data.length.isOdd) 0,
    ]);
    const frameSize = 1024 * 768 * 3, frames = 22;
    final strh = ByteData(56);
    strh.buffer.asUint8List().setRange(0, 8, ascii.encode('vidsDIB '));
    for (final pair in [
      [20, 1],
      [24, 10],
      [32, frames],
      [36, frameSize],
      [40, 0xffffffff],
    ]) {
      strh.setUint32(pair[0], pair[1], Endian.little);
    }
    strh.setUint16(52, 1024, Endian.little);
    strh.setUint16(54, 768, Endian.little);
    final strf = ints([
      40,
      1024,
      768,
      24 * 65536 + 1,
      0,
      frameSize,
      0,
      0,
      0,
      0,
    ]);
    final hdrl = chunk('LIST', [
      ...ascii.encode('hdrl'),
      ...chunk(
        'avih',
        ints([
          100000,
          frameSize * 10,
          0,
          16,
          frames,
          0,
          1,
          frameSize,
          1024,
          768,
          0,
          0,
          0,
          0,
        ]),
      ),
      ...chunk('LIST', [
        ...ascii.encode('strl'),
        ...chunk('strh', strh.buffer.asUint8List()),
        ...chunk('strf', strf),
      ]),
    ]);
    await output.writeFrom([
      ...ascii.encode('RIFF'),
      ...ints([length - 8]),
      ...ascii.encode('AVI '),
      ...hdrl,
      ...ascii.encode('LIST'),
      ...ints([4 + frames * (frameSize + 8)]),
      ...ascii.encode('movi'),
    ]);
    final frame = Uint8List(frameSize), index = <int>[];
    for (var i = 0; i < frames; i++) {
      for (var k = 0; k < frameSize; k += 3) {
        frame[k] = 32 + i * 4;
        frame[k + 1] = 80;
        frame[k + 2] = 160 - i * 3;
      }
      await output.writeFrom([
        ...ascii.encode('00db'),
        ...ints([frameSize]),
      ]);
      await output.writeFrom(frame);
      index.addAll([
        ...ascii.encode('00db'),
        ...ints([16, 4 + i * (8 + frameSize), frameSize]),
      ]);
    }
    await output.writeFrom(chunk('idx1', index));
    await output.close();
    expect(await original.length(), length);
    final vault = Directory('${scratch.path}/vault');
    WindowsDataProtection().preparePrivateDirectory(vault.path);
    final credentials = VaultCredentials(
      VaultBootstrapStore(File('${vault.path}/vault.bootstrap')),
    );
    final session = await credentials.initialize(
      password: 'resource budget test password',
      confirmation: 'resource budget test password',
    );
    final crypto = await VaultCrypto.load();
    final catalog = LibraryCatalog.create(
      File('${vault.path}/catalog.db'),
      session,
    );
    final imports = WindowsImportService(catalog: () => catalog)..start();
    Timer? timer;
    try {
      await imports.addFolder(photos.path);
      await until(() => catalog.mediaCount == 1 && imports.pending == 0);
      final media = catalog.media().single;
      final baseline = ProcessInfo.currentRss;
      var peak = baseline;
      void sample() {
        final rss = ProcessInfo.currentRss;
        if (rss > peak) peak = rss;
      }

      timer = Timer.periodic(const Duration(milliseconds: 10), (_) => sample());
      final store = SyncObjectStore(vault, () {});
      final task = SyncFormat.newId(crypto),
          revision = SyncFormat.newId(crypto);
      final descriptor = await SyncResourcePreparer(
        catalog: () => catalog,
        session: () => session,
        imports: imports,
        objects: store,
        checkAccess: sample,
        onProgress: (_, __) => sample(),
      ).prepare(task, media, revision, SourceCancellation());
      sample();
      final encryptionPeak = peak;
      final resource = session.openResource(
        SyncFormat.resourceContext(
          media['id'] as String,
          revision,
          descriptor['resourceId'] as String,
        ),
        VaultCiphertext(
          nonce: base64Decode(descriptor['keyNonce'] as String),
          ciphertext: base64Decode(descriptor['keyCipher'] as String),
        ),
      );
      final source = await original.open();
      final sizes = <int>[];
      try {
        for (var i = 0; i < SyncFormat.count(descriptor['blockCount']); i++) {
          final block = catalog.record(
            'jobs',
            SyncResourcePreparer.chunkKey(task, i),
          )!;
          final bytes = await store.read(
            task,
            block['objectId'] as String,
            SyncFormat.count(block['length']),
          );
          sizes.add(bytes.length);
          expect(bytes.length, lessThanOrEqualTo(4194352));
          final clear = decryptResourceBlock(
            resource,
            bytes,
            index: i,
            totalBytes: length,
          );
          try {
            expect(
              crypto.sameBytes(clear, await source.read(clear.length)),
              true,
            );
          } finally {
            clear.fillRange(0, clear.length, 0);
          }
        }
        expect(await source.position(), length);
      } finally {
        await source.close();
        resource.close();
      }
      expect(await original.length(), length);
      final after = await WindowsSourceReader().withSnapshot(
        original.path,
        photos.path,
        SourceCancellation(),
        (s) => s.fingerprint,
      );
      expect(after, descriptor['digest']);
      final evidence = {
        'platform': 'Windows',
        'scope': 'real native file read, SQLCipher and libsodium; no GitHub or playback claim',
        'clearBytes': length,
        'ciphertextSizes': sizes,
        'bytewiseEqual': true,
        'originalDigestUnchanged': true,
        'baselineRss': baseline,
        'encryptionPeakRss': encryptionPeak,
        'incrementalRss': encryptionPeak - baseline,
        'budget': 128 * 1024 * 1024,
        'timeUtc': DateTime.now().toUtc().toIso8601String(),
      };
      await File('build/sync-resource-budget-evidence.json')
          .writeAsString(jsonEncode(evidence));
      expect(encryptionPeak - baseline, lessThanOrEqualTo(128 * 1024 * 1024));
    } finally {
      timer?.cancel();
      imports.dispose();
      await imports.settled;
      catalog.close();
      credentials.revoke();
      await scratch.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
