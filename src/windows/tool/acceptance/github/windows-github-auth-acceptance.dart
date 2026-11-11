// Isolated real authorization acceptance; never ship as the normal entrypoint.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../support/tool_paths.dart';

import 'package:flutter/widgets.dart';

import 'package:encrypted_photo_app/app/vault_controller.dart';
import 'package:encrypted_photo_app/main.dart' show PhotoVaultApp;
import 'package:encrypted_photo_app/repositories/github_api.dart';
import 'package:encrypted_photo_app/repositories/github_connection.dart';

import '../support/github_auth_observer.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final root = ToolPaths.data('github-auth-acceptance');
  await root.create(recursive: true);
  final observer = GitHubAuthObserver();
  final app = VaultController(
    Directory('${root.path}/vault'),
    repositoryApi: GitHubApi(transport: observer),
  );
  await app.start();
  if (app.screen == VaultScreen.setup) {
    const password = 'artificial authorization acceptance password';
    await app.initialize(
      password: password,
      confirmation: password,
      pin: '6284',
      pinConfirmation: '6284',
    );
  }
  runApp(PhotoVaultApp(controller: app));

  final states = <Map<String, Object?>>[];
  final report = ToolPaths.reportFile('github-auth-acceptance', 'status.json');
  String? previous;
  var writing = false;
  Timer.periodic(const Duration(milliseconds: 500), (_) async {
    if (writing) return;
    writing = true;
    try {
      final connection = app.github;
      final open = app.screen == VaultScreen.library;
      final state = <String, Object?>{
        'screen': app.screen.name,
        'busy': connection?.busy ?? false,
        'waitingForAuthorization': connection?.waitingForAuthorization ?? false,
        'accountPresent': connection?.user != null,
        'verified': connection?.verified ?? false,
        'selectedTargetPresent': connection?.selected != null,
        'eligibleRepositoryCount':
            connection?.repositories.where((r) => r.eligible).length ?? 0,
        'denialShown':
            connection?.message ==
            GitHubConnection.describe(
              const RepositoryFailure(RepositoryFailureCode.denied),
            ),
        'cancellationShown':
            connection?.message ==
            GitHubConnection.describe(
              const RepositoryFailure(RepositoryFailureCode.cancelled),
            ),
        if (open)
          'savedConnectionState': app.catalog.record(
            'preferences',
            'github-connection',
          )?['state'],
        if (open) 'mediaCount': app.mediaCount,
      };
      final signature = jsonEncode(state);
      if (signature != previous) {
        previous = signature;
        states.add({
          'atUtc': DateTime.now().toUtc().toIso8601String(),
          ...state,
        });
        if (states.length > 100) states.removeAt(0);
      }
      await report.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'atUtc': DateTime.now().toUtc().toIso8601String(),
          'pid': pid,
          'productionRoot': 'PhotoVaultApp',
          'isolatedArtificialVault': true,
          'repositoryWritesAllowed': false,
          'blockedRequests': observer.blockedRequests,
          'current': state,
          'states': states,
          'requests': observer.events,
        }),
        flush: true,
      );
    } catch (_) {
      // No user data, raw error or stack is written to an acceptance report.
    } finally {
      writing = false;
    }
  });
}
