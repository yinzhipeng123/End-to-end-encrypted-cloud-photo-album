import 'package:flutter_test/flutter_test.dart';
import 'package:encrypted_photo_app/model/demo_store.dart';

void main() {
  late DateTime clock;
  late DemoStore store;
  setUp(() {
    clock = DateTime(2026, 11, 6, 10);
    store = DemoStore(clock: () => clock);
  });
  tearDown(() => store.dispose());

  test(
    'three-day boundary requires correct photo password, not PIN or provider login',
    () {
      final verified = store.lastVerified;
      clock = clock.add(const Duration(days: 3) - const Duration(seconds: 1));
      expect(store.canView, isTrue);
      clock = clock.add(const Duration(seconds: 1));
      expect(store.verificationDue, isTrue);
      expect(store.photos, isEmpty);
      store.lock();
      expect(store.unlockPin(DemoStore.defaultPin), isTrue);
      expect(store.lastVerified, verified);
      store.connectRepository(RepositoryProvider.github, store.repository);
      expect(store.canView, isFalse);
      expect(store.verifyPhotoPassword('wrong'), isFalse);
      expect(store.lastVerified, verified);
      expect(store.verifyPhotoPassword(DemoStore.defaultPassword), isTrue);
      expect(store.canView, isTrue);
      expect(store.verificationRemaining, const Duration(days: 3));
    },
  );

  test('correct photo password does not bypass an independent PIN lock', () {
    store.expireVerification();
    store.lock();
    expect(store.verifyPhotoPassword(DemoStore.defaultPassword), isTrue);
    expect(store.canView, isFalse);
    expect(store.unlockPin('0000'), isFalse);
    expect(store.unlockPin(DemoStore.defaultPin), isTrue);
    expect(store.canView, isTrue);
  });

  test('new device authorization does not unlock photos', () {
    store.beginNewDevice();
    store.connectRepository(
      RepositoryProvider.gitee,
      'demo-user / private-memories',
    );
    expect(store.canView, isFalse);
    expect(store.verifyPhotoPassword(DemoStore.defaultPin), isFalse);
    expect(store.verifyPhotoPassword(DemoStore.defaultPassword), isTrue);
  });

  test(
    'sync order encrypts and splits before upload and preserves original',
    () {
      final p = store.pending.first;
      expect(p.stage, SyncStage.queued);
      expect(p.encrypted, isFalse);
      store.tick();
      expect(p.stage, SyncStage.encrypting);
      store.tick();
      expect(p.stage, SyncStage.splitting);
      expect(p.encrypted, isTrue);
      store.tick();
      expect(p.stage, SyncStage.uploading);
      expect(p.remote, isFalse);
      for (var i = 0; i < 3; i++) {
        store.tick();
      }
      expect(p.remote, isTrue);
      expect(p.local, isTrue);
      expect(p.stage, SyncStage.complete);
    },
  );

  test(
    'expiration pauses active upload; verification resumes the same progress',
    () {
      final p = store.pending.first;
      for (var i = 0; i < 4; i++) {
        store.tick();
      }
      final progress = p.uploadProgress;
      final completed = store.syncedCount;
      store.expireVerification();
      for (var i = 0; i < 10; i++) {
        store.tick();
      }
      expect(p.uploadProgress, progress);
      expect(store.syncedCount, completed);
      store.verifyPhotoPassword('wrong');
      store.tick();
      expect(p.uploadProgress, progress);
      store.verifyPhotoPassword(DemoStore.defaultPassword);
      store.tick();
      expect(p.uploadProgress, greaterThan(progress));
    },
  );

  for (final fault in SyncFault.values.where((f) => f != SyncFault.none)) {
    test('password verification cannot bypass ${fault.name}', () {
      final p = store.pending.first;
      store.setFault(fault);
      store.expireVerification();
      store.verifyPhotoPassword(DemoStore.defaultPassword);
      store.tick();
      expect(p.stage, SyncStage.queued);
      expect(store.syncBlockReason, fault.label);
      store.setFault(SyncFault.none);
      store.tick();
      expect(p.stage, SyncStage.encrypting);
    });
  }

  test(
    'PIN locking strategy is selectable without changing verification timer',
    () {
      final verified = store.lastVerified;
      store.lock();
      expect(store.syncBlockReason, isNull);
      store.setPauseOnLock(true);
      expect(store.syncBlockReason, contains('应用已锁定'));
      store.unlockPin(DemoStore.defaultPin);
      expect(store.syncBlockReason, isNull);
      expect(store.lastVerified, verified);
    },
  );

  test('completed tasks never increment more than once after extra ticks', () {
    for (var i = 0; i < 100; i++) {
      store.tick();
    }
    final count = store.syncedCount;
    for (var i = 0; i < 100; i++) {
      store.tick();
    }
    expect(store.syncedCount, count);
    expect(store.pending, isEmpty);
  });

  test('repository switch queues local samples for the new destination', () {
    final p = store.photos.first;
    expect(p.remote, isTrue);
    store.connectRepository(
      RepositoryProvider.gitee,
      'demo-user / travel-vault',
    );
    expect(p.remote, isFalse);
    expect(p.stage, SyncStage.queued);
    expect(p.local, isTrue);
  });

  for (final scope in DeleteScope.values) {
    test('${scope.name} deletion affects only its selected copies', () {
      final p = store.photos.first;
      expect(store.deletePhoto(p, scope), isNull);
      expect(p.local, scope == DeleteScope.repository);
      expect(p.remote, scope == DeleteScope.local);
      expect(p.otherDevice, scope != DeleteScope.everywhere);
      final state = (p.local, p.remote, p.otherDevice);
      for (var i = 0; i < 100; i++) {
        store.tick();
      }
      expect((p.local, p.remote, p.otherDevice), state);
    });
  }

  test(
    'failed deletion keeps originals and repository unchanged and can retry',
    () {
      final p = store.photos.first;
      store.setDeletionFailure(true);
      expect(store.deletePhoto(p, DeleteScope.everywhere), isNotNull);
      expect(p.local && p.remote && p.otherDevice, isTrue);
      expect(store.deletePhoto(p, DeleteScope.everywhere), isNull);
      expect(p.visible, isFalse);
    },
  );

  test(
    'remote deletion does not claim success while repository unavailable',
    () {
      final p = store.photos.first;
      store.setFault(SyncFault.permission);
      expect(store.deletePhoto(p, DeleteScope.repository), isNotNull);
      expect(p.remote, isTrue);
    },
  );

  test('album add is idempotent and removal does not delete photos', () {
    final p = store.photos.first;
    expect(store.createAlbum('旅行'), isTrue);
    expect(store.createAlbum('旅行'), isFalse);
    store.setAlbum(p, '旅行', true);
    store.setAlbum(p, '旅行', true);
    expect(p.albums.where((a) => a == '旅行').length, 1);
    store.setAlbum(p, '旅行', false);
    expect(p.local && p.remote, isTrue);
  });

  test(
    'import queues samples, export leaves state intact, reset restores defaults',
    () {
      final count = store.totalCount;
      store.importSamples(3);
      expect(store.totalCount, count + 3);
      final p = store.photos.first;
      expect(p.stage, SyncStage.queued);
      expect(store.exportDemo(p), isTrue);
      expect(p.local, isTrue);
      store.setPin('1234');
      store.reset();
      expect(store.totalCount, count);
      expect(store.demoPin, DemoStore.defaultPin);
      expect(store.fault, SyncFault.none);
    },
  );

  test('locked mutations cannot manipulate photos through stale callbacks', () {
    final p = store.photos.first;
    final favorite = p.favorite;
    store.lock();
    store.toggleFavorite(p);
    expect(p.favorite, favorite);
    expect(store.importSamples(3), 0);
    expect(store.exportDemo(p), isFalse);
    expect(store.deletePhoto(p, DeleteScope.everywhere), isNotNull);
    expect(p.local && p.remote, isTrue);
  });

  test(
    'first setup validates two different credentials and restores access',
    () {
      store.beginSetup();
      expect(store.configured, isFalse);
      expect(store.photos, isEmpty);
      expect(
        store.completeSetup(
          password: '1234',
          pin: '1234',
          selectedProvider: RepositoryProvider.gitee,
          selectedRepository: 'demo',
        ),
        isFalse,
      );
      expect(
        store.completeSetup(
          password: 'sample-pass',
          pin: '123',
          selectedProvider: RepositoryProvider.gitee,
          selectedRepository: 'demo',
        ),
        isFalse,
      );
      expect(
        store.completeSetup(
          password: 'sample-pass',
          pin: '1234',
          selectedProvider: RepositoryProvider.gitee,
          selectedRepository: 'demo',
        ),
        isTrue,
      );
      expect(store.canView, isTrue);
      expect(store.demoPassword, 'sample-pass');
    },
  );
}
