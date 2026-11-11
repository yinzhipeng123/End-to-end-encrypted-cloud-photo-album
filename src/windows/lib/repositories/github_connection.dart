import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:encrypted_photo_shared/security/protected_record_store.dart';
import 'package:encrypted_photo_shared/security/vault_crypto.dart';
import 'package:encrypted_photo_app/storage/library_catalog.dart';
import 'package:encrypted_photo_app/repositories/github_api.dart';

part 'github_git_access.dart';

final class GitHubUser {
  GitHubUser(this.id, this.login);
  final int id;
  final String login;
  static GitHubUser parse(Map<String, Object?> json) => GitHubUser(
    githubInt(json['id']),
    githubString(json['login'], maxLength: 255),
  );
  Map<String, Object?> toRecord() => {'id': id, 'login': login};
}

final class GitHubRepository {
  GitHubRepository({
    required this.id,
    required this.installationId,
    required this.owner,
    required this.name,
    required this.eligible,
    required this.reason,
  });
  final int id;
  final int installationId;
  final String owner;
  final String name;
  final bool eligible;
  final String? reason;
  String get fullName => '$owner/$name';
  static GitHubRepository parse(
    Map<String, Object?> json,
    int installationId, {
    required bool installationWritable,
  }) {
    final permissions = json['permissions'];
    final writable = permissions is Map && permissions['push'] == true;
    final reason = json['private'] != true
        ? '必须选择私有仓库'
        : json['archived'] != false
        ? '仓库已归档或状态未知'
        : json['disabled'] != false
        ? '仓库已停用或状态未知'
        : !installationWritable
        ? '应用安装范围或 Contents 写权限不符合要求'
        : !writable
        ? '平台未确认当前用户具有写权限'
        : null;
    return GitHubRepository(
      id: githubInt(json['id']),
      installationId: installationId,
      owner: githubString(githubMap(json['owner'])['login'], maxLength: 255),
      name: githubString(json['name'], maxLength: 255),
      eligible: reason == null,
      reason: reason,
    );
  }

  Map<String, Object?> toRecord() => {
    'id': id,
    'installationId': installationId,
    'owner': owner,
    'name': name,
  };
  static GitHubRepository fromRecord(Map<String, Object?> json) =>
      GitHubRepository(
        id: githubInt(json['id']),
        installationId: githubInt(json['installationId']),
        owner: githubString(json['owner'], maxLength: 255),
        name: githubString(json['name'], maxLength: 255),
        eligible: false,
        reason: '待平台核验',
      );
}

/// A background-vault connection. Interface requests are independently revoked.
/// The SQLCipher record is the authority for the currently referenced DPAPI file.
final class GitHubConnection extends ChangeNotifier {
  GitHubConnection({
    required LibraryCatalog Function() catalog,
    required ProtectedRecordStore protectedStore,
    required Uint8List localBinding,
    GitHubApi? api,
    this.acquireView,
  }) : _catalog = catalog,
       _store = protectedStore,
       _localBinding = Uint8List.fromList(localBinding),
       api = api ?? GitHubApi() {
    try {
      final record = _record;
      if (record != null && record['state'] != 'disconnected') {
        _validateRecord(record);
        user = GitHubUser.parse(githubMap(record['user']));
        if (record['repository'] != null)
          selected = GitHubRepository.fromRecord(
            githubMap(record['repository']),
          );
        message = record['state'] == 'active'
            ? '已保存 GitHub 连接，请检查连接以核验当前权限。'
            : '上次授权材料更新未完整完成，请重新授权。';
      }
    } catch (_) {
      message = '无法读取已保存的连接，请重新授权；照片库未修改。';
    }
  }
  final LibraryCatalog Function() _catalog;
  final ProtectedRecordStore _store;
  final Uint8List _localBinding;
  final GitHubApi api;
  final void Function() Function()? acquireView;
  RepositoryOperation? _operation;
  RepositoryOperation? _interfaceOperation;
  bool _closed = false;
  bool verified = false;
  GitHubUser? user;
  GitHubRepository? selected;
  List<GitHubRepository> repositories = const [];
  String? userCode;
  DateTime? codeExpiresAt;
  String? message;
  int installationCount = 0;
  bool get busy => _operation != null;
  bool get waitingForAuthorization => userCode != null;
  String get networkDescription => api.transport is GitHubHttpTransport
      ? (api.transport as GitHubHttpTransport).networkDescription
      : '网络状态由当前传输服务提供';
  Map<String, Object?>? get _record =>
      _catalog().record('preferences', 'github-connection');

