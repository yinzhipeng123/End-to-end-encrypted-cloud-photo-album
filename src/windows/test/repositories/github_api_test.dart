import 'dart:async';

import 'package:encrypted_photo_app/repositories/github_api.dart';
import 'package:flutter_test/flutter_test.dart';

// These are protocol tests with an HTTP substitute, not platform acceptance.
class ScriptedTransport implements GitHubTransport {
  ScriptedTransport(this.reply);
  final FutureOr<GitHubReply> Function(Uri, String?, Map<String, String>?)
  reply;
  int calls = 0;
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
    calls++;
    operation.check();
    return await reply(uri, token, form);
  }
}

Map<String, Object?> tokenResponse([String generation = 'fixture']) => {
  'access_token': 'ghu_test_only_$generation',
  'refresh_token': 'ghr_test_only_$generation',
  'token_type': 'bearer',
  'expires_in': 28800,
  'refresh_token_expires_in': 15897600,
};

Map<String, Object?> deviceResponse() => {
  'device_code': 'test_only_device_code',
  'user_code': 'ABCD-1234',
  'verification_uri': GitHubRegistration.devicePage,
  'expires_in': 900,
  'interval': 1,
};

Matcher failure(RepositoryFailureCode code) =>
    throwsA(isA<RepositoryFailure>().having((e) => e.code, 'code', code));

