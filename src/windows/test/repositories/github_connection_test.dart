import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:encrypted_photo_app/app/vault_controller.dart';
import 'package:encrypted_photo_app/repositories/github_api.dart';
import 'package:encrypted_photo_app/repositories/github_connection.dart';
import 'package:encrypted_photo_shared/security/protected_record_store.dart';
import 'package:encrypted_photo_shared/security/security_failure.dart';
import 'package:encrypted_photo_app/security/windows_data_protection.dart';
import 'package:encrypted_photo_app/security/windows_protected_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'github_api_test.dart' show deviceResponse, tokenResponse;

// Only HTTP responses and fault scheduling are substituted. This suite uses
// the production vault controller, real SQLCipher, DPAPI, ACLs and files.
class FixtureGitHub implements GitHubTransport {
  bool installed = false;
  bool private = true;
  bool push = true;
  bool contentsWrite = true;
  bool archived = false;
  bool disabled = false;
  bool allRepos = false;
  int accountId = 101;
  int appId = GitHubRegistration.appId;
  int installationOwner = 101;
  int? userStatus;
  int userRequests = 0;
  int refreshes = 0;
  bool loseRefresh = false;
  String? authorizationError;
  void Function()? onRefresh;
  Future<void> Function()? beforeUser;
  Future<void> Function()? beforeTarget;
  String? lastAccess;
  final paths = <String>[];
  Map<String, Object?> repository() => {
    'id': 303,
    'owner': {'login': 'test-only-owner'},
    'name': 'test-only-photos',
    'private': private,
    'archived': archived,
    'disabled': disabled,
    'permissions': {'push': push},
  };
  @override
  Future<GitHubReply> send(
    Uri uri,
    RepositoryOperation operation, {
    String? token,
    Map<String, String>? form,
    String? method,
    Map<String, Object?>? json,
    int maxResponseBytes = 2 * 1024 * 1024,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    operation.check();
    paths.add(uri.path);
    if (uri.path == '/login/device/code')
      return GitHubReply(200, deviceResponse());
    if (uri.path == '/login/oauth/access_token') {
      if (form!['grant_type'] == 'refresh_token') {
        refreshes++;
        onRefresh?.call();
        if (loseRefresh)
          throw const RepositoryFailure(RepositoryFailureCode.network);
        return GitHubReply(200, tokenResponse('rotated'));
      }
      return GitHubReply(
        200,
        authorizationError == null
            ? tokenResponse()
            : {'error': authorizationError},
      );
    }
    expect(form, isNull, reason: 'Repository operations must stay read-only.');
    lastAccess = token;
    if (uri.path == '/user') {
      userRequests++;
      await beforeUser?.call();
      return GitHubReply(userStatus ?? 200, {
        'id': accountId,
        'login': 'test-only-owner',
      });
    }
    if (uri.path == '/user/installations') {
      return GitHubReply(200, {
        'installations': installed
            ? [
                {
                  'id': 202,
                  'app_id': appId,
                  'account': {'id': installationOwner},
                  'repository_selection': allRepos ? 'all' : 'selected',
                  'suspended_at': null,
                  'permissions': {
                    'contents': contentsWrite ? 'write' : 'read',
                    'metadata': 'read',
                  },
                },
              ]
            : [],
      });
    }
    if (uri.path == '/user/installations/202/repositories') {
      return GitHubReply(200, {
        'repositories': [repository()],
      });
    }
    if (uri.path == '/repos/test-only-owner/test-only-photos') {
      await beforeTarget?.call();
      return GitHubReply(200, repository());
    }
    throw StateError('Unexpected test endpoint');
  }
}

class FaultStore implements ProtectedRecordStore {
  FaultStore(this.inner);
  final ProtectedRecordStore inner;
  Future<void> Function()? afterWrite;
  bool failWrites = false;
  @override
  Future<Uint8List?> read(String name, Uint8List binding) =>
      inner.read(name, binding);
  @override
  Future<void> write(String name, Uint8List clear, Uint8List binding) async {
    if (failWrites)
      throw const SecurityFailure(SecurityFailureCode.storageFailure);
    await inner.write(name, clear, binding);
    await afterWrite?.call();
  }