  void _validateRecord(Map<String, Object?> record) {
    if (record['version'] != 1 ||
        record['clientId'] != GitHubRegistration.clientId ||
        record['appId'] != GitHubRegistration.appId ||
        !{'active', 'refreshing', 'reauthorize'}.contains(record['state'])) {
      throw const RepositoryFailure(
        RepositoryFailureCode.authorizationRequired,
      );
    }
    githubInt(githubMap(record['user'])['id']);
    final install = record['installationId'];
    if (install is! int || install < 0) {
      throw const RepositoryFailure(
        RepositoryFailureCode.authorizationRequired,
      );
    }
    if (!RegExp(r'^github-token-[a-f0-9]{32}$')
        .hasMatch(githubString(record['credential']))) {
      throw const RepositoryFailure(
        RepositoryFailureCode.authorizationRequired,
      );
    }
    final repository = record['repository'];
    if ((repository == null && install != 0) ||
        (repository != null &&
            githubMap(repository)['installationId'] != install)) {
      throw const RepositoryFailure(
        RepositoryFailureCode.authorizationRequired,
      );
    }
  }

  Uint8List _binding(int account, int installation) => Uint8List.fromList([
    ..._localBinding,
    ...utf8.encode(
      jsonEncode([
        'EPA/github-credentials/v1',
        GitHubRegistration.clientId,
        GitHubRegistration.appId,
        account,
        installation,
      ]),
    ),
  ]);
  Future<GitHubTokens> _readTokens(
    Map<String, Object?> record,
    RepositoryOperation op,
  ) async {
    _validateRecord(record);
    if (record['state'] != 'active') {
      throw const RepositoryFailure(
        RepositoryFailureCode.authorizationRequired,
      );
    }
    final bytes = await _store.read(
      record['credential'] as String,
      _binding(
        githubMap(record['user'])['id'] as int,
        record['installationId'] as int,
      ),
    );
    try {
      op.check();
      if (bytes == null)
        throw const RepositoryFailure(
          RepositoryFailureCode.authorizationRequired,
        );
      return GitHubTokens.fromRecord(githubMap(jsonDecode(utf8.decode(bytes))));
    } catch (_) {
      op.check();
      throw const RepositoryFailure(
        RepositoryFailureCode.authorizationRequired,
      );
    } finally {
      bytes?.fillRange(0, bytes.length, 0);
    }
  }

  Future<void> _save(
    GitHubTokens tokens,
    GitHubUser account,
    GitHubRepository? repository,
    RepositoryOperation op,
  ) async {
    op.check();
    final previous = _record;
    final crypto = await VaultCrypto.load();
    op.check();
    final id =
        'github-token-${crypto.randomBytes(16).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
    final clear = Uint8List.fromList(
      utf8.encode(jsonEncode(tokens.toRecord())),
    );
    var committed = false;
    try {
      await _store.write(
        id,
        clear,
        _binding(account.id, repository?.installationId ?? 0),
      );
      op.check();
      _catalog().putRecord('preferences', 'github-connection', {
        'version': 1,
        'state': 'active',
        'clientId': GitHubRegistration.clientId,
        'appId': GitHubRegistration.appId,
        'user': account.toRecord(),
        'installationId': repository?.installationId ?? 0,
        'credential': id,
        'repository': repository?.toRecord(),
      });
      committed = true;
    } finally {
      clear.fillRange(0, clear.length, 0);
      // Immutable generations prevent a late cancelled write from replacing a
      // newer unlocked session. Only the referenced generation is ever loaded.
      if (!committed) {
        try {
          await _store.remove(id);
        } catch (_) {}
      }
    }
    final old = previous?['credential'];
    if (old is String &&
        RegExp(r'^github-token-[a-f0-9]{32}$').hasMatch(old) &&
        old != id) {
      try {
        await _store.remove(old);
      } catch (_) {
        /* Sealed, unreferenced residue. */
      }
    }
    op.check();
  }

  void _invalidate() {
    final record = _record;
    if (record != null && record['state'] != 'disconnected') {
      _catalog().putRecord('preferences', 'github-connection', {
        ...record,
        'state': 'reauthorize',
      });
    }
    verified = false;
  }

