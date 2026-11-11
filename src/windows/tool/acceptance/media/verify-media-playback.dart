import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:media_kit/media_kit.dart';

/// 仅解码／状态探针；不代替窗口渲染、实际听音或 iPhone 原始样本验收。
Future<void> main(List<String> args) async {
  if (args.length < 2) throw ArgumentError('传入 libmpv 路径和人工生成的测试视频路径');
  MediaKit.ensureInitialized(libmpv: File(args.first).absolute.path);
  for (final path in args.skip(1)) {
    final player = Player(
      configuration: const PlayerConfiguration(
        vo: 'null',
        protocolWhitelist: ['file', 'data'],
        logLevel: MPVLogLevel.error,
      ),
    );
    final errors = <String>[];
    final sub = player.stream.error.listen(errors.add);
    try {
      await player.open(Media(File(path).absolute.path), play: false);
      await player.setVideoTrack(VideoTrack.auto());
      if (player.state.duration == Duration.zero) {
        await player.stream.duration
            .firstWhere((d) => d > Duration.zero)
            .timeout(const Duration(seconds: 10));
      }
      await player.setVolume(0);
      await player.play();
      await Future<void>.delayed(const Duration(milliseconds: 900));
      final advanced = player.state.position > Duration.zero;
      await player.seek(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await player.pause();
      await player.setVolume(25);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final result = {
        'fixture': File(path).uri.pathSegments.last,
        'durationMs': player.state.duration.inMilliseconds,
        'width': player.state.width,
        'height': player.state.height,
        'audioTracks': player.state.tracks.audio
            .where((t) => t.id != 'no' && t.id != 'auto')
            .length,
        'positionAdvanced': advanced,
        'seekMs': player.state.position.inMilliseconds,
        'paused': !player.state.playing,
        'volume': player.state.volume,
        'errors': errors,
      };
      if (!advanced ||
          player.state.position.inSeconds < 2 ||
          player.state.playing ||
          player.state.volume != 25 ||
          errors.isNotEmpty ||
          player.state.width == null) {
        throw StateError(jsonEncode(result));
      }
      await player.stop();
      stdout.writeln(jsonEncode(result));
    } finally {
      await sub.cancel();
      await player.dispose();
    }
  }
}
