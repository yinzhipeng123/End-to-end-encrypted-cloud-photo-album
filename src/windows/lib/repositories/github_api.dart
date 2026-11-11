import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:encrypted_photo_app/repositories/network_proxy.dart';

/// Public registration identifiers supplied by the owner; never secrets.
abstract final class GitHubRegistration {
  static const clientId = 'Iv23li0GQwH80cVzX6yX';
  static const appId = 5690653;
  static const apiVersion = '2026-03-10';
  static const devicePage = 'https://github.com/login/device';
  static const manageAppsPage = 'https://github.com/settings/apps';
}

enum RepositoryFailureCode {
  cancelled,
  network,
  proxyConfiguration,
  proxyUnsupported,
  proxyConnection,
  tls,
  invalidResponse,
  denied,
  expired,
  invalidDeviceCode,
  unverifiedEmail,
  configuration,
  authorizationRequired,
  permission,
  rateLimited,
  unavailable,
  invalidTarget,
  storage,
  browser,
  conflict,
}

final class RepositoryFailure implements Exception {
  const RepositoryFailure(this.code, {this.retryAt});
  final RepositoryFailureCode code;
  final DateTime? retryAt;
  @override
  String toString() => 'RepositoryFailure(${code.name})';
}

/// One foreground operation, revoked by the production vault access boundary.
final class RepositoryOperation {
  RepositoryOperation(this.requireAccess);
  final void Function() requireAccess;
  bool _cancelled = false;
  final _callbacks = <void Function()>{};
  void check() {
    if (_cancelled)
      throw const RepositoryFailure(RepositoryFailureCode.cancelled);
    requireAccess();
  }

  void Function() onCancel(void Function() callback) {
    check();
    _callbacks.add(callback);
    return () => _callbacks.remove(callback);
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final callback in _callbacks.toList()) {
      callback();
    }
    _callbacks.clear();
  }

  Future<void> wait(Duration duration) async {
    check();
    final done = Completer<void>();
    final timer = Timer(duration, () {
      if (!done.isCompleted) done.complete();
    });
    final remove = onCancel(() {
      if (!done.isCompleted)
        done.completeError(
          const RepositoryFailure(RepositoryFailureCode.cancelled),
        );
    });
    try {
      await done.future;
      check();
    } finally {
      timer.cancel();
      remove();
    }
  }
}

final class GitHubReply {
  GitHubReply(this.status, this.body, [this.headers = const {}]);
  final int status;
  final Map<String, Object?> body;
  final Map<String, String> headers;
}

abstract interface class GitHubTransport {
  Future<GitHubReply> send(
    Uri uri,
    RepositoryOperation operation, {
    String? token,
    Map<String, String>? form,
    String? method,
    Map<String, Object?>? json,
    int maxResponseBytes = 2 * 1024 * 1024,
    Duration timeout = const Duration(seconds: 45),
  });
}

/// Uses real HTTPS; no production fallback or response logging.
final class GitHubHttpTransport implements GitHubTransport {
  GitHubHttpTransport({NetworkProxyResolver? proxyResolver})
    : proxyResolver = proxyResolver ?? NetworkProxyResolver();
  final NetworkProxyResolver proxyResolver;