  Future<GitHubTokens> _usableTokens(RepositoryOperation op) async {
    final record = _record;
    if (record == null)
      throw const RepositoryFailure(
        RepositoryFailureCode.authorizationRequired,
      );
    var tokens = await _readTokens(record, op);
    if (api.now().add(const Duration(minutes: 1)).isBefore(tokens.expiresAt))
      return tokens;
    op.check();
    // Durable intent precedes the request: a crash or lost refresh response may
    // have invalidated the old pair. Such a record is never reused on restart.
    _catalog().putRecord('preferences', 'github-connection', {
      ...record,
      'state': 'refreshing',
    });
    try {
      tokens = await api.refresh(tokens, op);
      op.check();
      final account = GitHubUser.parse(githubMap(record['user']));
      final target = record['repository'] == null
          ? null
          : GitHubRepository.fromRecord(githubMap(record['repository']));
      await _save(tokens, account, target, op);
      return tokens;
    } catch (_) {
      op.check();
      _invalidate();
      throw const RepositoryFailure(
        RepositoryFailureCode.authorizationRequired,
      );
    }
  }

  Future<
    ({GitHubUser user, List<GitHubRepository> repositories, int installations})
  >
  _snapshot(
    GitHubTokens tokens,
    RepositoryOperation op, {
    int? expectedUser,
  }) async {
    final account = GitHubUser.parse(
      (await api.get(['user'], tokens.accessToken, op)).body,
    );
    if (expectedUser != null && account.id != expectedUser) {
      throw const RepositoryFailure(
        RepositoryFailureCode.authorizationRequired,
      );
    }
    final installations = await api.pages(
      ['user', 'installations'],
      'installations',
      tokens.accessToken,
      op,
    );
    final repos = <GitHubRepository>[];
    final seen = <int>{};
    var count = 0;
    for (final install in installations) {
      op.check();
      if (install['app_id'] != GitHubRegistration.appId) continue;
      final id = githubInt(install['id']);
      if (!seen.add(id))
        throw const RepositoryFailure(RepositoryFailureCode.invalidResponse);
      // Private app: installation must belong to the authorized personal owner.
      if (githubMap(install['account'])['id'] != account.id) continue;
      count++;
      final permissions = install['permissions'];
      final writable =
          install['suspended_at'] == null &&
          install['repository_selection'] == 'selected' &&
          permissions is Map &&
          permissions['contents'] == 'write' &&
          permissions['metadata'] == 'read';
      final entries = await api.pages(
        ['user', 'installations', '$id', 'repositories'],
        'repositories',
        tokens.accessToken,
        op,
      );
      for (final entry in entries) {
        repos.add(
          GitHubRepository.parse(entry, id, installationWritable: writable),
        );
      }
    }
    return (user: account, repositories: repos, installations: count);
  }

  void _showSnapshot(
    ({GitHubUser user, List<GitHubRepository> repositories, int installations})
    snapshot,
  ) {
    user = snapshot.user;
    repositories = List.unmodifiable(snapshot.repositories);
    installationCount = snapshot.installations;
    verified = true;
  }

  Future<void> authorize() => _run((op) async {
    verified = false;
    message = '正在向 GitHub 请求设备授权…';
    _notify();
    final code = await api.startDevice(op);
    op.check();
    userCode = code.userCode;
    codeExpiresAt = api.now().add(code.remaining);
    message = '请在 GitHub 官方页面输入本次显示的代码。只使用你从本 App 发起的授权。';
    _notify();
    final tokens = await api.pollDevice(code, op);
    op.check();
    userCode = null;
    codeExpiresAt = null;
    message = '授权已返回，正在核验账号和安装范围…';
    _notify();
    final snapshot = await _snapshot(tokens, op);
    // New explicit authorization always requires an explicit target selection.
    await _save(tokens, snapshot.user, null, op);
    op.check();
    selected = null;
    _showSnapshot(snapshot);
    message = snapshot.installations == 0
        ? 'GitHub 账号已授权，但未查到本相册应用在当前账号下的安装。请核对安装后刷新仓库。'
        : 'GitHub 账号已授权，请选择照片备份用的私有仓库。';
  });
  Future<void> refreshRepositories() => _run((op) async {
    verified = false;
    message = '正在核验 GitHub 连接和仓库权限…';
    _notify();
    final tokens = await _usableTokens(op);
    final record = _record!;
    final snapshot = await _snapshot(
      tokens,
      op,
      expectedUser: githubMap(record['user'])['id'] as int,
    );
    op.check();
    _showSnapshot(snapshot);
    if (selected != null) {
      final matching = snapshot.repositories
          .where(
            (r) =>
                r.id == selected!.id &&
                r.installationId == selected!.installationId,
          )
          .toList();
      if (matching.length != 1 || !matching.single.eligible) {
        verified = false;
        message = '已选仓库不可用，或私有属性／权限已变化。未执行任何同步。';
        return;
      }
      final target = await _checkTarget(matching.single, tokens, op);
      await _save(tokens, snapshot.user, target, op);
      selected = target;
    }
    message = snapshot.installations == 0
        ? '账号授权有效，但未查到本相册应用在当前账号下的安装。请核对安装后刷新仓库。'
        : selected == null
        ? '账号权限已核验，请选择私有照片仓库。'
        : '账号和所选私有仓库已核验。';
  });
  Future<GitHubRepository> _checkTarget(
    GitHubRepository target,
    GitHubTokens tokens,
    RepositoryOperation op,
  ) async {
    if (!target.eligible)
      throw const RepositoryFailure(RepositoryFailureCode.invalidTarget);
    final data = (await api.get(
      ['repos', target.owner, target.name],
      tokens.accessToken,
      op,
    )).body;
    final fresh = GitHubRepository.parse(
      data,
      target.installationId,
      installationWritable: true,
    );
    if (fresh.id != target.id || !fresh.eligible) {
      throw const RepositoryFailure(RepositoryFailureCode.invalidTarget);
    }
    return fresh;
  }

