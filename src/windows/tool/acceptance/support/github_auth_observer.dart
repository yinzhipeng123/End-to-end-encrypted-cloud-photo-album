import 'dart:async';

import 'package:encrypted_photo_app/repositories/github_api.dart';

/// Acceptance-only real transport decorator. Never imported by lib/main.dart.
/// Restricts this harness to authorization and read-only account/repository
/// queries and records only fixed categories, status codes and known errors.
final class GitHubAuthObserver implements GitHubTransport {
  GitHubAuthObserver({GitHubTransport? delegate})
    : _delegate = delegate ?? GitHubHttpTransport();
  final GitHubTransport _delegate;
  final events = <Map<String, Object?>>[];
  int blockedRequests = 0;

  void _record(Map<String, Object?> event) {
    events.add({'atUtc': DateTime.now().toUtc().toIso8601String(), ...event});
    if (events.length > 100) events.removeAt(0);
  }

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
    final oauth =
        uri.host == 'github.com' &&
        {
          '/login/device/code',
          '/login/oauth/access_token',
        }.contains(uri.path) &&
        uri.query.isEmpty &&
        form != null &&
        token == null &&
        (method == null || method == 'POST');
    final query =
        uri.host == 'api.github.com' &&
        form == null &&
        (method == null || method == 'GET') &&
        (uri.path == '/user' ||
            uri.path == '/user/installations' ||
            RegExp(r'^/user/installations/[0-9]+/repositories$')
                .hasMatch(uri.path) ||
            RegExp(r'^/repos/[^/]+/[^/]+$').hasMatch(uri.path));
    if (uri.scheme != 'https' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        json != null ||
        !(oauth || query)) {
      blockedRequests++;
      _record({'kind': 'blocked'});
      throw const RepositoryFailure(RepositoryFailureCode.configuration);
    }
    final kind = oauth
        ? (uri.path == '/login/device/code' ? 'device' : 'token')
        : (uri.path == '/user' ? 'account' : 'repository_query');
    try {
      final reply = await _delegate.send(
        uri,
        operation,
        token: token,
        form: form,
        method: method,
        json: json,
        maxResponseBytes: maxResponseBytes,
        timeout: timeout,
      );
      final error = reply.body['error'];
      const knownErrors = {
        'authorization_pending',
        'slow_down',
        'expired_token',
        'token_expired',
        'access_denied',
        'bad_verification_code',
        'incorrect_device_code',
        'unverified_user_email',
        'incorrect_client_credentials',
        'device_flow_disabled',
        'bad_refresh_token',
        'unsupported_grant_type',
      };
      _record({
        'kind': kind,
        'status': reply.status,
        if (oauth && error != null)
          'error': knownErrors.contains(error) ? error : 'unrecognized',
        if (kind == 'token' && error == null)
          'tokenResponseReceived': reply.body.containsKey('access_token'),
      });
      return reply;
    } catch (error) {
      _record({
        'kind': kind,
        'failure': error is RepositoryFailure ? error.code.name : 'unexpected',
      });
      rethrow;
    }
  }
}
