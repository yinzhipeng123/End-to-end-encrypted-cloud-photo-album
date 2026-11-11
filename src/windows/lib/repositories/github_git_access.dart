part of 'github_connection.dart';

/// A short-lived, selected-repository capability. Never stores plaintext media,
/// follows response URLs, force-updates refs, or writes outside the app prefix.
final class GitHubGitAccess {
  GitHubGitAccess._(this._api, this.target, this._token, this.operation);
  final GitHubApi _api;
  final GitHubRepository target;
  final String _token;
  final RepositoryOperation operation;
  static const dataBranch = 'epa-data-v1';
  static const prefix = '.encrypted-photo-app/v1/';
  static const markerPath = '.encrypted-photo-app/initialized-v1.txt';
  static const marker = 'EncryptedPhotoApp repository initialization v1\n';
  List<String> get _base => ['repos', target.owner, target.name];
  static String sha(Object? value) {
    if (value is! String || !RegExp(r'^[a-f0-9]{40}$').hasMatch(value)) {
      throw const RepositoryFailure(RepositoryFailureCode.invalidResponse);
    }
    return value;
  }

  static void _path(String path) {
    if (!path.startsWith(prefix) ||
        path.length > 256 ||
        path.split('/').any((s) => s.isEmpty || s == '.' || s == '..') ||
        !RegExp(r'^[a-zA-Z0-9._/-]+$').hasMatch(path)) {
      throw const RepositoryFailure(RepositoryFailureCode.configuration);
    }
  }

  Future<Map<String, Object?>> verifyTarget() async {
    final reply = await _api.get(_base, _token, operation);
    final fresh = GitHubRepository.parse(
      reply.body,
      target.installationId,
      installationWritable: true,
    );
    if (fresh.id != target.id ||
        !fresh.eligible ||
        fresh.fullName != target.fullName) {
      throw const RepositoryFailure(RepositoryFailureCode.invalidTarget);
    }
    return reply.body;
  }

  Future<GitHubReply> _request(
    List<String> suffix, {
    String method = 'GET',
    Map<String, Object?>? body,
    Set<int> accepted = const {200},
    bool blob = false,
  }) async {
    operation.check();
    if (method != 'GET') await verifyTarget();
    return _api.request(
      [..._base, ...suffix],
      _token,
      operation,
      method: method,
      body: body,
      accepted: accepted,
      blob: blob,
    );
  }

  Future<String?> head([String branch = dataBranch]) async {
    if (!RegExp(r'^[a-zA-Z0-9._/-]+$').hasMatch(branch) ||
        branch.contains('..')) {
      throw const RepositoryFailure(RepositoryFailureCode.invalidResponse);
    }
    final reply = await _request(
      ['git', 'ref', 'heads', ...branch.split('/')],
      accepted: {200, 404, 409},
    );
    if (reply.status != 200) return null;
    if (reply.body['ref'] != 'refs/heads/$branch')
      throw const RepositoryFailure(RepositoryFailureCode.invalidResponse);
    final object = githubMap(reply.body['object']);
    if (object['type'] != 'commit')
      throw const RepositoryFailure(RepositoryFailureCode.invalidResponse);
    return sha(object['sha']);
  }

  Future<Map<String, Object?>> commit(String id) async {
    final reply = await _request(['git', 'commits', sha(id)]);
    if (reply.body['sha'] != id)
      throw const RepositoryFailure(RepositoryFailureCode.invalidResponse);
    sha(githubMap(reply.body['tree'])['sha']);
    return reply.body;
  }

  Future<List<Map<String, Object?>>> tree(String id) async {
    final reply = await _request(['git', 'trees', sha(id)]);
    final entries = reply.body['tree'];
    if (reply.body['sha'] != id ||
        reply.body['truncated'] != false ||
        entries is! List) {
      throw const RepositoryFailure(RepositoryFailureCode.invalidResponse);
    }
    return entries.map(githubMap).toList();
  }

