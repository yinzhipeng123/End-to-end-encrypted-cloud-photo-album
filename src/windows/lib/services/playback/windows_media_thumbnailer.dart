import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'package:media_kit_video/media_kit_video.dart';

import 'package:encrypted_photo_app/sync/windows_sync_service.dart';
import 'package:encrypted_photo_app/services/playback/loopback_media_source.dart';
import 'package:encrypted_photo_app/services/playback/media_playback.dart';
import 'package:encrypted_photo_app/services/playback/playback_session.dart';
import 'package:encrypted_photo_app/services/import/windows_import_service.dart';
import 'package:encrypted_photo_app/services/import/windows_source_reader.dart';

/// One native thumbnail decoder at a time; pixels persist only in SQLCipher.
/// Card cancellation and view revocation apply to queued work as well as IO.
abstract final class WindowsMediaThumbnailer {
  static Future<void> _decoderTail = Future.value();
  static final resumed = ValueNotifier<int>(0);
  static final _requests = <SourceCancellation>{};
  static int _foregroundViews = 0;

  static void Function() prioritizeViewer() {
    _foregroundViews++;
    for (final token in _requests.toList()) {
      token.cancel();
    }
    var released = false;
    return () {
      if (released) return;
      released = true;
      _foregroundViews--;
      if (_foregroundViews == 0)
        scheduleMicrotask(() {
          if (_foregroundViews == 0) resumed.value++;
        });
    };
  }

  static Future<T> _serialized<T>(
    SourceCancellation token,
    Future<T> Function() action,
  ) async {
    if (_foregroundViews > 0)
      throw const SourceFailure(SourceFailureCode.cancelled);
    _requests.add(token);
    final previous = _decoderTail;
    final done = Completer<void>();
    _decoderTail = done.future;
    try {
      await previous;
      token.check();
      return await action();
    } finally {
      _requests.remove(token);
      done.complete();
    }
  }

  static Future<Uint8List?> create(
    WindowsImportService imports,
    Map<String, Object?> record,
    SourceCancellation token,
  ) async {
    try {
      return await _serialized(token, () async {
        final id = record['id'] as String,
            version = record['version'] as String;
        var previewId = id, previewVersion = version;
        int? pairedDuration;
        if (record['kind'] == 'livePhoto') {
          final parts = (record['resources'] as List).whereType<Map>();
          final image = parts.where((part) => part['role'] == 'image').single;
          previewId = image['sourceMediaId'] as String;
          previewVersion = image['version'] as String;
          final video = parts
              .where((part) => part['role'] == 'pairedVideo')
              .single;
          final original = imports.catalog().mediaById(
            video['sourceMediaId'] as String,
          );
          if (original?['version'] == video['version'] &&
              original?['sourceMetadata'] is Map) {
            pairedDuration =
                (original!['sourceMetadata'] as Map)['durationMs'] as int?;
          }
        }
        // The Live Photo cover is the still resource, never a motion frame.
        await imports.withLocalPlayback(
          previewId,
          previewVersion,
          token,
          (source) => _capture(
            imports,
            record,
            token,
            Uri.file(source.path, windows: true).toString(),
            pairedDuration: pairedDuration,
          ),
        );
        token.check();
        return imports.readVideoCover(id);
      });
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List?> createRemote(
    WindowsImportService imports,
    WindowsSyncService sync,
    Map<String, Object?> record,
    SourceCancellation parent,
  ) async {
    SourceCancellation? view;
    try {
      // Register before enqueueing, so opening a full viewer or locking also
      // cancels requests that have not yet reached the native decoder.
      final token = sync.beginThumbnail(parent);
      view = token;
      return await _serialized(token, () async {
        token.check();
        final timer = Timer(const Duration(seconds: 45), token.cancel);
        LoopbackMediaSource? remote;
        try {
          remote = await sync.openRemotePlayback(
            record['id'] as String,
            record['version'] as String,
            token,
            token.cancel,
            thumbnail: true,
            stillImage: record['kind'] != 'video',
          );
          token.check();
          await _capture(
            imports,
            record,
            token,
            remote.location,
            remote: remote,
          );
          token.check();
          return imports.readVideoCover(record['id'] as String);
        } finally {
          timer.cancel();
          token.cancel();
          await remote?.close();
        }
      });
    } catch (_) {
      return null;
    } finally {
      view?.cancel();
    }
  }

  static Future<void> _capture(
    WindowsImportService imports,
    Map<String, Object?> record,
    SourceCancellation token,
    String location, {
    LoopbackMediaSource? remote,
    int? pairedDuration,
  }) async {
    token.check();
    final backend = createMediaPlayback(
      thumbnail: true,
      loopbackLocation: remote?.location,
      headers: remote?.headers,
    );
    final session = PlaybackSession(backend, () => !token.cancelled);
    final cancelled = Completer<void>();
    final remove = token.onCancel(() {
      if (!cancelled.isCompleted) cancelled.complete();
      unawaited(session.revoke().catchError((Object _) {}));
    });
    final controller = VideoController(backend.player);
    Uint8List? frameBytes, thumbnail;
    ui.Codec? codec;
    ui.Image? frame;
    try {
      await session.setVolume(0);
      await session.open(location);
      await Future.any([
        controller.waitUntilFirstFrameRendered,
        cancelled.future,
      ]).timeout(const Duration(seconds: 20));
      token.check();
      final state = backend.player.state;
      final width = state.width, height = state.height;
      if (width == null || height == null || width <= 0 || height <= 0) return;
      // The native filter bounds the screenshot; video-params describes the
      // original decoder output. Original bytes and format are never replaced.
      frameBytes = await backend.player.screenshot(format: 'image/jpeg');
      token.check();
      if (frameBytes != null && frameBytes.length <= 16 * 1024 * 1024) {
        codec = await ui.instantiateImageCodec(
          frameBytes,
          targetWidth: width >= height
              ? 256
              : (256 * width / height).round().clamp(1, 256),
          allowUpscaling: false,
        );
        frame = (await codec.getNextFrame()).image;
        final png = await frame.toByteData(format: ui.ImageByteFormat.png);
        if (png != null) {
          try {
            if (png.lengthInBytes <= 256 * 1024)
              thumbnail = Uint8List.fromList(
                png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
              );
          } finally {
            png.buffer.asUint8List().fillRange(0, png.buffer.lengthInBytes, 0);
          }
        }
      }
      token.check();
      imports.saveViewMetadata(
        record['id'] as String,
        record['version'] as String,
        width: width,
        height: height,
        durationMs:
            pairedDuration ??
            (record['kind'] == 'video' && state.duration > Duration.zero
                ? state.duration.inMilliseconds
                : null),
        thumbnail: thumbnail,
      );
    } finally {
      remove();
      try {
        await session.dispose();
      } finally {
        frame?.dispose();
        codec?.dispose();
        frameBytes?.fillRange(0, frameBytes.length, 0);
        thumbnail?.fillRange(0, thumbnail.length, 0);
      }
    }
  }
}
