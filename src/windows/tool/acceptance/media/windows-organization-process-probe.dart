// Separate-process acceptance with actual source files, real production
// controller, importer, credentials, DPAPI and SQLCipher. Never a shipping entry.
import 'dart:convert';
import 'dart:io';

import '../support/tool_paths.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:encrypted_photo_app/app/vault_controller.dart';
import 'package:encrypted_photo_shared/model/library_query.dart';
import 'package:encrypted_photo_app/services/import/windows_source_reader.dart';

void main() {
  test(
    'real organization commit, crash and restart with unchanged source bytes',
    () async {
      final root = ToolPaths.requireData(
        Platform.environment['EPA_ORGANIZATION_ROOT']!,
        'organization-e2e',
      );
      final mode = Platform.environment['EPA_ORGANIZATION_MODE'];
      if (!{'initial', 'crash', 'reopen'}.contains(mode))
        throw StateError('Isolated probe parameters required');
      WindowsSourceReader.setTestLibrary(
        ToolPaths.buildFile('source-reader/Release/epa_source_reader.dll')
            .absolute
            .path,
      );
      await root.create(recursive: true);
      final source = await Directory(
        '${root.path}/ARTIFICIAL_ORGANIZATION_SOURCE/sub',
      ).create(recursive: true);
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=',
      );
      final fixture = ToolPaths.fixture('h264.mp4');
      expect(
        fixture.existsSync(),
        true,
        reason: 'Previously generated artificial FFmpeg fixture required',
      );
      if (mode == 'initial') {
        await File('${source.path}/one.png').writeAsBytes(png);
        await File('${source.parent.path}/two.png').writeAsBytes(png);
        await fixture.copy('${source.path}/video.mp4');
      }
      final controller = VaultController(
        Directory('${root.path}/vault'),
        automaticCheck: false,
      );
      try {
        await controller.start();
        if (mode == 'initial')
          await controller.initialize(
            password: 'artificial organization process password',
            confirmation: 'artificial organization process password',
            pin: '5837',
            pinConfirmation: '5837',
          );
        expect(controller.screen, VaultScreen.pin);
        await controller.unlock('5837');
        expect(
          controller.screen,
          VaultScreen.library,
          reason: controller.message,
        );
        if (mode == 'initial')
          await controller.imports!.addFolder(source.parent.path);
        final deadline = DateTime.now().add(const Duration(seconds: 35));
        while (controller.mediaCount != 3 ||
            controller.imports!.pending > 0 ||
            controller.imports!.scanning) {
          if (DateTime.now().isAfter(deadline))
            throw StateError('Actual import timed out');
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        final organization = controller.organization!;
        final catalog = controller.catalog;
        final items = catalog.media();
        final chosen = items
            .where((r) => r['fileName'] != 'two.png')
            .map((r) => r['id'] as String)
            .toList();
        final stateFile = File('${root.path}/expected.json');
        late String albumId;
        if (mode == 'initial') {
          albumId = await organization.createAlbum('ARTIFICIAL_PRIVATE_ALBUM');
          expect(organization.organize(chosen, albumId: albumId), 2);
          expect(organization.organize(chosen, favorite: true), 2);
          organization.renameAlbum(albumId, 'ARTIFICIAL_PRIVATE_RENAMED');
          organization.setHidden(albumId, true);
          await stateFile.writeAsString(
            jsonEncode({'albumId': albumId, 'ids': chosen}),
            flush: true,
          );
        } else {
          final state = jsonDecode(await stateFile.readAsString()) as Map;
          albumId = state['albumId'] as String;
          expect(chosen.toSet(), (state['ids'] as List).toSet());
          expect(
            catalog.albumById(albumId)!['name'],
            'ARTIFICIAL_PRIVATE_RENAMED',
          );
          expect(catalog.albumById(albumId)!['hidden'], 1);
          expect(catalog.albumMembers(albumId).toSet(), chosen.toSet());
          expect(items.where((r) => r['favorite'] == true).length, 2);
        }
        expect(organization.count, 1);
        expect(
          organization.countFor(const LibraryQuery(favoritesOnly: true)),
          0,
        );
        expect(organization.countFor(LibraryQuery(albumId: albumId)), 2);
        if (mode == 'crash') {
          catalog.transaction(() {
            organization.setQuery(LibraryQuery(albumId: albumId));
            organization.organize(chosen, favorite: false);
            organization.renameAlbum(albumId, 'MUST_ROLL_BACK');
            organization.deleteAlbum(albumId);
            expect(catalog.albums(), isEmpty);
            File('${root.path}/crash.json').writeAsStringSync(
              jsonEncode({
                'pid': pid,
                'beforeOuterCommit': true,
                'artificialOnly': true,
              }),
              flush: true,
            );
            exit(
              91,
            ); // Abrupt exit without disposing/rolling back the connection.
          });
        }
        if (mode == 'reopen') {
          organization.setQuery(LibraryQuery(albumId: albumId));
          organization.organize([chosen.first], albumId: albumId, remove: true);
          expect(catalog.albumMembers(albumId).length, 1);
          organization.deleteAlbum(albumId);
          expect(organization.count, 3);
          expect(catalog.mediaCount, 3);
          expect(
            organization.countFor(const LibraryQuery(favoritesOnly: true)),
            2,
          );
        }
        for (final item in items) {
          final bytes = await File(item['path'] as String).readAsBytes();
          expect(
            bytes,
            item['kind'] == 'video' ? await fixture.readAsBytes() : png,
          );
        }
        catalog.verifyIntegrity();
        final databaseBytes = latin1.decode(
          await controller.catalogFile.readAsBytes(),
        );
        expect(databaseBytes, isNot(contains('ARTIFICIAL_PRIVATE')));
        await File('${root.path}/$mode.json').writeAsString(
          jsonEncode({
            'pid': pid,
            'mode': mode,
            'imported': 3,
            'photoCount': 2,
            'videoCount': 1,
            'integrity': 'passed',
            'originalBytesUnchanged': true,
            'reopenedCommittedOrganization': mode == 'reopen',
            'crashRollback': mode == 'reopen',
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
    },
  );
}