  Future<void> selectRepository(GitHubRepository choice) => _run((op) async {
    verified = false;
    final tokens = await _usableTokens(op);
    final record = _record!;
    final snapshot = await _snapshot(
      tokens,
      op,
      expectedUser: githubMap(record['user'])['id'] as int,
    );
    final matching = snapshot.repositories
        .where(
          (r) => r.id == choice.id && r.installationId == choice.installationId,
        )
        .toList();
    if (matching.length != 1)
      throw const RepositoryFailure(RepositoryFailureCode.invalidTarget);
    final fresh = await _checkTarget(matching.single, tokens, op);
    await _save(tokens, snapshot.user, fresh, op);
    op.check();
    selected = fresh;
    _showSnapshot(snapshot);
    message = '私有仓库选择已加密保存。同步进度和结果见下方状态。';
  });

  /// A revocable capability scoped to the freshly verified selected target.
  /// Tokens never leave this library; the capability expires at callback exit.
  Future<T> withRepository<T>(
    Future<T> Function(GitHubGitAccess access) action, {
    void Function(RepositoryOperation operation)? onOperation,
  }) async {
    if (_closed || busy || selected == null) {
      throw const RepositoryFailure(RepositoryFailureCode.invalidTarget);
    }
    final op = RepositoryOperation(() {
      if (_closed)
        throw const RepositoryFailure(RepositoryFailureCode.cancelled);
      _catalog();
    });
    _operation = op;
    _notify();
    try {
      onOperation?.call(op);
      final choice = selected!;
      final tokens = await _usableTokens(op);
      final snapshot = await _snapshot(
        tokens,
        op,
        expectedUser: githubMap(_record!['user'])['id'] as int,
      );
      final matches = snapshot.repositories
          .where(
            (r) =>
                r.id == choice.id && r.installationId == choice.installationId,
          )
          .toList();
      if (matches.length != 1)
        throw const RepositoryFailure(RepositoryFailureCode.invalidTarget);
      final fresh = await _checkTarget(matches.single, tokens, op);
      selected = fresh;
      _showSnapshot(snapshot);
      final result = await action(
        GitHubGitAccess._(api, fresh, tokens.accessToken, op),
      );
      op.check();
      return result;
    } catch (error) {
      if (!_closed) {
        verified = false;
        message = describe(error);
        if (error is RepositoryFailure &&
            error.code == RepositoryFailureCode.authorizationRequired)
          _invalidate();
      }
      rethrow;
    } finally {
      op.cancel();
      _operation = null;
      _notify();
    }
  }

  Future<void> disconnect() => _run((op) async {
    final record = _record;
    final credential = record?['credential'];
    if (credential is String &&
        RegExp(r'^github-token-[a-f0-9]{32}$').hasMatch(credential)) {
      // Commit invalidation first, so an interrupted deletion is never reused.
      _invalidate();
      await _store.remove(credential);
    }
    op.check();
    _catalog().putRecord('preferences', 'github-connection', {
      'version': 1,
      'state': 'disconnected',
    });
    user = null;
    selected = null;
    repositories = const [];
    verified = false;
    message = '已移除本机连接。GitHub 端的授权尚未撤销，可在 GitHub 的 Applications → Authorized GitHub Apps 中撤销。';
  });
  void cancelAuthorization() {
    _operation?.cancel();
    userCode = null;
    codeExpiresAt = null;
    verified = false;
    message = '本次操作已停止；已保存的连接状态可在下次检查连接时核验。';
    _notify();
  }

