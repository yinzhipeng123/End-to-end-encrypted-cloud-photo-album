import 'dart:convert';
import 'dart:io';

import 'package:encrypted_photo_app/repositories/github_api.dart';

/// Real unauthenticated endpoint probe. Never prints either device code and
/// never polls for credentials or modifies any repository.
Future<void> main() async {
  final operation = RepositoryOperation(() {});
  try {
    final code = await GitHubApi().startDevice(operation);
    stdout.writeln(
      jsonEncode({
        'clientId': GitHubRegistration.clientId,
        'appId': GitHubRegistration.appId,
        'deviceEndpointValidated': true,
        'expiresInSeconds': code.expiresIn,
        'intervalSeconds': code.interval,
        'authorizationPerformed': false,
        'repositoryWrites': 0,
      }),
    );
  } on RepositoryFailure catch (error) {
    stdout.writeln(
      jsonEncode({'deviceEndpointValidated': false, 'error': error.code.name}),
    );
    rethrow;
  } finally {
    operation.cancel();
  }
}
