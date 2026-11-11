import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:encrypted_photo_shared/model/library_query.dart';
import 'package:encrypted_photo_app/services/library/library_organization_service.dart';
import 'package:encrypted_photo_app/services/playback/media_playback.dart';
import 'package:encrypted_photo_app/services/playback/playback_session.dart';
import 'package:encrypted_photo_app/services/import/windows_import_service.dart';
import 'package:encrypted_photo_app/services/import/windows_source_reader.dart';
import 'package:encrypted_photo_app/sync/windows_sync_service.dart';
import 'package:encrypted_photo_app/services/playback/loopback_media_source.dart';

/// Production media view: no demo model, automatic playback or plaintext cache.
class ProductionMediaViewer extends StatefulWidget {
  const ProductionMediaViewer({
    super.key,
    required this.record,
    required this.organization,
    required this.source,
    required this.imports,
    required this.onDetails,
    this.onClosed,
    this.sync,
  });
  final Map<String, Object?> record;
  final LibraryOrganizationService organization;
  final LibraryQuery source;
  final WindowsImportService imports;
  final WindowsSyncService? sync;
  final VoidCallback onDetails;
  final VoidCallback? onClosed;

  @override
  State<ProductionMediaViewer> createState() => _ProductionMediaViewerState();
}

class _ProductionMediaViewerState extends State<ProductionMediaViewer> {
  late final SourceCancellation _view;
  final _decoderClosed = Completer<void>();
  MediaKitPlayback? _backend;
  LoopbackMediaSource? _remote;
  PlaybackSession? _session;
  VideoController? _video;
  StreamSubscription<String>? _errors;
  Uint8List? _photo;
  MemoryImage? _image;
  ImageProvider? _displayImage;
  bool _disposed = false, _ended = false, _ready = false;
  bool _remotePhoto = false;
  String? _error;
  String? _notice;
  Future<void>? _closing;
  String get _id => widget.record['id'] as String;
  String get _version => widget.record['version'] as String;
  bool get _isVideo => {'video', 'livePhoto'}.contains(widget.record['kind']);
  bool get _nativePhoto =>
      !_isVideo &&
      (!{
            'JPEG',
            'PNG',
            'WebP',
            'GIF',
            'BMP',
          }.contains(widget.record['format']) ||
          (widget.record['size'] as int) > 16 * 1024 * 1024);