  String get networkDescription {
    try {
      return proxyResolver.resolve(Uri.https('api.github.com')).description;
    } on ProxyConfigurationException catch (error) {
      return error.problem == ProxyConfigurationProblem.unsupported
          ? '检测到暂不支持的代理配置；请启用 HTTP 代理（当前不支持仅 SOCKS、PAC 或 WPAD）'
          : '代理配置无法读取或格式无效，请检查系统代理或启动环境变量';
    }
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
    if (uri.scheme != 'https' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        !(uri.host == 'api.github.com' || uri.host == 'github.com') ||
        (token != null && uri.host != 'api.github.com') ||
        (form != null && json != null) ||
        (method != null && !{'GET', 'POST', 'PATCH', 'PUT'}.contains(method)) ||
        maxResponseBytes < 1 ||
        maxResponseBytes > 8 * 1024 * 1024 ||
        (json != null && uri.host != 'api.github.com')) {
      throw const RepositoryFailure(RepositoryFailureCode.configuration);
    }
    final ProxyRoute route;
    try {
      route = proxyResolver.resolve(uri);
    } on ProxyConfigurationException catch (error) {
      throw RepositoryFailure(
        error.problem == ProxyConfigurationProblem.unsupported
            ? RepositoryFailureCode.proxyUnsupported
            : RepositoryFailureCode.proxyConfiguration,
      );
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..findProxy = (_) => route.directive;
    final remove = operation.onCancel(() => client.close(force: true));
    try {
      return await (() async {
        final request = await client.openUrl(
          method ?? (form == null ? 'GET' : 'POST'),
          uri,
        );
        operation.check();
        request.followRedirects = false;
        request.headers.set(HttpHeaders.acceptHeader, 'application/json');
        request.headers.set(HttpHeaders.userAgentHeader, 'EncryptedPhotoApp');
        if (uri.host == 'api.github.com') {
          request.headers.set(
            'X-GitHub-Api-Version',
            GitHubRegistration.apiVersion,
          );
        }
        if (token != null)
          request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        if (form != null) {
          request.headers.contentType = ContentType(
            'application',
            'x-www-form-urlencoded',
          );
          request.write(Uri(queryParameters: form).query);
        }
        if (json != null) {
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(json));
        }
        operation.check();
        final response = await request.close();
        final bytes = BytesBuilder(copy: false);
        if (response.contentLength > maxResponseBytes) {
          throw const RepositoryFailure(RepositoryFailureCode.invalidResponse);
        }
        await for (final part in response.timeout(
          const Duration(seconds: 30),
        )) {
          operation.check();
          if (bytes.length + part.length > maxResponseBytes) {
            throw const RepositoryFailure(
              RepositoryFailureCode.invalidResponse,
            );
          }
          bytes.add(part);
        }
        operation.check();
        Map<String, Object?> body = const {};
        try {
          final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
          if (decoded is Map<String, dynamic>)
            body = decoded;
          else if (response.statusCode >= 200 && response.statusCode < 300) {
            throw const RepositoryFailure(
              RepositoryFailureCode.invalidResponse,
            );
          }
        } on FormatException {
          if (response.statusCode >= 200 && response.statusCode < 300) {
            throw const RepositoryFailure(
              RepositoryFailureCode.invalidResponse,
            );
          }
        }
        return GitHubReply(response.statusCode, body, {
          for (final name in [
            'retry-after',
            'x-ratelimit-remaining',
            'x-ratelimit-reset',
            'link',
          ])
            if (response.headers.value(name) case final String value)
              name: value,
        });
      })().timeout(timeout);
    } on RepositoryFailure {
      rethrow;
    } on HandshakeException {
      operation.check();
      throw const RepositoryFailure(RepositoryFailureCode.tls);
    } catch (_) {
      operation.check();
      throw RepositoryFailure(
        route.proxied
            ? RepositoryFailureCode.proxyConnection
            : RepositoryFailureCode.network,
      );
    } finally {
      remove();
      client.close(force: true);
    }
  }
}

String githubString(Object? value, {int maxLength = 4096}) {
  if (value is! String ||
      value.isEmpty ||
      value.length > maxLength ||
      value.runes.any((c) => c < 32 || c == 127)) {
    throw const RepositoryFailure(RepositoryFailureCode.invalidResponse);
  }
  return value;
}

int githubInt(Object? value, {int maximum = 9007199254740991}) {
  if (value is! int || value <= 0 || value > maximum) {
    throw const RepositoryFailure(RepositoryFailureCode.invalidResponse);
  }
  return value;
}

Map<String, Object?> githubMap(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const RepositoryFailure(RepositoryFailureCode.invalidResponse);
  }
  return value;
}