  Future<Uint8List> blob(String id, {required int maximum}) async {
    if (maximum < 1 || maximum > 50000000)
      throw const RepositoryFailure(RepositoryFailureCode.configuration);
    final reply = await _request(['git', 'blobs', sha(id)], blob: true);
    final size = githubInt(reply.body['size'], maximum: maximum);
    final content = reply.body['content'];
    if (reply.body['sha'] != id ||
        reply.body['encoding'] != 'base64' ||
        content is! String ||
        content.length > 8 * 1024 * 1024)
      throw const RepositoryFailure(RepositoryFailureCode.invalidResponse);
    try {
      // GitHub wraps Base64 lines. Reject arbitrary characters and mismatched
      // lengths before decoding; the caller authenticates the resulting bytes.
      final compact = content.replaceAll('\n', '').replaceAll('\r', '');
      if (!RegExp(r'^[A-Za-z0-9+/]*={0,2}$').hasMatch(compact) ||
          compact.length != 4 * ((size + 2) ~/ 3)) {
        throw const RepositoryFailure(RepositoryFailureCode.invalidResponse);
      }
      final bytes = base64Decode(compact);
      if (bytes.length != size)
        throw const RepositoryFailure(RepositoryFailureCode.invalidResponse);
      return bytes;
    } on FormatException {
      throw const RepositoryFailure(RepositoryFailureCode.invalidResponse);
    }
  }

  Future<String?> fileSha(String commitId, String path) async {
    if (path != markerPath) _path(path);
    var treeId = sha(githubMap((await commit(commitId))['tree'])['sha']);
    final parts = path.split('/');
    for (var i = 0; i < parts.length; i++) {
      final matches = (await tree(treeId))
          .where((e) => e['path'] == parts[i])
          .toList();
      if (matches.isEmpty) return null;
      if (matches.length != 1)
        throw const RepositoryFailure(RepositoryFailureCode.invalidResponse);
      final item = matches.single;
      final last = i == parts.length - 1;
      if (item['type'] != (last ? 'blob' : 'tree') ||
          item['mode'] != (last ? '100644' : '040000')) {
        throw const RepositoryFailure(RepositoryFailureCode.invalidResponse);
      }
      treeId = sha(item['sha']);
    }
    return treeId;
  }

  Future<bool> containsCommit(String known, String current) async {
    if (sha(known) == sha(current)) return true;
    final result = await _api.get(
      [..._base, 'compare', '$known...$current'],
      _token,
      operation,
      query: {'per_page': '1', 'page': '1'},
    );
    return result.body['status'] == 'ahead' ||
        result.body['status'] == 'identical';
  }

  Future<bool> hasDataDirectory(String commitId) async {
    var treeId = sha(githubMap((await commit(commitId))['tree'])['sha']);
    for (final segment in ['.encrypted-photo-app', 'v1']) {
      final matches = (await tree(treeId))
          .where((e) => e['path'] == segment)
          .toList();
      if (matches.isEmpty) return false;
      if (matches.length != 1 || matches.single['type'] != 'tree') {
        throw const RepositoryFailure(RepositoryFailureCode.invalidResponse);
      }
      treeId = sha(matches.single['sha']);
    }
    return true;
  }

  Future<void> validateNamespace(String commitId) async {
    final root = await tree(
      sha(githubMap((await commit(commitId))['tree'])['sha']),
    );
    final entries = root
        .where((e) => e['path'] == '.encrypted-photo-app')
        .toList();
    if (entries.isEmpty) return;
    if (entries.length != 1 || entries.single['type'] != 'tree')
      throw const RepositoryFailure(RepositoryFailureCode.invalidResponse);
    final application = await tree(sha(entries.single['sha']));
    for (final item in application) {
      if (item['path'] == 'initialized-v1.txt' && item['type'] == 'blob') {
        final bytes = await blob(sha(item['sha']), maximum: marker.length);
        if (utf8.decode(bytes, allowMalformed: true) != marker)
          throw const RepositoryFailure(RepositoryFailureCode.invalidResponse);
      } else if (item['path'] == 'v1' && item['type'] == 'tree') {
        for (final child in await tree(sha(item['sha']))) {
          if (!(child['path'] == 'objects' && child['type'] == 'tree') &&
              !({'head.bin', 'recovery.bin'}.contains(child['path']) &&
                  child['type'] == 'blob'))
            throw const RepositoryFailure(
              RepositoryFailureCode.invalidResponse,
            );
        }
      } else {
        throw const RepositoryFailure(RepositoryFailureCode.invalidResponse);
      }
    }
  }

