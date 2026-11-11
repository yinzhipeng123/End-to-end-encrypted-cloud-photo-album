import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../model/demo_store.dart';

import 'package:encrypted_photo_shared/model/library_query.dart';
import 'package:encrypted_photo_app/services/playback/media_playback.dart';
import 'package:encrypted_photo_app/services/playback/playback_session.dart';

import 'dialogs.dart';
import 'media_thumbnail.dart';

Future<void> showMediaViewer(
  BuildContext context,
  DemoStore store,
  MediaItem item,
  LibraryQuery source,
) async {
  if (!store.query(source).any((p) => p.id == item.id)) return;
  await Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => MediaViewer(store: store, item: item, source: source),
      fullscreenDialog: true,
    ),
  );
}

class MediaViewer extends StatefulWidget {
  const MediaViewer({
    super.key,
    required this.store,
    required this.item,
    required this.source,
  });
  final DemoStore store;
  final MediaItem item;
  final LibraryQuery source;
  @override
  State<MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends State<MediaViewer> {
  MediaKitPlayback? _backend;
  PlaybackSession? _session;
  VideoController? _controller;
  StreamSubscription<String>? _errors;
  String? _error;
  String? _playbackWarning;
  bool _ready = false;
  bool _disposed = false;

  bool get _allowed =>
      widget.store.canView &&
      widget.store.query(widget.source).any((p) => identical(p, widget.item));

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_checkAccess);
    if (widget.item.kind != MediaKind.photo) unawaited(_initialize());
  }

  Future<void> _initialize() async {
    final item = widget.item;
    if (!item.hasCompleteLocalResources) {
      _error = '原始动态资源缺失或配对不完整';
      return;
    }
    try {
      final role = item.kind == MediaKind.livePhoto
          ? ResourceRole.pairedVideo
          : ResourceRole.video;
      final resource = item.resources.firstWhere((r) => r.role == role);
      _backend = MediaKitPlayback();
      _session = PlaybackSession(_backend!, () => !_disposed && _allowed);
      _controller = VideoController(_backend!.player);
      _errors = _backend!.player.stream.error.listen((message) {
        // 原生解码可能先报告硬件失败，再成功回退；以画面就绪判断打开结果。
        // 不展示或保存可能包含来源路径的原始错误。
        if (mounted && _allowed && _ready) {
          setState(() => _playbackWarning = '播放遇到问题，可暂停或退出后重新打开');
        }
      });
      await _session!.open(
        item.isDemo ? 'asset:///${resource.location}' : resource.location,
      );
      if (!mounted || !_session!.allowed) return;
      await _controller!.waitUntilFirstFrameRendered.timeout(
        const Duration(seconds: 15),
      );
      if (!mounted || !_session!.allowed) return;
      await _session!.setVolume(80);
      if (mounted && _session!.allowed) setState(() => _ready = true);
    } on TimeoutException {
      await _session?.revoke().catchError((Object _) {});
      if (mounted && _allowed) {
        setState(() => _error = '未能读取视频画面：文件可能损坏、读取过慢或编码暂不支持');
      }
    } catch (_) {
      await _session?.revoke().catchError((Object _) {});
      if (mounted) setState(() => _error = '播放器初始化或资源读取失败');
    }
  }

  void _checkAccess() {
    if (!_allowed) unawaited(_session?.revoke().catchError((Object _) {}));
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _disposed = true;
    widget.store.removeListener(_checkAccess);
    unawaited(_errors?.cancel());
    unawaited(_session?.dispose().catchError((Object _) {}));
    super.dispose();
  }

  Future<void> _control(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      await _session?.revoke().catchError((Object _) {});
      if (mounted) setState(() => _error = '播放操作失败，请退出后重新打开');
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final allowed = _allowed;
    return Scaffold(
      backgroundColor: const Color(0xFF101914),
      appBar: AppBar(
        backgroundColor: const Color(0xFF101914),
        foregroundColor: Colors.white,
        leading: IconButton(
          tooltip: '退出全屏',
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('${item.kindLabel}全屏查看'),
        actions: [
          if (allowed)
            IconButton(
              tooltip: '查看详情',
              icon: const Icon(Icons.info_outline),
              onPressed: () => showPhotoDetails(context, widget.store, item),
            ),
          IconButton(
            tooltip: '锁定应用',
            icon: const Icon(Icons.lock_outline),
            onPressed: widget.store.lock,
          ),
        ],
      ),
      body: !allowed
          ? const Center(
              child: Text(
                '该项目已不在当前可见范围',
                style: TextStyle(color: Colors.white),
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: SizedBox.expand(
                    child: _controller != null && _error == null
                        ? Video(
                            controller: _controller!,
                            controls: NoVideoControls,
                            wakelock: false,
                          )
                        : MediaThumbnail(item: item, fit: BoxFit.contain),
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                if (_error == null && _controller != null && !_ready)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      '正在读取视频画面…',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                if (_error == null && _playbackWarning != null)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      _playbackWarning!,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                if (_backend != null && _ready && _error == null) _controls(),
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
              builder: (context, position) => StreamBuilder<Duration>(
                stream: player.stream.duration,
                initialData: player.state.duration,
                builder: (context, duration) {
                  final max = duration.data?.inMilliseconds.toDouble() ?? 0;
                  final value = (position.data?.inMilliseconds.toDouble() ?? 0)
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
                              : (value) => _control(
                                  () => _session!.seek(
                                    Duration(milliseconds: value.round()),
                                  ),
                                ),
                        ),
                      ),
                      Text(
                        _time(duration.data ?? Duration.zero),
                        style: const TextStyle(color: Colors.white),
                      ),
                    ],
                  );
                },
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                StreamBuilder<bool>(
                  stream: player.stream.playing,
                  initialData: player.state.playing,
                  builder: (context, playing) => IconButton(
                    tooltip: playing.data == true ? '暂停' : '播放',
                    color: Colors.white,
                    icon: Icon(
                      playing.data == true ? Icons.pause : Icons.play_arrow,
                    ),
                    onPressed: () => _control(
                      playing.data == true ? _session!.pause : _session!.play,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                StreamBuilder<double>(
                  stream: player.stream.volume,
                  initialData: player.state.volume,
                  builder: (context, volume) => Row(
                    children: [
                      IconButton(
                        tooltip: (volume.data ?? 0) == 0 ? '取消静音' : '静音',
                        color: Colors.white,
                        icon: Icon(
                          (volume.data ?? 0) == 0
                              ? Icons.volume_off
                              : Icons.volume_up,
                        ),
                        onPressed: () => _control(
                          () => _session!.setVolume(
                            (volume.data ?? 0) == 0 ? 80 : 0,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 130,
                        child: Slider(
                          value: (volume.data ?? 0).clamp(0, 100),
                          max: 100,
                          onChanged: (value) =>
                              _control(() => _session!.setVolume(value)),
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