  @override
  Future<void> remove(String name) => inner.remove(name);
}

void main() {
  if (!Platform.isWindows) return;
  late Directory scratch;
  late Directory directory;
  late VaultController app;
  late FixtureGitHub wire;
  late FaultStore store;
  late GitHubConnection connection;
  late DateTime now;
  final binding = Uint8List.fromList(List.generate(32, (i) => i + 1));
  const password = 'artificial GitHub integration password';

  void attach({Uint8List? differentBinding}) {
    app.github?.dispose();
    connection = GitHubConnection(
      catalog: () => app.catalog,
      protectedStore: store,
      localBinding: differentBinding ?? binding,
      api: GitHubApi(transport: wire, now: () => now),
    );
    app.github = connection;
  }

  Map<String, Object?>? record() =>
      app.catalog.record('preferences', 'github-connection');
  List<File> tokenFiles() => directory
      .listSync()
      .whereType<File>()
      .where((f) => f.path.contains('github-token-'))
      .toList();
  Future<void> restart() async {
    await app.close();
    app.dispose();
    app = VaultController(directory, automaticCheck: false);
    await app.start();
    expect(app.screen, VaultScreen.pin);
    await app.unlock('8392');
    expect(app.screen, VaultScreen.library);
    attach();
  }

  Future<void> authorize({bool installed = false}) async {
    wire.installed = installed;
    await connection.authorize();
    expect(connection.user?.id, 101, reason: connection.message);
    expect(record()?['state'], 'active', reason: connection.message);
  }

  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('epa-github-real-store-');
    directory = Directory('${scratch.path}/vault');
    app = VaultController(directory, automaticCheck: false);
    await app.start();
    await app.initialize(
      password: password,
      confirmation: password,
      pin: '8392',
      pinConfirmation: '8392',
    );
    await app.unlock('8392');
    expect(app.screen, VaultScreen.library, reason: app.message);
    wire = FixtureGitHub();
    store = FaultStore(
      WindowsProtectedStore(directory, WindowsDataProtection()),
    );
    now = DateTime.now().toUtc();
    attach();
  });
  tearDown(() async {
    await app.close();
    app.dispose();
    await scratch.delete(recursive: true);
  });

  for (final error in {
    'bad_verification_code': '未接受本次设备授权码',
    'unverified_user_email': '验证主邮箱',
  }.entries) {
    test(
      'authorization ${error.key} saves no credentials and can be retried',
      () async {
        wire.authorizationError = error.key;
        await connection.authorize();
        expect(connection.message, contains(error.value));
        expect(connection.user, isNull);
        expect(connection.selected, isNull);
        expect(connection.userCode, isNull);
        expect(connection.codeExpiresAt, isNull);
        expect(connection.busy, false);
        expect(record(), isNull);
        expect(tokenFiles(), isEmpty);
        expect(wire.userRequests, 0);

        wire.authorizationError = null;
        await connection.authorize();
        expect(connection.user?.id, 101, reason: connection.message);
        expect(record()?['state'], 'active');
        expect(tokenFiles(), hasLength(1));
      },
    );
  }

  test('uninstalled account persists via real DPAPI and SQLCipher and reopens unverified', () async {
    await authorize();
    expect(connection.selected, isNull);
    expect(connection.repositories, isEmpty);
    expect(connection.message, contains('未查到本相册应用在当前账号下的安装'));
    expect(tokenFiles(), hasLength(1));
    // Release the real exclusive instance.lock before scanning every file.
    await app.close();
    for (final file in directory.listSync(recursive: true).whereType<File>()) {
      final bytes = latin1.decode(await file.readAsBytes());
      for (final secret in [
        'ghu_test_only_fixture',
        'ghr_test_only_fixture',
        'test-only-owner',
      ]) {
        expect(bytes, isNot(contains(secret)), reason: file.path);
      }
    }
    await restart();
    expect(connection.user?.id, 101);
    expect(connection.verified, false);
    await connection.refreshRepositories();
    expect(connection.verified, true, reason: connection.message);
    expect(wire.lastAccess, 'ghu_test_only_fixture');
    expect(connection.selected, isNull);
  });

  test(
    'eligible target is actually encrypted and preserved but never uploads',
    () async {
      await authorize(installed: true);
      await connection.selectRepository(connection.repositories.single);
      expect(connection.selected?.id, 303, reason: connection.message);
      expect(record()?['installationId'], 202);
      expect(tokenFiles(), hasLength(1));
      await restart();
      expect(connection.selected?.id, 303);
      expect(connection.verified, false);
      await connection.refreshRepositories();
      expect(connection.verified, true, reason: connection.message);
      expect(
        wire.paths.every(
          (p) => !p.contains('/git/') && !p.contains('/contents'),
        ),
        true,
      );
      expect(app.catalog.mediaCount, 0);
    },
  );

  test('public, archived, disabled, read-only and all-repository installations cannot be chosen', () async {
    await authorize(installed: true);
    for (final reset in <void Function()>[
      () => wire.private = false,
      () => wire.archived = true,
      () => wire.disabled = true,
      () => wire.push = false,
      () => wire.contentsWrite = false,
      () => wire.allRepos = true,
    ]) {
      wire.private = true;
      wire.archived = false;
      wire.disabled = false;
      wire.push = true;
      wire.contentsWrite = true;
      wire.allRepos = false;
      reset();
      await connection.refreshRepositories();
      expect(connection.repositories.single.eligible, false);
      await connection.selectRepository(connection.repositories.single);
      expect(connection.selected, isNull);
      expect(record()?['repository'], isNull);
      expect(connection.verified, false);
    }
  });

  test('unrelated application and installation owner are ignored', () async {
    wire.appId = 999;
    await authorize(installed: true);
    expect(connection.repositories, isEmpty);
    wire.appId = GitHubRegistration.appId;
    wire.installationOwner = 999;
    await connection.refreshRepositories();
    expect(connection.repositories, isEmpty);
  });

  test(
    'permission change during target verification does not save a target',
    () async {
      await authorize(installed: true);
      wire.beforeTarget = () async => wire.private = false;
      await connection.selectRepository(connection.repositories.single);
      expect(connection.selected, isNull);
      expect(record()?['repository'], isNull);
      expect(connection.verified, false);
    },
  );

  test(
    'selected target removed from installation loses verified state',
    () async {
      await authorize(installed: true);
      await connection.selectRepository(connection.repositories.single);
      wire.installed = false;
      await connection.refreshRepositories();
      expect(connection.selected?.id, 303);
      expect(connection.verified, false);
      expect(connection.message, contains('已选仓库不可用'));
    },
  );

  test(
    'actual DPAPI rejects account, installation and local binding changes',
    () async {
      await authorize(installed: true);
      await connection.selectRepository(connection.repositories.single);
      final saved = record()!;
      final requests = wire.paths.length;
      for (final changed in [
        {
          ...saved,
          'user': {'id': 999, 'login': 'test-only-owner'},
        },
        {
          ...saved,
          'installationId': 999,
          'repository': {
            ...(saved['repository'] as Map),
            'installationId': 999,
          },
        },
      ]) {
        app.catalog.putRecord('preferences', 'github-connection', changed);
        attach();
        await connection.refreshRepositories();
        expect(connection.verified, false);
        expect(wire.paths.length, requests);
      }
      app.catalog.putRecord('preferences', 'github-connection', saved);
      attach(differentBinding: Uint8List(32));
      await connection.refreshRepositories();
      expect(connection.verified, false);
      expect(wire.paths.length, requests);
    },
  );

  test('missing or damaged sealed token cannot fall back to an authenticated account', () async {
    await authorize();
    final file = tokenFiles().single;
    final bytes = await file.readAsBytes();
    final saved = record()!;
    await file.writeAsBytes([1, 2, 3], flush: true);
    await connection.refreshRepositories();
    expect(connection.verified, false);
    await file.writeAsBytes(bytes, flush: true);
    app.catalog.putRecord('preferences', 'github-connection', saved);
    await file.delete();
    await connection.refreshRepositories();
    expect(connection.verified, false);
    expect(record()?['state'], 'reauthorize');
  });

  test(
    'real rotation writes durable intent first and saves the complete new pair',
    () async {
      await authorize();
      final old = record()!['credential'];
      now = now.add(const Duration(hours: 9));
      wire.onRefresh = () => expect(record()?['state'], 'refreshing');
      await connection.refreshRepositories();
      expect(connection.verified, true, reason: connection.message);
      expect(wire.refreshes, 1);
      expect(wire.lastAccess, 'ghu_test_only_rotated');
      expect(record()?['credential'], isNot(old));
      expect(record()?['state'], 'active');
      expect(tokenFiles(), hasLength(1));
      await restart();
      await connection.refreshRepositories();
      expect(wire.lastAccess, 'ghu_test_only_rotated');
      expect(wire.refreshes, 1);
    },
  );

  test('lost refresh response or interrupted durable intent never reuses old pair after restart', () async {
    await authorize();
    now = now.add(const Duration(hours: 9));
    wire.loseRefresh = true;
    await connection.refreshRepositories();
    expect(record()?['state'], 'reauthorize');
    final calls = wire.paths.length;
    await restart();
    await connection.refreshRepositories();
    expect(wire.paths.length, calls);
    expect(connection.verified, false);
    app.catalog.putRecord('preferences', 'github-connection', {
      ...record()!,
      'state': 'refreshing',
    });
    await restart();
    await connection.refreshRepositories();
    expect(wire.paths.length, calls);
    expect(connection.verified, false);
  });

  test('seal failure during refresh invalidates connection instead of keeping stale pair active', () async {
    await authorize();
    now = now.add(const Duration(hours: 9));
    store.failWrites = true;
    await connection.refreshRepositories();
    expect(record()?['state'], 'reauthorize');
    expect(connection.verified, false);
    final calls = wire.paths.length;
    await restart();
    await connection.refreshRepositories();
    expect(wire.paths.length, calls);
  });

  test('system suspension revokes a late HTTP callback and preserves the saved connection', () async {
    await authorize();
    final saved = record()!;
    final entered = Completer<void>();
    final release = Completer<void>();
    wire.beforeUser = () async {
      entered.complete();
      await release.future;
    };
    final oldConnection = connection;
    final running = connection.refreshRepositories();
    await entered.future;
    app.suspend();
    expect(app.github, isNull);
    expect(oldConnection.user, isNull);
    release.complete();
    await running;
    await app.unlock('8392');
    expect(record(), saved);
    expect(oldConnection.user, isNull);
    expect(oldConnection.verified, false);
  });

  test('lock after sealing but before SQLCipher commit cannot replace the referenced generation', () async {
    await authorize(installed: true);
    final saved = record()!;
    store.afterWrite = () async => app.lock();
    final oldConnection = connection;
    await connection.selectRepository(connection.repositories.single);
    expect(app.screen, VaultScreen.pin);
    expect(oldConnection.selected, isNull);
    await app.unlock('8392');
    expect(record(), saved);
    expect(tokenFiles(), hasLength(1));
  });

  test('cancellation during device interval stores nothing and sends no token poll', () async {
    final showing = Completer<void>();
    connection.addListener(() {
      if (connection.userCode != null && !showing.isCompleted)
        showing.complete();
    });
    final running = connection.authorize();
    await showing.future;
    connection.cancelAuthorization();
    await running;
    expect(connection.userCode, isNull);
    expect(connection.verified, false);
    expect(record(), isNull);
    expect(tokenFiles(), isEmpty);
    expect(wire.paths, ['/login/device/code']);
  });

  test('401 and account mismatch require reauthorization without exposing response bodies', () async {
    await authorize();
    wire.userStatus = 401;
    await connection.refreshRepositories();
    expect(record()?['state'], 'reauthorize');
    expect(connection.verified, false);
    wire.userStatus = null;
    await authorize();
    wire.accountId = 999;
    await connection.refreshRepositories();
    expect(record()?['state'], 'reauthorize');
    expect(connection.verified, false);
    expect(connection.message, isNot(contains('ghu_')));
  });

  test('disconnect removes current real sealed token and remains disconnected on restart', () async {
    await authorize();
    await connection.disconnect();
    expect(record()?['state'], 'disconnected');
    expect(tokenFiles(), isEmpty);
    expect(connection.user, isNull);
    expect(connection.message, contains('尚未撤销'));
    await restart();
    expect(connection.user, isNull);
    expect(connection.selected, isNull);
    expect(connection.verified, false);
  });
}
