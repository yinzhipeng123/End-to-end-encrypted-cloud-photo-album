import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:encrypted_photo_app/repositories/github_api.dart';
import 'package:encrypted_photo_app/repositories/network_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final github = Uri.https('api.github.com', '/rate_limit');
  NetworkProxyResolver resolver(
    Map<String, String> env, [
    SystemProxySettings settings = const SystemProxySettings(),
  ]) => NetworkProxyResolver(
    environment: () => env,
    systemSettings: () => settings,
  );

  test('HTTPS environment wins over HTTP, SOCKS ALL_PROXY and system configuration', () {
    final route = resolver({
      'https_proxy': 'http://127.0.0.1:10808',
      'http_proxy': 'http://127.0.0.1:8888',
      'ALL_PROXY': 'socks5://127.0.0.1:9999',
    }, const SystemProxySettings(server: '127.0.0.1:7777')).resolve(github);
    expect(route.directive, 'PROXY 127.0.0.1:10808');
    expect(route.source, '环境变量');
    expect(
      resolver({'HTTPS_PROXY': 'http://127.0.0.1:10808'})
          .resolve(github)
          .directive,
      route.directive,
    );
    expect(
      resolver({'HTTP_PROXY': 'http://127.0.0.1:10808'})
          .resolve(github)
          .directive,
      route.directive,
    );
    expect(
      resolver({'ALL_PROXY': 'http://127.0.0.1:10808'})
          .resolve(github)
          .directive,
      route.directive,
    );
  });

  test('system settings are reread, with protocol-specific selection and explicit disabled state', () {
    var current = const SystemProxySettings(server: '127.0.0.1:10808');
    final policy = NetworkProxyResolver(
      environment: () => {},
      systemSettings: () => current,
    );
    expect(policy.resolve(github).directive, 'PROXY 127.0.0.1:10808');
    current = const SystemProxySettings(
      server: 'http=127.0.0.1:80;https=127.0.0.1:8080',
    );
    expect(policy.resolve(github).directive, 'PROXY 127.0.0.1:8080');
    current = const SystemProxySettings();
    expect(policy.resolve(github).directive, 'DIRECT');
  });

  test('bypass rules respect domain boundaries and optional ports', () {
    expect(
      resolver({
        'https_proxy': 'http://127.0.0.1:8080',
        'NO_PROXY': '.github.com:443',
      }).resolve(github).proxied,
      false,
    );
    expect(
      resolver({
        'https_proxy': 'http://127.0.0.1:8080',
        'NO_PROXY': '.github.com:80',
      }).resolve(github).proxied,
      true,
    );
    expect(
      resolver({'https_proxy': 'http://127.0.0.1:8080', 'NO_PROXY': 'hub.com'})
          .resolve(github)
          .proxied,
      true,
    );
    expect(
      resolver(
        {},
        const SystemProxySettings(
          server: '127.0.0.1:8080',
          bypass: '<local>;*.github.com',
        ),
      ).resolve(github).proxied,
      false,
    );
    expect(
      resolver(
        {},
        const SystemProxySettings(
          server: '127.0.0.1:8080',
          bypass: 'evilgithub.com',
        ),
      ).resolve(github).proxied,
      true,
    );
    expect(
      resolver({'https_proxy': 'http://[::1]:8080'}).resolve(github).directive,
      'PROXY [::1]:8080',
    );
  });

  test('malformed, authenticated and unsupported proxies fail without disclosing credentials or choosing DIRECT', () {
    for (final value in [
      'socks5://127.0.0.1:10808',
      'https://127.0.0.1:10808',
      'http://private-user:private-password@127.0.0.1:10808',
      'http://127.0.0.1:65536',
      'http://127.0.0.1:0',
      'http://127.0.0.1:8080/path',
      'http://127.0.0.1:8080?secret',
      '127.0.0.1:8080; DIRECT',
      'http://bad\nhost:8080',
    ]) {
      expect(
        () => resolver({'https_proxy': value}).resolve(github),
        throwsA(
          isA<ProxyConfigurationException>().having(
            (e) => e.toString(),
            'sanitized',
            isNot(contains('private-password')),
          ),
        ),
      );
    }
    expect(
      () =>
          resolver({}, const SystemProxySettings(hasPac: true)).resolve(github),
      throwsA(isA<ProxyConfigurationException>()),
    );
    expect(
      () => resolver(
        {},
        const SystemProxySettings(server: 'socks=127.0.0.1:10808'),
      ).resolve(github),
      throwsA(isA<ProxyConfigurationException>()),
    );
  });

  test(
    'production transport reports unsupported proxy before network activity',
    () async {
      final transport = GitHubHttpTransport(
        proxyResolver: resolver({'ALL_PROXY': 'socks5://127.0.0.1:10808'}),
      );
      await expectLater(
        transport.send(github, RepositoryOperation(() {})),
        throwsA(
          isA<RepositoryFailure>().having(
            (e) => e.code,
            'code',
            RepositoryFailureCode.proxyUnsupported,
          ),
        ),
      );
    },
  );

  test('real CONNECT goes only to selected proxy, no token escapes in CONNECT, rejection is not a successful response', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final received = Completer<String>();
    final clients = <Socket>[];
    final subscription = server.listen((socket) {
      clients.add(socket);
      var data = '';
      socket.listen((bytes) {
        data += latin1.decode(bytes);
        if (data.contains('\r\n\r\n') && !received.isCompleted) {
          received.complete(data);
          socket.write(
            'HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\nConnection: close\r\n\r\n',
          );
          socket.flush().then((_) => socket.destroy());
        }
      });
    });
    try {
      final transport = GitHubHttpTransport(
        proxyResolver: resolver({
          'https_proxy': 'http://127.0.0.1:${server.port}',
        }),
      );
      await expectLater(
        transport.send(
          github,
          RepositoryOperation(() {}),
          token: 'test-only-secret',
        ),
        throwsA(
          isA<RepositoryFailure>().having(
            (e) => e.code,
            'code',
            RepositoryFailureCode.proxyConnection,
          ),
        ),
      );
      final request = await received.future.timeout(const Duration(seconds: 3));
      expect(request, startsWith('CONNECT api.github.com:443 HTTP/1.1'));
      expect(request, isNot(contains('test-only-secret')));
      expect(request.toLowerCase(), isNot(contains('authorization:')));
    } finally {
      for (final socket in clients) {
        socket.destroy();
      }
      await subscription.cancel();
      await server.close();
    }
  });

  test(
    'lock cancellation closes a real stalled proxy connection promptly',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = Completer<void>();
      final clients = <Socket>[];
      final subscription = server.listen((socket) {
        clients.add(socket);
        if (!accepted.isCompleted) accepted.complete();
        socket.listen((_) {});
      });
      try {
        final operation = RepositoryOperation(() {});
        final transport = GitHubHttpTransport(
          proxyResolver: resolver({
            'https_proxy': 'http://127.0.0.1:${server.port}',
          }),
        );
        final check = expectLater(
          transport.send(github, operation),
          throwsA(
            isA<RepositoryFailure>().having(
              (e) => e.code,
              'code',
              RepositoryFailureCode.cancelled,
            ),
          ),
        );
        await accepted.future.timeout(const Duration(seconds: 3));
        operation.cancel();
        await check.timeout(const Duration(seconds: 3));
      } finally {
        for (final socket in clients) {
          socket.destroy();
        }
        await subscription.cancel();
        await server.close();
      }
    },
  );

  test(
    'actual Windows settings can be read without mutating the configuration',
    () {
      final settings = WindowsProxySettings.read();
      expect(settings, isA<SystemProxySettings>());
    },
    skip: !Platform.isWindows,
  );
}
