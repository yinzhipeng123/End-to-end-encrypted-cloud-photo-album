import 'package:media_kit/media_kit.dart';

import 'package:encrypted_photo_app/services/playback/playback_session.dart';

/// Initialized lazily so the normal locked/startup path does not load a decoder.
MediaKitPlayback createMediaPlayback({
  String? loopbackLocation,
  Map<String, String>? headers,
  bool thumbnail = false,
}) {
  MediaKit.ensureInitialized();
  return MediaKitPlayback(
    loopbackLocation: loopbackLocation,
    headers: headers,
    thumbnail: thumbnail,
  );
}

class MediaKitPlayback implements PlaybackBackend {
  MediaKitPlayback({
    this.loopbackLocation,
    Map<String, String>? headers,
    this.thumbnail = false,
  }) : _headers = headers,
       player = Player(
         configuration: PlayerConfiguration(
           protocolWhitelist: loopbackLocation == null
               ? ['file', 'data']
               : ['http', 'tcp'],
           logLevel: MPVLogLevel.error,
         ),
       );
  final Player player;
  final String? loopbackLocation;
  final bool thumbnail;
  Map<String, String>? _headers;
  @override
  Future<void> open(String location) async {
    final native = player.platform;
    if (native is! NativePlayer)
      throw StateError('Native playback unavailable');
    // media_kit's native defaults enable disk caching. Override before loading
    // any user resource, including local files; never write decoded content.
    await native.setProperty('cache-on-disk', 'no');
    await native.setProperty('save-position-on-quit', 'no');
    await native.setProperty('access-references', 'no');
    await native.setProperty('sub-auto', 'no');
    await native.setProperty('audio-file-auto', 'no');
    await native.setProperty('demuxer', 'lavf');
    if (thumbnail)
      await native.setProperty(
        'vf',
        'lavfi=[scale=256:256:force_original_aspect_ratio=decrease:flags=bilinear]',
      );
    const formats =
        'mov,matroska,avi,mpegts,flv,asf,jpeg_pipe,png_pipe,webp_pipe,gif,bmp_pipe,tiff_pipe,heif,avif,image2';
    await native.setProperty(
      'demuxer-lavf-o',
      'protocol_whitelist=[file,data],format_whitelist=[$formats],enable_drefs=0,use_absolute_path=0,pattern_type=none',
    );
    if (loopbackLocation != null) {
      final uri = Uri.parse(location);
      if (location != loopbackLocation ||
          uri.scheme != 'http' ||
          uri.host != '127.0.0.1' ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment) {
        throw StateError('Invalid playback capability');
      }
      // Empty explicit FFmpeg proxy option prevents inherited HTTP_PROXY from
      // sending the private loopback bearer header through an upstream proxy.
      await native.setProperty('stream-lavf-o', 'http_proxy=');
      await native.setProperty(
        'demuxer-lavf-o',
        'http_proxy=,protocol_whitelist=[http,tcp],format_whitelist=[$formats],enable_drefs=0,use_absolute_path=0,pattern_type=none',
      );
    }
    await player.open(Media(location, httpHeaders: _headers), play: false);
  }

  @override
  Future<void> play() => player.play();
  @override
  Future<void> pause() => player.pause();
  @override
  Future<void> stop() => player.stop();
  @override
  Future<void> setVolume(double value) => player.setVolume(value);
  @override
  Future<void> seek(Duration value) => player.seek(value);
  @override
  Future<void> dispose() async {
    _headers = null;
    await player.dispose();
  }
}
