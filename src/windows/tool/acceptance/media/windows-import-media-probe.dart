// Import verification for previously generated, artificial FFmpeg fixtures.
// This does not verify video decoding, sound, or iPhone source compatibility.
import 'dart:convert';
import 'dart:io';

import '../support/tool_paths.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:encrypted_photo_app/app/vault_controller.dart';
import 'package:encrypted_photo_app/services/import/windows_source_reader.dart';

void main() {
  test('actual generated H264 HEVC and ProRes resources persist without modification', () async {
    WindowsSourceReader.setTestLibrary(
      ToolPaths.buildFile('source-reader/Release/epa_source_reader.dll')
          .absolute
          .path,
    );
    final parent = await ToolPaths.data('import-media-probe')
        .create(recursive: true);
    final root = await parent.createTemp('run-');
    final source = await Directory('${root.path}/source/nested')
        .create(recursive: true);
    final names = ['h264.mp4', 'hevc.mp4', 'prores.mov'];
    final originalBytes = <String, List<int>>{};
    for (final name in names) {
      final fixture = ToolPaths.fixture(name);
      expect(
        fixture.existsSync(),
        true,
        reason:
            'Artificial FFmpeg fixtures required; see implementation-notes.md',
      );
      originalBytes[name] = await fixture.readAsBytes();
      await fixture.copy('${source.path}/$name');
    }
    final controller = VaultController(
      Directory('${root.path}/vault'),
      automaticCheck: false,
    );
    try {
      await controller.start();
      await controller.initialize(
        password: 'artificial video import password',
        confirmation: 'artificial video import password',
        pin: '5837',
        pinConfirmation: '5837',
      );
      await controller.unlock('5837');
      expect(
        controller.screen,
        VaultScreen.library,
        reason: controller.message,
      );
      await controller.imports!.addFolder(source.parent.path);
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (controller.mediaCount != 3 || controller.imports!.pending != 0) {
        if (DateTime.now().isAfter(deadline))
          throw StateError('Video import timeout');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final records = controller.catalog.media();
      expect(records.every((r) => r['kind'] == 'video'), true);
      expect(records.every((r) => r['decodeStatus'] == 'unverified'), true);
      for (final r in records) {
        expect(
          await File(r['path'] as String).readAsBytes(),
          originalBytes[r['fileName']],
        );
        expect(r['size'], originalBytes[r['fileName']]!.length);
      }
      controller.catalog.verifyIntegrity();
      await ToolPaths.reportFile(
        'import-media-probe',
        '${root.uri.pathSegments.where((s) => s.isNotEmpty).last}.json',
      ).writeAsString(
        jsonEncode({
          'mediaCount': 3,
          'catalogIntegrity': 'passed',
          'sourceBytesUnchanged': true,
          'formats': records
              .map(
                (r) => {
                  'name': r['fileName'],
                  'size': r['size'],
                  'kind': r['kind'],
                },
              )
              .toList(),
          'playbackTested': false,
          'artificialOnly': true,
        }),
        flush: true,
      );
      stdout.writeln('Isolated result: ${root.path}/result.json');
    } finally {
      final imports = controller.imports;
      await controller.close();
      await imports?.settled;
      controller.dispose();
    }
  });
}