final class GitHubTokens {
  GitHubTokens(
    this.accessToken,
    this.refreshToken,
    this.expiresAt,
    this.refreshExpiresAt,
  );
  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
  final DateTime refreshExpiresAt;
  static GitHubTokens fromResponse(
    Map<String, Object?> data,
    DateTime issuedAt,
  ) {
    final access = githubString(data['access_token']);
    final refresh = githubString(data['refresh_token']);
    if (!access.startsWith('ghu_') ||
        !refresh.startsWith('ghr_') ||
        data['token_type'] != 'bearer') {
      throw const RepositoryFailure(RepositoryFailureCode.invalidResponse);
    }
    return GitHubTokens(
      access,
      refresh,
      issuedAt.add(
        Duration(seconds: githubInt(data['expires_in'], maximum: 31536000)),
      ),
      issuedAt.add(
        Duration(
          seconds: githubInt(
            data['refresh_token_expires_in'],
            maximum: 31536000,
          ),
        ),
      ),
    );
  }

  Map<String, Object?> toRecord() => {
    'access': accessToken,
    'refresh': refreshToken,
    'expiresAt': expiresAt.millisecondsSinceEpoch,
    'refreshExpiresAt': refreshExpiresAt.millisecondsSinceEpoch,
  };
  static GitHubTokens fromRecord(Map<String, Object?> data) {
    final access = githubString(data['access']);
    final refresh = githubString(data['refresh']);
    if (!access.startsWith('ghu_') || !refresh.startsWith('ghr_')) {
      throw const RepositoryFailure(
        RepositoryFailureCode.authorizationRequired,
      );
    }
    return GitHubTokens(
      access,
      refresh,
      DateTime.fromMillisecondsSinceEpoch(
        githubInt(data['expiresAt']),
        isUtc: true,
      ),
      DateTime.fromMillisecondsSinceEpoch(
        githubInt(data['refreshExpiresAt']),
        isUtc: true,
      ),
    );
  }

  @override
  String toString() => 'GitHubTokens(<redacted>)';
}

final class GitHubDeviceCode {
  GitHubDeviceCode(
    this.deviceCode,
    this.userCode,
    this.expiresIn,
    this.interval,
  ) : _elapsed = Stopwatch()..start();
  GitHubDeviceCode._(
    this.deviceCode,
    this.userCode,
    this.expiresIn,
    this.interval,
    this._elapsed,
  );
  final Stopwatch _elapsed;
  final String deviceCode;
  final String userCode;
  final int expiresIn;
  final int interval;
  // This lifetime belongs to the issued code, not to each polling attempt.
  Duration get remaining => Duration(
    milliseconds: math.max(0, expiresIn * 1000 - _elapsed.elapsedMilliseconds),
  );
  @override
  String toString() => 'GitHubDeviceCode(<redacted>)';
}

final class GitHubApi {
  GitHubApi({GitHubTransport? transport, DateTime Function()? now})
    : transport = transport ?? GitHubHttpTransport(),
      now = now ?? DateTime.now;
  final GitHubTransport transport;
  final DateTime Function() now;
  DateTime? _retryAt;
  void _checkBackoff() {
    if (_retryAt != null && now().isBefore(_retryAt!)) {
      throw RepositoryFailure(
        RepositoryFailureCode.rateLimited,
        retryAt: _retryAt,
      );
    }
  }

