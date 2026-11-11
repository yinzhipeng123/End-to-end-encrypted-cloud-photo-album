// Isolated, real Windows controller + SQLCipher + importer in separate tester
// processes. Never included in the application entry point or user library.
import 'dart:convert';
import 'dart:io';

import '../support/tool_paths.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:encrypted_photo_app/app/vault_controller.dart';
import 'package:encrypted_photo_app/services/import/windows_source_reader.dart';

void main() {
  test('real import across process restart', () async {
    final root = ToolPaths.requireData(
      Platform.environment['EPA_IMPORT_PROBE_ROOT']!,
      'import-e2e',
    );
    final mode = Platform.environment['EPA_IMPORT_PROBE_MODE'];
    if (!{'initial', 'crash', 'reopen'}.contains(mode)) {
      throw StateError('Expected initial, crash or reopen mode');
    }
    WindowsSourceReader.setTestLibrary(
      ToolPaths.buildFile('source-reader/Release/epa_source_reader.dll')
          .absolute
          .path,
    );
    await root.create(recursive: true);
    final source = await Directory(
      '${root.path}/ARTIFICIAL_IMPORT_SOURCE/subfolder',
    ).create(recursive: true);
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=',
    );
    final controller = VaultController(
      Directory('${root.path}/vault'),
      automaticCheck: false,
    );
    try {
      if (mode == 'initial') {
        await File('${source.path}/one.png').writeAsBytes(png);
        await File('${source.parent.path}/two.png').writeAsBytes(png);
      } else if (mode == 'reopen') {
        await File('${source.path}/added-while-stopped.png').writeAsBytes(png);
      }
      await controller.start();
      if (mode == 'initial') {
        await controller.initialize(
          password: 'artificial process import password',
          confirmation: 'artificial process import password',
          pin: '5837',
          pinConfirmation: '5837',
        );
      }
      expect(controller.screen, VaultScreen.pin);
      await controller.unlock('5837');
      expect(
        controller.screen,
        VaultScreen.library,
        reason: controller.message,
      );
      final before = controller.mediaCount;
      if (mode == 'crash') {
        final imports = controller.imports!;
        imports.dispose();
        await imports.settled;
        final added = await File('${source.path}/added-while-stopped.png')
            .writeAsBytes(png);
        final savedSource = controller.catalog.sources().single;
        final sourceId = savedSource['id'] as String;
        final epoch = (savedSource['state'] as Map)['epoch'] as String;
        final path = WindowsSourceReader.absolute(added.path);
        final stat = await added.stat();
        controller.catalog.observeImport(
          source: sourceId,
          path: path,
          size: stat.size,
          modified: stat.modified.microsecondsSinceEpoch,
          epoch: epoch,
          now: 0,
          quietMilliseconds: 0,
          force: true,
        );
        await WindowsSourceReader().withSnapshot(
          path,
          source.parent.path,
          SourceCancellation(),
          (snapshot) {
            controller.catalog.transaction(() {
              controller.catalog.commitImport(
                source: sourceId,
                path: path,
                newId: 'artificial-uncommitted-media',
                nativeId: snapshot.identity,
                created: snapshot.created,
                observed: {
                  'kind': snapshot.kind,
                  'format': snapshot.format,
                  'path': snapshot.path,
                  'fileName': snapshot.fileName,
                  'size': snapshot.size,
                  'version': snapshot.version,
                  'observedAt': DateTime.now().millisecondsSinceEpoch,
                },
              );
              expect(controller.mediaCount, 3);
              File('${root.path}/crash.json').writeAsStringSync(
                jsonEncode({
                  'pid': pid,
                  'insideUncommittedCount': controller.mediaCount,
                  'candidateSavedBeforeTransaction': true,
                  'phase': 'after-import-update-before-outer-commit',
                  'artificialOnly': true,
                }),
                flush: true,
              );
              // Abrupt process termination: do not call SQLCipher close/rollback.
              exit(91);
            });
          },
        );
      }
      if (mode == 'initial')
        await controller.imports!.addFolder(source.parent.path);
      final expected = mode == 'initial' ? 2 : 3;
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (controller.mediaCount != expected ||
          controller.imports!.pending != 0) {
        if (DateTime.now().isAfter(deadline))
          throw StateError('Import did not complete');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      controller.catalog.verifyIntegrity();
      final ids = controller.catalog.media().map((r) => r['id']).toList();
      if (mode != 'initial') {
        final prior = jsonDecode(
          await File('${root.path}/initial.json').readAsString(),
        ) as Map;
        expect(before, 2);
        expect(pid, isNot(prior['pid']));
        expect(ids, containsAll(prior['mediaIds'] as List));
        expect(ids, isNot(contains('artificial-uncommitted-media')));
      }
      await File('${root.path}/$mode.json').writeAsString(
        jsonEncode({
          'mode': mode,
          'pid': pid,
          'beforeScan': before,
          'mediaCount': controller.mediaCount,
          'sources': controller.catalog.sources().length,
          'mediaIds': ids,
          'screenAfterStartup': 'pin',
          'catalogIntegrity': 'passed',
          'artificialOnly': true,
        }),
        flush: true,
      );
    } finally {
      final imports = controller.imports;
      await controller.close();
      await imports?.settled;
      controller.dispose();
    }
  });
}
