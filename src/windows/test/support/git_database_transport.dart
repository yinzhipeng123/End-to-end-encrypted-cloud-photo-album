// HTTP substitute only. Production crypto, file I/O, SQLCipher and queues remain
// real in tests. This file is never imported by lib/ or a shipping entry point.
import 'dart:convert';
import 'dart:typed_data';

import 'package:encrypted_photo_app/repositories/github_api.dart';

import '../repositories/github_connection_test.dart' show FixtureGitHub;

final class GitDatabaseTransport extends FixtureGitHub {
  GitDatabaseTransport() {
    installed = true;
  }
  final blobs = <String, Uint8List>{};
  final trees = <String, Map<String, String>>{};
  final commits = <String, Map<String, Object?>>{};
  final refs = <String, String>{};
  final writes = <({String path, Map<String, Object?> body})>[];
  int _id = 10;
  bool loseNextPublishReply = false;
  Future<void> Function(Uri uri, String method)? beforeRequest;
  String identifier() => (++_id).toRadixString(16).padLeft(40, '0');
  String addBlob(Uint8List bytes) {
    final id = identifier();
    blobs[id] = Uint8List.fromList(bytes);
    return id;
  }

  String addTree(Map<String, String> paths) {
    final id = identifier();
    trees[id] = Map.from(paths);
    return id;
  }

  String addCommit(String tree, List<String> parents) {
    final id = identifier();
    commits[id] = {
      'sha': id,
      'tree': {'sha': tree},
      'parents': parents.map((p) => {'sha': p}).toList(),
    };
    return id;
  }

  bool contains(String ancestor, String head) =>
      ancestor == head ||
      (commits[head]!['parents'] as List).any(
        (p) => contains(ancestor, (p as Map)['sha'] as String),
      );
  @override
  Map<String, Object?> repository() => {
    ...super.repository(),
    'default_branch': 'main',
  };
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
    await beforeRequest?.call(uri, method ?? 'GET');
    final parts = uri.pathSegments;
    if (parts.length <= 3 || parts[0] != 'repos') {
      return super.send(
        uri,
        operation,
        token: token,
        form: form,
        method: method,
        json: json,
        maxResponseBytes: maxResponseBytes,
        timeout: timeout,
      );
    }
    if ((method ?? 'GET') != 'GET')
      writes.add((path: uri.path, body: Map.from(json!)));
    final path = parts.skip(3).toList();
    if (path.first == 'contents' && method == 'PUT') {
      final name = path.skip(1).join('/');
      final base = refs['main'];
      final paths = base == null
          ? <String, String>{}
          : Map<String, String>.from(
              trees[(commits[base]!['tree'] as Map)['sha']]!,
            );
      if (paths.containsKey(name)) return GitHubReply(422, {});
      paths[name] = addBlob(base64Decode(json!['content'] as String));
      final commit = addCommit(addTree(paths), base == null ? [] : [base]);
      refs['main'] = commit;
      return GitHubReply(201, {
        'commit': {'sha': commit},
      });
    }
    if (path.first == 'compare') {
      final values = path[1].split('...');
      return GitHubReply(200, {
        'status': values[0] == values[1]
            ? 'identical'
            : contains(values[0], values[1])
            ? 'ahead'
            : 'diverged',
      });
    }
    if (path[0] != 'git') throw StateError('Unexpected fixture path');
    final type = path[1];
    if (type == 'ref') {
      final branch = path.skip(3).join('/');
      return refs.containsKey(branch)
          ? GitHubReply(200, {
              'ref': 'refs/heads/$branch',
              'object': {'type': 'commit', 'sha': refs[branch]},
            })
          : GitHubReply(refs.isEmpty ? 409 : 404, {});
    }
    if (type == 'refs') {
      final branch = method == 'POST'
          ? (json!['ref'] as String).substring(11)
          : path.skip(3).join('/');
      final sha = json!['sha'] as String;
      if (method == 'POST') {
        if (refs.isEmpty || refs.containsKey(branch))
          return GitHubReply(422, {});
      } else {
        if (json['force'] != false) throw StateError('Force update forbidden');
        if (!contains(refs[branch]!, sha)) return GitHubReply(422, {});
      }
      refs[branch] = sha;
      if (method == 'PATCH' && loseNextPublishReply) {
        loseNextPublishReply = false;
        throw const RepositoryFailure(RepositoryFailureCode.network);
      }
      return GitHubReply(method == 'POST' ? 201 : 200, {
        'ref': 'refs/heads/$branch',
        'object': {'type': 'commit', 'sha': sha},
      });
    }
    if (type == 'blobs') {
      if (method == 'POST')
        return GitHubReply(201, {
          'sha': addBlob(base64Decode(json!['content'] as String)),
        });
      final bytes = blobs[path[2]];
      if (bytes == null) return GitHubReply(404, {});
      return GitHubReply(200, {
        'sha': path[2],
        'size': bytes.length,
        'encoding': 'base64',
        'content': base64Encode(bytes),
      });
    }
    if (type == 'commits') {
      if (method == 'POST')
        return GitHubReply(201, {
          'sha': addCommit(
            json!['tree'] as String,
            List<String>.from(json['parents'] as List),
          ),
        });
      return GitHubReply(200, commits[path[2]]!);
    }
    if (type == 'trees') {
      if (method == 'POST') {
        final flat = Map<String, String>.from(trees[json!['base_tree']]!);
        for (final v in json['tree'] as List) {
          final e = v as Map;
          flat[e['path'] as String] = e['sha'] as String;
        }
        return GitHubReply(201, {'sha': addTree(flat), 'truncated': false});
      }
      final flat = trees[path[2]]!;
      final entries = <Map<String, Object?>>[];
      final directories = <String, Map<String, String>>{};
      for (final item in flat.entries) {
        final slash = item.key.indexOf('/');
        if (slash < 0) {
          entries.add({
            'path': item.key,
            'mode': '100644',
            'type': 'blob',
            'sha': item.value,
          });
        } else {
          directories.putIfAbsent(
            item.key.substring(0, slash),
            () => {},
          )[item.key.substring(slash + 1)] = item.value;
        }
      }
      for (final d in directories.entries) {
        entries.add({
          'path': d.key,
          'mode': '040000',
          'type': 'tree',
          'sha': addTree(d.value),
        });
      }
      return GitHubReply(200, {
        'sha': path[2],
        'truncated': false,
        'tree': entries,
      });
    }
    throw StateError('Unhandled fixture Git request');
  }
}
