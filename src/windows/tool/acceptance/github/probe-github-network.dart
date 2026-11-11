// Read-only public HTTPS checks using the production transport; no tokens,
// user media, repository operations, or vault access.
import 'dart:convert';
import 'dart:io';

import 'package:encrypted_photo_app/repositories/github_api.dart';
import 'package:encrypted_photo_app/repositories/network_proxy.dart';

Future<void> main() async {
  final results = <Map<String, Object?>>[];
  for (final entry in {
    'system-without-shell-environment': NetworkProxyResolver(
      environment: () => {},
    ),
    'provided-environment': NetworkProxyResolver(
      environment: () => {
        'https_proxy': 'http://127.0.0.1:10808',
        'http_proxy': 'http://127.0.0.1:10808',
        'all_proxy': 'socks5://127.0.0.1:10808',
      },
    ),
  }.entries) {
    final transport = GitHubHttpTransport(proxyResolver: entry.value);
    for (final uri in [
      Uri.https('api.github.com', '/rate_limit'),
      Uri.https('github.com', '/login/device/code'),
    ]) {
      try {
        // The second request only allocates an unused device code to check the
        // official auth endpoint; it does not poll or authorize an account.
        final reply = await transport.send(
          uri,
          RepositoryOperation(() {}),
          form: uri.host == 'github.com'
              ? {'client_id': GitHubRegistration.clientId}
              : null,
        );
        final ok =
            reply.status == 200 &&
            (uri.host == 'api.github.com'
                ? reply.body.containsKey('resources')
                : reply.body.containsKey('device_code'));
        results.add({
          'case': entry.key,
          'host': uri.host,
          'route': transport.networkDescription,
          'status': reply.status,
          'validResponse': ok,
        });
        if (!ok) exitCode = 1;
      } on RepositoryFailure catch (error) {
        results.add({
          'case': entry.key,
          'host': uri.host,
          'failure': error.code.name,
        });
        exitCode = 1;
      }
    }
  }
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(results));
}