  void _checkReply(GitHubReply reply, {Set<int> accepted = const {200}}) {
    final limited =
        reply.status == 429 ||
        (reply.status == 403 &&
            (reply.headers['x-ratelimit-remaining'] == '0' ||
                reply.headers.containsKey('retry-after') ||
                (reply.body['message'] is String &&
                    (reply.body['message'] as String).toLowerCase().contains(
                      'rate limit',
                    ))));
    if (limited) {
      final seconds = int.tryParse(reply.headers['retry-after'] ?? '');
      final reset = int.tryParse(reply.headers['x-ratelimit-reset'] ?? '');
      final retry = seconds != null && seconds >= 0
          ? now().add(Duration(seconds: seconds))
          : reset != null
          ? DateTime.fromMillisecondsSinceEpoch(reset * 1000, isUtc: true)
          : now().add(const Duration(minutes: 1));
      _retryAt = retry.isAfter(now())
          ? retry
          : now().add(const Duration(minutes: 1));
      throw RepositoryFailure(
        RepositoryFailureCode.rateLimited,
        retryAt: _retryAt,
      );
    }
    if (accepted.contains(reply.status)) return;
    if (reply.status == 401)
      throw const RepositoryFailure(
        RepositoryFailureCode.authorizationRequired,
      );
    if (reply.status == 403)
      throw const RepositoryFailure(RepositoryFailureCode.permission);
    if (reply.status == 404)
      throw const RepositoryFailure(RepositoryFailureCode.unavailable);
    if (reply.status == 409 || reply.status == 422)
      throw const RepositoryFailure(RepositoryFailureCode.conflict);
    if (reply.status >= 200 && reply.status < 300) {
      throw const RepositoryFailure(RepositoryFailureCode.invalidResponse);
    }
    throw const RepositoryFailure(RepositoryFailureCode.network);
  }

  Future<Map<String, Object?>> _oauth(
    String path,
    Map<String, String> form,
    RepositoryOperation op,
  ) async {
    op.check();
    _checkBackoff();
    final reply = await transport.send(
      Uri.https('github.com', path),
      op,
      form: {'client_id': GitHubRegistration.clientId, ...form},
    );
    op.check();
    _checkReply(reply);
    return reply.body;
  }

  Future<GitHubDeviceCode> startDevice(RepositoryOperation op) async {
    // Count the request latency conservatively; receiving or polling a code
    // later must never extend the server's stated lifetime.
    final elapsed = Stopwatch()..start();
    final body = await _oauth('/login/device/code', {
      'scope': 'offline_access',
    }, op);
    if (body.containsKey('error')) _oauthFailure(body['error']);
    if (body['verification_uri'] != GitHubRegistration.devicePage) {
      throw const RepositoryFailure(RepositoryFailureCode.invalidResponse);
    }
    final userCode = githubString(body['user_code'], maxLength: 32);
    if (!RegExp(r'^[A-Z0-9]{4}-[A-Z0-9]{4}$').hasMatch(userCode)) {
      throw const RepositoryFailure(RepositoryFailureCode.invalidResponse);
    }
    final code = GitHubDeviceCode._(
      githubString(body['device_code']),
      userCode,
      githubInt(body['expires_in'], maximum: 3600),
      githubInt(body['interval'] ?? 5, maximum: 3600),
      elapsed,
    );
    if (code.remaining == Duration.zero) {
      throw const RepositoryFailure(RepositoryFailureCode.expired);
    }
    return code;
  }

  Future<GitHubTokens> pollDevice(
    GitHubDeviceCode code,
    RepositoryOperation op, {
    Future<void> Function(Duration)? wait,
  }) async {
    var interval = code.interval;
    while (true) {
      op.check();
      final remaining = code.remaining.inMilliseconds;
      if (remaining <= 0)
        throw const RepositoryFailure(RepositoryFailureCode.expired);
      await (wait ?? op.wait)(
        Duration(milliseconds: math.min(interval * 1000, remaining)),
      );
      op.check();
      if (code.remaining == Duration.zero) {
        throw const RepositoryFailure(RepositoryFailureCode.expired);
      }
      final issuedAt = now().toUtc();
      final body = await _oauth('/login/oauth/access_token', {
        'device_code': code.deviceCode,
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
      }, op);
      if (code.remaining == Duration.zero) {
        throw const RepositoryFailure(RepositoryFailureCode.expired);
      }
      if (body['error'] == 'authorization_pending') continue;
      if (body['error'] == 'slow_down') {
        interval = math.max(
          interval + 5,
          body['interval'] == null
              ? 0
              : githubInt(body['interval'], maximum: 3600),
        );
        continue;
      }
      if (body.containsKey('error')) _oauthFailure(body['error']);
      return GitHubTokens.fromResponse(body, issuedAt);
    }
  }

