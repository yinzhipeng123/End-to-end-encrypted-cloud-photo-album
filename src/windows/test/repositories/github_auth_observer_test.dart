import 'dart:convert';

import 'package:encrypted_photo_app/repositories/github_api.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/acceptance/support/github_auth_observer.dart';
import 'github_api_test.dart' show ScriptedTransport;

void main() {
  test(
    'acceptance transport prevents repository mutations before delegation',
    () async {
      final wire = ScriptedTransport((u, t, f) => GitHubReply(200, {}));
      final observed = GitHubAuthObserver(delegate: wire);
      for (final request in [
        ('https://api.github.com/repos/example/photos', 'PATCH'),
        ('https://api.github.com/repos/example/photos/git/refs', 'POST'),
        ('https://api.github.com/repos/example/photos/contents/a', 'PUT'),
        ('https://api.github.com/repos/example/photos', 'DELETE'),
        ('https://other.invalid/user', 'GET'),
      ]) {
        await expectLater(
          observed.send(
            Uri.parse(request.$1),
            RepositoryOperation(() {}),
            method: request.$2,
          ),
          throwsA(isA<RepositoryFailure>()),
        );
      }
      expect(wire.calls, 0);
      expect(observed.blockedRequests, 5);
    },
  );

  test(
    'acceptance report omits supplied credentials and arbitrary server text',
    () async {
      final wire = ScriptedTransport(
        (u, t, f) => GitHubReply(200, {
          'access_token': 'ghu_artificial_secret',
          'refresh_token': 'ghr_artificial_secret',
          'device_code': 'artificial_device_secret',
          'user_code': 'ABCD-1234',
          'error': 'untrusted arbitrary secret',
          'message': 'artificial_account_name',
        }),
      );
      final observed = GitHubAuthObserver(delegate: wire);
      await observed.send(
        Uri.https('github.com', '/login/oauth/access_token'),
        RepositoryOperation(() {}),
        form: {'device_code': 'artificial_device_secret'},
      );
      final encoded = jsonEncode(observed.events);
      for (final secret in ['artificial', 'ABCD-1234', 'untrusted']) {
        expect(encoded, isNot(contains(secret)));
      }
      expect(observed.events.single['error'], 'unrecognized');
      expect(wire.calls, 1);
    },
  );
}
