// Isolated native UI inspection, artificial data only. NOT a shipping entry.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../support/tool_paths.dart';

import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'package:encrypted_photo_app/app/vault_controller.dart';
import 'package:encrypted_photo_app/main.dart' show PhotoVaultApp;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final root = ToolPaths.data('isolated-organization-ui');
  await root.create(recursive: true);
  final source = await Directory('${root.path}/artificial-source').create();
  for (var i = 0; i < 3; i++) {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawColor(
      [
        const ui.Color(0xff264f4d),
        const ui.Color(0xffb78558),
        const ui.Color(0xff496d89),
      ][i],
      ui.BlendMode.src,
    );
    canvas.drawCircle(
      const ui.Offset(160, 120),
      64,
      ui.Paint()..color = const ui.Color(0xfff2dcc2),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(320, 240);
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    await File('${source.path}/artificial-$i.png')
        .writeAsBytes(bytes.buffer.asUint8List());
    image.dispose();
    picture.dispose();
  }
  final controller = VaultController(
    Directory('${root.path}/vault'),
    automaticCheck: false,
  );
  await controller.start();
  if (controller.screen == VaultScreen.setup)
    await controller.initialize(
      password: 'artificial organization UI password',
      confirmation: 'artificial organization UI password',
      pin: '5837',
      pinConfirmation: '5837',
    );
  runApp(PhotoVaultApp(controller: controller));
  await Future<void>.delayed(const Duration(seconds: 1));
  await controller.unlock('5837');
  await controller.imports!.addFolder(source.path);
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (controller.mediaCount != 3 || controller.imports!.pending != 0) {
    if (DateTime.now().isAfter(deadline))
      throw StateError('UI probe import timeout');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  final organization = controller.organization!;
  if (organization.albums.isEmpty) {
    final album = await organization.createAlbum('隔离测试相册');
    final id = controller.catalog.media().first['id'] as String;
    organization.organize([id], favorite: true);
    organization.organize([id], albumId: album);
    organization.setHidden(album, true);
  }
  await ToolPaths.reportFile(
    'isolated-organization-ui',
    'ready.json',
  ).writeAsString(
    jsonEncode({
      'pid': pid,
      'mediaCount': controller.mediaCount,
      'visible': organization.count,
      'artificialOnly': true,
    }),
  );
}