  void lockInterface() {
    _interfaceOperation?.cancel();
    userCode = null;
    codeExpiresAt = null;
  }

  Future<void> _run(Future<void> Function(RepositoryOperation) action) async {
    if (_closed || busy) return;
    void Function()? view;
    final op = RepositoryOperation(() {
      if (_closed)
        throw const RepositoryFailure(RepositoryFailureCode.cancelled);
      _catalog();
      view?.call();
    });
    _operation = op;
    _interfaceOperation = op;
    message = null;
    _notify();
    try {
      view = acquireView?.call();
      op.check();
      await action(op);
      op.check();
    } catch (error) {
      if (!_closed) {
        verified = false;
        if (error is RepositoryFailure &&
            error.code == RepositoryFailureCode.authorizationRequired) {
          try {
            _invalidate();
          } catch (_) {}
        }
        message = describe(error);
      }
    } finally {
      userCode = null;
      codeExpiresAt = null;
      _operation = null;
      _interfaceOperation = null;
      _notify();
    }
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    _operation?.cancel();
    userCode = null;
    codeExpiresAt = null;
    user = null;
    selected = null;
    repositories = const [];
    verified = false;
    _localBinding.fillRange(0, _localBinding.length, 0);
    super.dispose();
  }

  static String describe(Object error) {
    if (error is! RepositoryFailure) return '无法安全读取或保存连接，本次操作未完成。请重新授权或重试。';
    return switch (error.code) {
      RepositoryFailureCode.cancelled => '本次操作已停止；已保存的连接状态可在下次检查连接时核验。',
      RepositoryFailureCode.denied => '你在 GitHub 拒绝了本次授权。',
      RepositoryFailureCode.expired => '设备授权码已过期，请重新发起授权。',
      RepositoryFailureCode.invalidDeviceCode =>
        'GitHub 未接受本次设备授权码，可能已失效。请重新发起授权并使用新代码。',
      RepositoryFailureCode.unverifiedEmail =>
        '请先在 GitHub 账号设置中验证主邮箱，再返回 App 重新发起授权。',
      RepositoryFailureCode.configuration =>
        'GitHub 应用配置不正确，请检查 Client ID 和“启用设备流”。',
      RepositoryFailureCode.proxyConfiguration =>
        '无法读取代理设置或代理地址格式无效。请检查 Windows 系统代理或启动环境变量；未改用直连。',
      RepositoryFailureCode.proxyUnsupported =>
        '当前代理配置暂不支持。请使用 HTTP 代理；仅 SOCKS、PAC、WPAD、HTTPS 代理服务器及带凭据的地址尚未支持，未改用直连。',
      RepositoryFailureCode.proxyConnection =>
        '通过代理连接 GitHub 失败或超时。请检查代理是否运行、代理规则及网络；未改用直连。',
      RepositoryFailureCode.tls =>
        '无法完成 GitHub TLS 安全连接，请检查代理和系统时间／证书。未关闭证书验证。',
      RepositoryFailureCode.authorizationRequired => '授权已失效或令牌更新未完整完成，请重新授权。',
      RepositoryFailureCode.permission => 'GitHub 拒绝访问，请检查安装范围和权限。',
      RepositoryFailureCode.rateLimited =>
        error.retryAt == null
            ? 'GitHub 已限流，请稍后重试。'
            : 'GitHub 已限流，请在 ${error.retryAt!.toLocal()} 后重试。',
      RepositoryFailureCode.unavailable => 'GitHub 目标不可访问，可能已移除、改名或权限发生变化。',
      RepositoryFailureCode.invalidTarget => '所选仓库未通过身份、私有属性和写权限核验，未保存新目标。',
      RepositoryFailureCode.invalidResponse => 'GitHub 返回了无法安全验证的响应，本次操作未完成。',
      RepositoryFailureCode.conflict => '仓库发生并发变化或拒绝本次发布，需要重新核对；没有强制覆盖。',
      RepositoryFailureCode.browser =>
        '无法打开浏览器，请手动访问 https://github.com/login/device。',
      _ => '网络连接失败或请求超时，请检查网络后重试。',
    };
  }
}