  bool get _allowed {
    if (_disposed || _ended) return false;
    try {
      final db = widget.organization.catalog;
      final current = db.mediaById(_id);
      return widget.organization.query == widget.source &&
          current?['version'] == _version &&
          db.queryIds(widget.source, within: [_id]).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  @override
  void initState() {
    super.initState();
    _view = SourceCancellation(
      checkAccess: () {
        if (!_allowed) throw const SourceFailure(SourceFailureCode.cancelled);
      },
    );
    _view.onCancel(() => unawaited(_closeDecoder()));
    widget.organization.addListener(_checkScope);
    unawaited(_load());
  }

  void _checkScope() {
    if (_allowed) return;
    unawaited(_closeDecoder());
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      _view.check();
      if (_isVideo || _nativePhoto) {
        Future<void> play(
          String location, {
          LoopbackMediaSource? remote,
        }) async {
          try {
            _view.check();
            final backend = createMediaPlayback(
              loopbackLocation: remote?.location,
              headers: remote?.headers,
            );
            _backend = backend;
            _session = PlaybackSession(
              backend,
              () => _allowed && !_view.cancelled,
            );
            _video = VideoController(backend.player);
            _errors = backend.player.stream.error.listen((_) {
              // Native messages may contain sensitive local paths. Never echo them.
              if (mounted && _allowed && _ready) {
                setState(() => _notice = '解码器报告播放异常；可暂停或退出后重试。');
              }
            });
            if (mounted && _allowed) setState(() {});
            await _session!.setVolume(0);
            await _session!.open(location);
            _view.check();
            await Future.any<void>([
              _video!.waitUntilFirstFrameRendered.timeout(
                const Duration(seconds: 20),
              ),
              _decoderClosed.future,
            ]);
            _view.check();
            final state = backend.player.state;
            final width = state.width, height = state.height;
            if (width != null && height != null) {
              Uint8List? thumbnail;
              try {
                // The motion frame must not replace a Live Photo's still cover.
                if (widget.record['kind'] != 'livePhoto')
                  thumbnail = await _captureCover(width, height);
                _view.check();
                widget.imports.saveViewMetadata(
                  _id,
                  _version,
                  width: width,
                  height: height,
                  durationMs: state.duration > Duration.zero
                      ? state.duration.inMilliseconds
                      : null,
                  thumbnail: thumbnail,
                );
              } catch (_) {
                if (_allowed) _notice = '视频已读取，但媒体属性保存失败。';
              } finally {
                thumbnail?.fillRange(0, thumbnail.length, 0);
              }
            }
            await _session!.setVolume(80);
            _view.check();
            if (mounted) setState(() => _ready = true);
            // Keep the verified source and ancestor guards until the decoder is
            // closed, including while paused. Releasing them earlier permits a
            // path-based native player to switch to a different source file.
            await _decoderClosed.future;
          } catch (error) {
            if (mounted && _allowed && !_view.cancelled) {
              setState(
                () => _error = error is TimeoutException
                    ? '未能读取视频画面：文件可能损坏、读取过慢或编码暂不兼容。'
                    : '播放器未能打开此视频，请返回后重试。',
              );
            }
            rethrow;
          } finally {
            await _closeDecoder();
          }
        }

        if (widget.record['local'] == true) {
          await widget.imports.withLocalPlayback(
            _id,
            _version,
            _view,
            (source) => play(Uri.file(source.path, windows: true).toString()),
          );
        } else {
          final sync = widget.sync;
          if (sync == null)
            throw const SourceFailure(SourceFailureCode.unavailable);
          final remote = await sync.openRemotePlayback(
            _id,
            _version,
            _view,
            () {
              if (mounted && _allowed) {
                setState(() => _error = '仓库读取失败，播放已停止；请检查连接或副本完整性后重试。');
              }
              unawaited(_closeDecoder());
            },
          );
          _remote = remote;
          try {
            _view.check();
            await play(remote.location, remote: remote);
          } finally {
            await remote.close();
          }
        }
      } else {
        _remotePhoto = widget.record['local'] != true;
        final bytes = _remotePhoto
            ? await widget.sync?.readRemotePhoto(_id)
            : await widget.imports.preview(_id);
        if (!_allowed || _view.cancelled) {
          _releasePhoto(bytes);
          return;
        }
        if (bytes == null)
          throw const SourceFailure(SourceFailureCode.unavailable);
        _photo = bytes;
        _image = MemoryImage(bytes);
        _displayImage = ResizeImage.resizeIfNeeded(2048, null, _image!);
        await _readImageDimensions(bytes);
        if (!_allowed || _view.cancelled) return;
        if (mounted) setState(() => _ready = true);
      }
    } on TimeoutException {
      if (mounted && _allowed)
        setState(() => _error = '无法取得视频画面：文件可能损坏、读取过慢或编码暂不兼容。');
      await _closeDecoder();
    } catch (error) {
      if (mounted && !_disposed && !_view.cancelled) {
        setState(
          () => _error = error is SourceFailure
              ? switch (error.code) {
                  SourceFailureCode.busy => '原文件正在被其他程序使用，请关闭后重试。',
                  SourceFailureCode.changed => '原文件已变化，正在安排重新扫描；请返回图库后重试。',
                  SourceFailureCode.cancelled => '媒体访问已结束。',
                  _ =>
                    _isVideo
                        ? '无法打开本地视频；原文件可能缺失或解码器暂不支持。'
                        : '图片暂不可读取或超出当前内存预览范围。',
                }
              : '媒体读取或解码失败，请返回后重试。',
        );
      }
      await _closeDecoder();
    }
  }

  Future<void> _closeDecoder() {
    if (_ended) return _closing ?? Future<void>.value();
    _ended = true;
    _view.cancel();
    // Revoke synchronously before waiting for subscriptions/native disposal.
    final stopping = _session?.revoke();
    final closingRemote = _remote?.close();
    return _closing = () async {
      try {
        await closingRemote;
        await stopping;
        await _errors?.cancel();
        await _session?.dispose();
      } catch (_) {
        // Disposal errors never reopen the view or expose native error strings.
      } finally {
        if (!_decoderClosed.isCompleted) _decoderClosed.complete();
      }
    }();
  }

  Future<Uint8List?> _captureCover(int width, int height) async {
    // Screenshot only an actually decoded frame. Bound large frame copies and
    // store only a small PNG in SQLCipher; no decoder-created files are used.
    if (width <= 0 || height <= 0 || width * height > 3840 * 2160) return null;
    Uint8List? encoded;
    ui.Codec? codec;
    ui.Image? frame;
    try {
      _view.check();
      encoded = await _backend!.player.screenshot(format: 'image/jpeg');
      _view.check();
      if (encoded == null || encoded.length > 16 * 1024 * 1024) return null;
      codec = await ui.instantiateImageCodec(
        encoded,
        targetWidth: width >= height
            ? 256
            : (256 * width / height).round().clamp(1, 256),
        allowUpscaling: false,
      );
      _view.check();
      frame = (await codec.getNextFrame()).image;
      final png = await frame.toByteData(format: ui.ImageByteFormat.png);
      _view.check();
      if (png == null) return null;
      final bytes = png.buffer.asUint8List(
        png.offsetInBytes,
        png.lengthInBytes,
      );
      if (bytes.length <= 256 * 1024) return bytes;
      bytes.fillRange(0, bytes.length, 0);
      return null;
    } catch (_) {
      _view.check();
      // A cover is optional; failure must not discard actual size/duration.
      return null;
    } finally {
      frame?.dispose();
      codec?.dispose();
      encoded?.fillRange(0, encoded.length, 0);
    }
  }

  Future<void> _readImageDimensions(Uint8List bytes) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      _view.check();
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      _view.check();
      widget.imports.saveViewMetadata(
        _id,
        _version,
        width: descriptor.width,
        height: descriptor.height,
      );
    } catch (_) {
      _view.check();
      _notice = '图片尺寸暂不可读取或保存。';
    } finally {
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  void _releasePhoto(Uint8List? bytes) {
    if (bytes == null) return;
    if (_remotePhoto) {
      widget.sync?.releasePhoto(bytes);
    } else {
      widget.imports.releasePreview(bytes);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    widget.organization.removeListener(_checkScope);
    unawaited(_closeDecoder());
    unawaited(_image?.evict());
    unawaited(_displayImage?.evict());
    _releasePhoto(_photo);
    _photo = null;
    widget.onClosed?.call();
    super.dispose();
  }

  Future<void> _control(Future<void> Function() action) async {
    if (!_allowed || !_ready) return;
    try {
      await action();
    } catch (_) {
      if (mounted && _allowed) setState(() => _error = '播放操作失败，请退出后重试。');
      await _closeDecoder();
    }
  }

  @override
  Widget build(BuildContext context) {
    final allowed = _allowed;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(
          widget.record['kind'] == 'livePhoto'
              ? '实况照片'
              : _isVideo
              ? '视频查看'
              : '照片查看',
        ),
        leading: IconButton(
          tooltip: '退出全屏',
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          if (allowed)
            IconButton(
              tooltip: '查看详情',
              onPressed: widget.onDetails,
              icon: const Icon(Icons.info_outline),
            ),
        ],
      ),
      body: !allowed || _error != null
          ? Center(
              child: Text(
                _error ?? '该媒体已不在可访问范围，请返回图库。',
                style: const TextStyle(color: Colors.white),
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: Center(
                    child: _isVideo || _nativePhoto
                        ? (_video == null
                              ? const CircularProgressIndicator()
                              : Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    Video(
                                      controller: _video!,
                                      controls: NoVideoControls,
                                      wakelock: false,
                                    ),
                                    if (!_ready)
                                      const Center(
                                        child: CircularProgressIndicator(),
                                      ),
                                  ],
                                ))
                        : (_image == null
                              ? const CircularProgressIndicator()
                              : InteractiveViewer(
                                  minScale: 0.5,
                                  maxScale: 8,
                                  child: Image(
                                    image: _displayImage!,
                                    fit: BoxFit.contain,
                                    errorBuilder: (_, __, ___) => const Text(
                                      '图片解码失败',
                                      style: TextStyle(color: Colors.white),
                                    ),
                                  ),
                                )),
                  ),
                ),
                if (_isVideo && !_ready)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      '正在核对原文件并读取视频画面…',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                if (_notice != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      _notice!,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                if (_isVideo && _ready && _session != null) _controls(),
              ],
            ),
    );
  }

  Widget _controls() {
    final player = _backend!.player;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            StreamBuilder<Duration>(
              stream: player.stream.position,
              initialData: player.state.position,
              builder: (_, position) => StreamBuilder<Duration>(
                stream: player.stream.duration,
                initialData: player.state.duration,
                builder: (_, duration) {
                  final max = (duration.data ?? Duration.zero).inMilliseconds
                      .toDouble();
                  final value = (position.data ?? Duration.zero).inMilliseconds
                      .toDouble()
                      .clamp(0.0, max > 0 ? max : 1.0);
                  return Row(
                    children: [
                      Text(
                        _time(position.data ?? Duration.zero),
                        style: const TextStyle(color: Colors.white),
                      ),
                      Expanded(
                        child: Slider(
                          value: value,
                          max: max > 0 ? max : 1,
                          onChanged: max <= 0
                              ? null
                              : (value) => unawaited(
                                  _control(
                                    () => _session!.seek(
                                      Duration(milliseconds: value.round()),
                                    ),
                                  ),
                                ),
                        ),
                      ),
                      Text(
                        max > 0 ? _time(duration.data!) : '时长未知',
                        style: const TextStyle(color: Colors.white),
                      ),
                    ],
                  );
                },
              ),
            ),
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                StreamBuilder<bool>(
                  stream: player.stream.playing,
                  initialData: player.state.playing,
                  builder: (_, playing) => IconButton(
                    color: Colors.white,
                    tooltip: playing.data == true ? '暂停' : '播放',
                    icon: Icon(
                      playing.data == true ? Icons.pause : Icons.play_arrow,
                    ),
                    onPressed: () => unawaited(
                      _control(() async {
                        if (player.state.playing) {
                          await _session!.pause();
                        } else {
                          if (player.state.completed)
                            await _session!.seek(Duration.zero);
                          await _session!.play();
                        }
                      }),
                    ),
                  ),
                ),
                StreamBuilder<double>(
                  stream: player.stream.volume,
                  initialData: player.state.volume,
                  builder: (_, volume) => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        color: Colors.white,
                        tooltip: (volume.data ?? 0) == 0 ? '取消静音' : '静音',
                        icon: Icon(
                          (volume.data ?? 0) == 0
                              ? Icons.volume_off
                              : Icons.volume_up,
                        ),
                        onPressed: () => unawaited(
                          _control(
                            () => _session!.setVolume(
                              (volume.data ?? 0) == 0 ? 80 : 0,
                            ),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 140,
                        child: Slider(
                          value: (volume.data ?? 0).clamp(0, 100),
                          max: 100,
                          onChanged: (value) => unawaited(
                            _control(() => _session!.setVolume(value)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _time(Duration value) =>
    '${value.inMinutes}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';