  Future<String> createBlob(Uint8List ciphertext) async {
    // WSR-1 metadata and blocks fit this bound. No multi-object buffering.
    if (ciphertext.isEmpty || ciphertext.length > 4194352)
      throw const RepositoryFailure(RepositoryFailureCode.configuration);
    final reply = await _request(
      ['git', 'blobs'],
      method: 'POST',
      blob: true,
      body: {'content': base64Encode(ciphertext), 'encoding': 'base64'},
      accepted: {201},
    );
    return sha(reply.body['sha']);
  }

  Future<String> createTree(String baseTree, Map<String, String?> files) async {
    if (files.isEmpty || files.length > 256)
      throw const RepositoryFailure(RepositoryFailureCode.configuration);
    final entries = <Map<String, Object?>>[];
    for (final file in files.entries) {
      _path(file.key);
      entries.add({
        'path': file.key,
        'mode': '100644',
        'type': 'blob',
        'sha': file.value == null ? null : sha(file.value),
      });
    }
    final reply = await _request(
      ['git', 'trees'],
      method: 'POST',
      accepted: {201},
      body: {'base_tree': sha(baseTree), 'tree': entries},
    );
    if (reply.body['truncated'] == true)
      throw const RepositoryFailure(RepositoryFailureCode.invalidResponse);
    return sha(reply.body['sha']);
  }

  Future<String> createCommit(String treeId, String parent) async {
    final identity = {
      'name': 'EncryptedPhotoApp',
      'email': 'encrypted-photo-app@users.noreply.github.com',
    };
    final reply = await _request(
      ['git', 'commits'],
      method: 'POST',
      accepted: {201},
      body: {
        'message': 'EncryptedPhotoApp data update v1',
        'tree': sha(treeId),
        'parents': [sha(parent)],
        'author': identity,
        'committer': identity,
      },
    );
    return sha(reply.body['sha']);
  }

  Future<void> publish(String id) async {
    final reply = await _request(
      ['git', 'refs', 'heads', dataBranch],
      method: 'PATCH',
      body: {'sha': sha(id), 'force': false},
    );
    if (reply.body['ref'] != 'refs/heads/$dataBranch' ||
        githubMap(reply.body['object'])['sha'] != id) {
      throw const RepositoryFailure(RepositoryFailureCode.invalidResponse);
    }
  }

  Future<void> createDataBranch(String id) async {
    final reply = await _request(
      ['git', 'refs'],
      method: 'POST',
      accepted: {201},
      body: {'ref': 'refs/heads/$dataBranch', 'sha': sha(id)},
    );
    if (reply.body['ref'] != 'refs/heads/$dataBranch' ||
        githubMap(reply.body['object'])['sha'] != id) {
      throw const RepositoryFailure(RepositoryFailureCode.invalidResponse);
    }
  }

  /// The sole approved default-branch exception, called only from explicit init.
  Future<String> createInitializationMarker() async {
    final reply = await _request(
      ['contents', ...markerPath.split('/')],
      method: 'PUT',
      accepted: {201},
      body: {
        'message': 'Initialize EncryptedPhotoApp data branch',
        'content': base64Encode(utf8.encode(marker)),
      },
    );
    return sha(githubMap(reply.body['commit'])['sha']);
  }

  @override
  String toString() => 'GitHubGitAccess(repositoryId=${target.id})';
}