  Future<GitHubTokens> refresh(
    GitHubTokens tokens,
    RepositoryOperation op,
  ) async {
    final issuedAt = now().toUtc();
    if (!issuedAt.isBefore(tokens.refreshExpiresAt)) {
      throw const RepositoryFailure(
        RepositoryFailureCode.authorizationRequired,
      );
    }
    final body = await _oauth('/login/oauth/access_token', {
      'grant_type': 'refresh_token',
      'refresh_token': tokens.refreshToken,
    }, op);
    if (body.containsKey('error')) _oauthFailure(body['error']);
    return GitHubTokens.fromResponse(body, issuedAt);
  }

  Never _oauthFailure(Object? error) {
    throw RepositoryFailure(switch (error) {
      'access_denied' => RepositoryFailureCode.denied,
      'expired_token' || 'token_expired' => RepositoryFailureCode.expired,
      'bad_verification_code' ||
      'incorrect_device_code' => RepositoryFailureCode.invalidDeviceCode,
      'unverified_user_email' => RepositoryFailureCode.unverifiedEmail,
      'incorrect_client_credentials' ||
      'device_flow_disabled' ||
      'unsupported_grant_type' => RepositoryFailureCode.configuration,
      'bad_refresh_token' ||
      'invalid_grant' => RepositoryFailureCode.authorizationRequired,
      _ => RepositoryFailureCode.invalidResponse,
    });
  }

  Future<GitHubReply> get(
    List<String> path,
    String token,
    RepositoryOperation op, {
    Map<String, String>? query,
  }) async {
    op.check();
    _checkBackoff();
    final uri = Uri(
      scheme: 'https',
      host: 'api.github.com',
      pathSegments: path,
      queryParameters: query,
    );
    final reply = await transport.send(uri, op, token: token);
    op.check();
    _checkReply(reply);
    return reply;
  }

  /// Fixed-origin Git Database/Contents requests. Callers supply only path
  /// components; redirects and credential-bearing URLs remain forbidden.
  Future<GitHubReply> request(
    List<String> path,
    String token,
    RepositoryOperation op, {
    String method = 'GET',
    Map<String, Object?>? body,
    Set<int> accepted = const {200},
    bool blob = false,
  }) async {
    op.check();
    _checkBackoff();
    final reply = await transport.send(
      Uri(scheme: 'https', host: 'api.github.com', pathSegments: path),
      op,
      token: token,
      method: method,
      json: body,
      maxResponseBytes: blob ? 8 * 1024 * 1024 : 2 * 1024 * 1024,
      timeout: blob ? const Duration(minutes: 5) : const Duration(seconds: 45),
    );
    op.check();
    _checkReply(reply, accepted: accepted);
    return reply;
  }

  Future<List<Map<String, Object?>>> pages(
    List<String> path,
    String key,
    String token,
    RepositoryOperation op,
  ) async {
    final items = <Map<String, Object?>>[];
    for (var page = 1; ; page++) {
      final reply = await get(
        path,
        token,
        op,
        query: {'per_page': '100', 'page': '$page'},
      );
      final values = reply.body[key];
      if (values is! List || values.length > 100) {
        throw const RepositoryFailure(RepositoryFailureCode.invalidResponse);
      }
      items.addAll(values.map(githubMap));
      final hasNext = RegExp(r'rel="next"')
          .hasMatch(reply.headers['link'] ?? '');
      if (!hasNext && values.length < 100) break;
      // Bound network work per interaction, not the user's media capacity.
      if (page >= 100)
        throw const RepositoryFailure(RepositoryFailureCode.invalidResponse);
    }
    return items;
  }
}
