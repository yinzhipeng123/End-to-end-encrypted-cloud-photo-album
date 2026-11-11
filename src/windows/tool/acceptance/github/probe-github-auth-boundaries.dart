import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:encrypted_photo_app/repositories/github_api.dart';

/// Real, unauthenticated GitHub checks only. Does not display device codes,
/// persist tokens, use a user vault, open a browser or access a repository.
final class ObservedTransport implements GitHubTransport {
  final _http = GitHubHttpTransport();
  final requests = <Map<String, Object?>>[];

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
    if (token != null ||
        json != null ||
        uri.host != 'github.com' ||
        !{
          '/login/device/code',
          '/login/oauth/access_token',
        }.contains(uri.path)) {
      throw StateError('Probe endpoint boundary violated');
    }
    final entry = <String, Object?>{'path': uri.path};
    requests.add(entry);
    final reply = await _http.send(
      uri,
      operation,
      form: form,
      method: method,
      maxResponseBytes: maxResponseBytes,
      timeout: timeout,
    );
    entry['status'] = reply.status;
    // No response body, headers, device code or credential is logged.
    return reply;
  }
}

Future<void> main() async {
  final wire = ObservedTransport();
  final api = GitHubApi(transport: wire);
  final operation = RepositoryOperation(() {});
  final report = <String, Object?>{
    'atUtc': DateTime.now().toUtc().toIso8601String(),
    'clientId': GitHubRegistration.clientId,
    'authorizationPerformed': false,
    'repositoryWrites': 0,
    'requests': wire.requests,
  };
  try {
    final code = await api.startDevice(operation);
    report['deviceEndpointValidated'] = true;
    report['serverLifetimeSeconds'] = code.expiresIn;
    report['remainingWithinServerLifetime'] =
        code.remaining > Duration.zero &&
        code.remaining <= Duration(seconds: code.expiresIn);

    final requestsBeforeCancel = wire.requests.length;
    final outcome = api
        .pollDevice(code, operation)
        .then<String>(
          (_) => 'unexpected_success',
          onError: (Object error) => error is RepositoryFailure
              ? error.code.name
              : 'unexpected_failure',
        );
    operation.cancel();
    report['cancelResult'] = await outcome;
    report['cancelSentNoTokenRequest'] =
        wire.requests.length == requestsBeforeCancel;
    if (report['cancelResult'] != 'cancelled' ||
        report['cancelSentNoTokenRequest'] != true ||
        report['remainingWithinServerLifetime'] != true) {
      throw StateError('Cancellation/deadline check failed');
    }

    // One deliberately invalid code tests an actual platform rejection. It was
    // not obtained from a user, and cannot represent a user authorization.
    final invalidOperation = RepositoryOperation(() {});
    try {
      await api.pollDevice(
        GitHubDeviceCode('0' * 40, 'TEST-ONLY', 60, 5),
        invalidOperation,
      );
      throw StateError('Invalid code unexpectedly accepted');
    } on RepositoryFailure catch (error) {
      report['invalidCodeResult'] = error.code.name;
      if (error.code != RepositoryFailureCode.invalidDeviceCode) rethrow;
    } finally {
      invalidOperation.cancel();
    }
    report['passed'] = true;
  } catch (error) {
    report['passed'] = false;
    report['failure'] = error is RepositoryFailure
        ? error.code.name
        : error.runtimeType.toString();
    exitCode = 1;
  } finally {
    operation.cancel();
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
  }
}
