import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:encrypted_photo_app/services/import/windows_source_reader.dart';

/// Read-only, pinned ExifTool. Caller holds the original stable file handle.
/// User Perl configs are explicitly disabled; no tag-writing arguments exist.
abstract final class WindowsMediaMetadata {
  static String get executable =>
      '${File(Platform.resolvedExecutable).parent.path}/metadata/exiftool.exe';
  static bool get available => File(executable).existsSync();
  static Future<Map<String, Object?>> read(
    String path,
    SourceCancellation token,
  ) async {
    token.check();
    if (!await File(executable).exists())
      return {'status': 'backend-unavailable'};
    token.check();
    final process = await Process.start(executable, [
      '-config',
      '',
      '-json',
      '-n',
      '-G1',
      '-charset',
      'filename=UTF8',
      '-ContentIdentifier',
      '-ImageWidth',
      '-ImageHeight',
      '-ExifImageWidth',
      '-ExifImageHeight',
      '-Duration',
      '-DateTimeOriginal',
      '-SubSecDateTimeOriginal',
      '-OffsetTimeOriginal',
      '-Rotation',
      '-Orientation',
      path,
    ], runInShell: false);
    final output = BytesBuilder(copy: false);
    final errors = BytesBuilder(copy: false);
    var overflow = false;
    void collect(BytesBuilder builder, List<int> bytes) {
      if (builder.length + bytes.length > 65536) {
        overflow = true;
        process.kill();
        return;
      }
      builder.add(bytes);
    }

    final remove = token.onCancel(process.kill);
    final timer = Timer(const Duration(seconds: 25), process.kill);
    final stdoutDone = process.stdout
        .listen((bytes) => collect(output, bytes))
        .asFuture<void>();
    final stderrDone = process.stderr
        .listen((bytes) => collect(errors, bytes))
        .asFuture<void>();
    Uint8List? bytes, errorBytes;
    try {
      final result = await process.exitCode;
      await Future.wait([stdoutDone, stderrDone]);
      token.check();
      bytes = output.takeBytes();
      errorBytes = errors.takeBytes();
      if (result != 0 || overflow) return {'status': 'unreadable'};
      final data = jsonDecode(utf8.decode(bytes));
      if (data is! List || data.length != 1 || data.single is! Map)
        return {'status': 'unreadable'};
      final values = Map<String, Object?>.from(data.single as Map);
      Object? value(List<String> names) {
        for (final key in names) {
          if (values[key] != null) return values[key];
        }
        return null;
      }

      final contentId = value([
        'Apple:ContentIdentifier',
        'Keys:ContentIdentifier',
        'QuickTime:ContentIdentifier',
      ]);
      final width = value([
        'ExifIFD:ExifImageWidth',
        'File:ImageWidth',
        'QuickTime:ImageWidth',
        'PNG:ImageWidth',
      ]);
      final height = value([
        'ExifIFD:ExifImageHeight',
        'File:ImageHeight',
        'QuickTime:ImageHeight',
        'PNG:ImageHeight',
      ]);
      final duration = value(['QuickTime:Duration', 'Matroska:Duration']);
      final captured = value([
        'Composite:SubSecDateTimeOriginal',
        'ExifIFD:DateTimeOriginal',
      ]);
      return {
        'status': 'read',
        if (contentId is String &&
            RegExp(r'^[a-zA-Z0-9-]{16,128}$').hasMatch(contentId))
          'appleContentIdentifier': contentId.toLowerCase(),
        if (width is num && width > 0 && width <= 100000)
          'width': width.toInt(),
        if (height is num && height > 0 && height <= 100000)
          'height': height.toInt(),
        if (duration is num && duration > 0 && duration < 1e9)
          'durationMs': (duration * 1000).round(),
        if (captured is String && captured.length <= 80)
          'captureText': captured,
      };
    } catch (_) {
      token.check();
      return {'status': 'unreadable'};
    } finally {
      timer.cancel();
      remove();
      process.kill();
      bytes?.fillRange(0, bytes.length, 0);
      errorBytes?.fillRange(0, errorBytes.length, 0);
      final rest = output.takeBytes();
      rest.fillRange(0, rest.length, 0);
      final restErrors = errors.takeBytes();
      restErrors.fillRange(0, restErrors.length, 0);
    }
  }
}