void main() {
  test(
    'device flow uses public ID and POST form without a client secret',
    () async {
      final wire = ScriptedTransport((uri, token, form) {
        expect(uri.toString(), 'https://github.com/login/device/code');
        expect(uri.query, isEmpty);
        expect(token, isNull);
        expect(form, {
          'client_id': GitHubRegistration.clientId,
          'scope': 'offline_access',
        });
        return GitHubReply(200, deviceResponse());
      });
      final code = await GitHubApi(transport: wire)
          .startDevice(RepositoryOperation(() {}));
      expect(code.userCode, 'ABCD-1234');
      expect(code.toString(), isNot(contains(code.deviceCode)));
    },
  );

  test(
    'pending and slow_down obey server interval and return expiring token pair',
    () async {
      var index = 0;
      final wire = ScriptedTransport((uri, token, form) {
        expect(form!['client_secret'], isNull);
        expect(form['device_code'], 'test_only_device_code');
        return GitHubReply(
          200,
          [
            {'error': 'authorization_pending'},
            {'error': 'slow_down', 'interval': 12},
            tokenResponse(),
          ][index++],
        );
      });
      final waits = <Duration>[];
      final pair = await GitHubApi(transport: wire).pollDevice(
        GitHubDeviceCode('test_only_device_code', 'ABCD-1234', 900, 5),
        RepositoryOperation(() {}),
        wait: (duration) async => waits.add(duration),
      );
      expect(waits.map((d) => d.inSeconds), [5, 5, 12]);
      expect(pair.accessToken, 'ghu_test_only_fixture');
      expect(pair.toString(), isNot(contains(pair.refreshToken)));
    },
  );

  for (final entry in {
    'access_denied': RepositoryFailureCode.denied,
    'expired_token': RepositoryFailureCode.expired,
    'device_flow_disabled': RepositoryFailureCode.configuration,
    'incorrect_client_credentials': RepositoryFailureCode.configuration,
    'bad_refresh_token': RepositoryFailureCode.authorizationRequired,
    'bad_verification_code': RepositoryFailureCode.invalidDeviceCode,
    'incorrect_device_code': RepositoryFailureCode.invalidDeviceCode,
    'unverified_user_email': RepositoryFailureCode.unverifiedEmail,
  }.entries) {
    test('OAuth ${entry.key} cannot produce a successful connection', () async {
      final api = GitHubApi(
        transport: ScriptedTransport(
          (u, t, f) => GitHubReply(200, {'error': entry.key}),
        ),
      );
      await expectLater(
        api.pollDevice(
          GitHubDeviceCode('fixture', 'ABCD-1234', 900, 5),
          RepositoryOperation(() {}),
          wait: (_) async {},
        ),
        failure(entry.value),
      );
    });
  }

  test(
    'reject untrusted verification URI and malformed or nonexpiring tokens',
    () async {
      for (final field in [
        {'verification_uri': 'https://example.com'},
        {'user_code': 'ABCD\n1234'},
        {'expires_in': 0},
        {'interval': -1},
      ]) {
        final api = GitHubApi(
          transport: ScriptedTransport(
            (u, t, f) => GitHubReply(200, {...deviceResponse(), ...field}),
          ),
        );
        await expectLater(
          api.startDevice(RepositoryOperation(() {})),
          failure(RepositoryFailureCode.invalidResponse),
        );
      }
      for (final field in [
        {'access_token': 'other_fixture'},
        {'refresh_token': null},
        {'expires_in': 0},
        {'token_type': 'unexpected'},
      ]) {
        expect(
          () => GitHubTokens.fromResponse({
            ...tokenResponse(),
            ...field,
          }, DateTime.now()),
          failure(RepositoryFailureCode.invalidResponse),
        );
      }
    },
  );

  test(
    'cancellation stops interval and rejects a late HTTP response',
    () async {
      final op = RepositoryOperation(() {});
      final waiting = op.wait(const Duration(hours: 1));
      final check = expectLater(
        waiting,
        failure(RepositoryFailureCode.cancelled),
      );
      op.cancel();
      await check;
      final pending = Completer<GitHubReply>();
      final second = RepositoryOperation(() {});
      final api = GitHubApi(
        transport: ScriptedTransport((u, t, f) => pending.future),
      );
      final reading = api.get(['user'], 'fixture', second);
      second.cancel();
      pending.complete(GitHubReply(200, {'id': 10}));
      await expectLater(reading, failure(RepositoryFailureCode.cancelled));
    },
  );

  test(
    'delayed polling cannot restart the lifetime of an issued device code',
    () async {
      final wire = ScriptedTransport(
        (u, t, f) => GitHubReply(200, tokenResponse()),
      );
      final code = GitHubDeviceCode('fixture', 'ABCD-1234', 1, 1);
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await expectLater(
        GitHubApi(transport: wire)
            .pollDevice(code, RepositoryOperation(() {}), wait: (_) async {}),
        failure(RepositoryFailureCode.expired),
      );
      expect(wire.calls, 0);
    },
  );

  test(
    'device response received after its conservative deadline is rejected',
    () async {
      final wire = ScriptedTransport((u, t, f) async {
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        return GitHubReply(200, {...deviceResponse(), 'expires_in': 1});
      });
      await expectLater(
        GitHubApi(transport: wire).startDevice(RepositoryOperation(() {})),
        failure(RepositoryFailureCode.expired),
      );
      expect(wire.calls, 1);
    },
  );

  test(
    'unexpected HTTP success status cannot satisfy a different accepted status',
    () async {
      final api = GitHubApi(
        transport: ScriptedTransport(
          (u, t, f) => GitHubReply(200, {'sha': 'fixture'}),
        ),
      );
      await expectLater(
        api.request(
          ['repos', 'fixture', 'test', 'git', 'commits'],
          'test_only',
          RepositoryOperation(() {}),
          method: 'POST',
          accepted: const {201},
        ),
        failure(RepositoryFailureCode.invalidResponse),
      );
    },
  );

  test(
    'local monotonic deadline rejects a late successful token response',
    () async {
      final api = GitHubApi(
        transport: ScriptedTransport((u, t, f) async {
          await Future<void>.delayed(const Duration(milliseconds: 1100));
          return GitHubReply(200, tokenResponse());
        }),
      );
      await expectLater(
        api.pollDevice(
          GitHubDeviceCode('fixture', 'ABCD-1234', 1, 1),
          RepositoryOperation(() {}),
          wait: (_) async {},
        ),
        failure(RepositoryFailureCode.expired),
      );
    },
  );

  test(
    'refresh uses form only and refuses expired refresh token without network',
    () async {
      var now = DateTime.utc(2026, 11, 10);
      final wire = ScriptedTransport((uri, token, form) {
        expect(uri.query, isEmpty);
        expect(form!['grant_type'], 'refresh_token');
        expect(form['client_secret'], isNull);
        expect(form['refresh_token'], 'ghr_test_only_fixture');
        return GitHubReply(200, tokenResponse('rotated'));
      });
      final pair = GitHubTokens.fromResponse(tokenResponse(), now);
      final api = GitHubApi(transport: wire, now: () => now);
      expect(
        (await api.refresh(pair, RepositoryOperation(() {}))).accessToken,
        'ghu_test_only_rotated',
      );
      now = pair.refreshExpiresAt;
      await expectLater(
        api.refresh(pair, RepositoryOperation(() {})),
        failure(RepositoryFailureCode.authorizationRequired),
      );
      expect(wire.calls, 1);
    },
  );

  test('401, permission 403, 404 and throttling remain distinct; throttling stops retry', () async {
    for (final entry in {
      401: RepositoryFailureCode.authorizationRequired,
      403: RepositoryFailureCode.permission,
      404: RepositoryFailureCode.unavailable,
    }.entries) {
      final api = GitHubApi(
        transport: ScriptedTransport((u, t, f) => GitHubReply(entry.key, {})),
      );
      await expectLater(
        api.get(['user'], 'fixture', RepositoryOperation(() {})),
        failure(entry.value),
      );
    }
    var now = DateTime.utc(2026, 11, 10);
    final wire = ScriptedTransport(
      (u, t, f) => GitHubReply(403, {}, {'retry-after': '60'}),
    );
    final api = GitHubApi(transport: wire, now: () => now);
    for (var i = 0; i < 2; i++) {
      await expectLater(
        api.get(['user'], 'fixture', RepositoryOperation(() {})),
        failure(RepositoryFailureCode.rateLimited),
      );
    }
    expect(wire.calls, 1);
    now = now.add(const Duration(minutes: 1));
    await expectLater(
      api.get(['user'], 'fixture', RepositoryOperation(() {})),
      failure(RepositoryFailureCode.rateLimited),
    );
    expect(wire.calls, 2);
  });

  test(
    'pagination generates only official endpoints and rejects non-list data',
    () async {
      final wire = ScriptedTransport((uri, token, form) {
        expect(uri.host, 'api.github.com');
        expect(form, isNull);
        expect(uri.queryParameters['per_page'], '100');
        final page = uri.queryParameters['page'];
        return page == '1'
            ? GitHubReply(
                200,
                {
                  'repositories': [
                    {'id': 1},
                  ],
                },
                {'link': '<https://untrusted.invalid/>; rel="next"'},
              )
            : GitHubReply(200, {
                'repositories': [
                  {'id': 2},
                ],
              });
      });
      final api = GitHubApi(transport: wire);
      expect(
        (await api.pages(
          ['user', 'installations', '1', 'repositories'],
          'repositories',
          'fixture',
          RepositoryOperation(() {}),
        )).length,
        2,
      );
      final invalid = GitHubApi(
        transport: ScriptedTransport(
          (u, t, f) => GitHubReply(200, {'repositories': 'invalid'}),
        ),
      );
      await expectLater(
        invalid.pages(
          ['user'],
          'repositories',
          'fixture',
          RepositoryOperation(() {}),
        ),
        failure(RepositoryFailureCode.invalidResponse),
      );
    },
  );

  test(
    'real HTTP transport rejects unsafe endpoints before any request',
    () async {
      for (final uri in [
        'http://api.github.com/user',
        'https://example.com/user',
        'https://api.github.com:444/user',
        'https://user@api.github.com/user',
        'https://github.com/login/device',
      ]) {
        await expectLater(
          GitHubHttpTransport().send(
            Uri.parse(uri),
            RepositoryOperation(() {}),
            token: 'test_only',
          ),
          failure(RepositoryFailureCode.configuration),
        );
      }
    },
  );
}
