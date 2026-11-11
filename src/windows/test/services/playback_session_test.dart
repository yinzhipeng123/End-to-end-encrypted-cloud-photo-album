import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:encrypted_photo_app/services/playback/playback_session.dart';

class FakePlayback implements PlaybackBackend {
  Completer<void>? opening;
  bool playing = false;
  double volume = 80;
  int playCalls = 0;
  bool disposed = false;
  @override
  Future<void> open(String location) async {
    await opening?.future;
  }

  @override
  Future<void> play() async {
    playing = true;
    playCalls++;
  }

  @override
  Future<void> pause() async {
    playing = false;
  }

  @override
  Future<void> stop() async {
    playing = false;
  }

  @override
  Future<void> setVolume(double value) async {
    volume = value;
  }

  @override
  Future<void> seek(Duration value) async {}
  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

void main() {
  test(
    'revoking playback silences output and stale controls cannot restart it',
    () async {
      final backend = FakePlayback();
      var access = true;
      final session = PlaybackSession(backend, () => access);
      await session.open('local');
      await session.play();
      expect(backend.playing, isTrue);
      access = false;
      await session.revoke();
      expect(backend.playing, isFalse);
      expect(backend.volume, 0);
      access = true;
      await session.play();
      await session.setVolume(100);
      expect(backend.playCalls, 1);
      expect(backend.volume, 0);
      await session.dispose();
      expect(backend.disposed, isTrue);
    },
  );
  test('late open and queued play cannot bypass revocation', () async {
    final backend = FakePlayback()..opening = Completer<void>();
    final session = PlaybackSession(backend, () => true);
    final opening = session.open('local');
    final playing = session.play();
    final stopping = session.revoke();
    backend.opening!.complete();
    await Future.wait([opening, playing, stopping]);
    expect(backend.playCalls, 0);
    expect(backend.playing, isFalse);
    expect(backend.volume, 0);
    await session.dispose();
  });
}
