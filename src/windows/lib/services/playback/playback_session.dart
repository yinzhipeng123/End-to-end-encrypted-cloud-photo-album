import 'dart:async';

abstract interface class PlaybackBackend {
  Future<void> open(String location);
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> setVolume(double value);
  Future<void> seek(Duration position);
  Future<void> dispose();
}

/// 撤销后永不复用；异步 open 必须以暂停状态完成，不能在锁定后自动出声。
class PlaybackSession {
  PlaybackSession(this.backend, this.canAccess);
  final PlaybackBackend backend;
  final bool Function() canAccess;
  bool _revoked = false;
  bool get allowed => !_revoked && canAccess();
  Future<void> _pending = Future.value();
  Future<void>? _revocation;

  Future<void> open(String location) => _command(() => backend.open(location));

  Future<void> _command(Future<void> Function() action) {
    final result = _pending.then((_) async {
      if (!allowed) return;
      await action();
      if (!allowed) await backend.stop();
    });
    // 保持队列可继续，同时让调用者接收错误。
    _pending = result.catchError((Object _) {});
    return result;
  }

  Future<void> play() => _command(backend.play);
  Future<void> pause() => _command(backend.pause);
  Future<void> seek(Duration value) => _command(() => backend.seek(value));
  Future<void> setVolume(double value) =>
      _command(() => backend.setVolume(value));

  Future<void> revoke() {
    _revoked = true;
    return _revocation ??= _stopOutput();
  }

  Future<void> _stopOutput() async {
    try {
      await backend.setVolume(0);
    } finally {
      await backend.stop();
    }
  }

  Future<void> dispose() async {
    try {
      await revoke();
    } finally {
      // An in-flight open must not complete after the native player is freed.
      await _pending;
      await backend.dispose();
    }
  }
}
