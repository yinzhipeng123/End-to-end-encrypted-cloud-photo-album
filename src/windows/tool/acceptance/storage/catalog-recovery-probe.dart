// Isolated process-termination verification of the production catalog code.
// Input is artificial; credentials travel only over stdin, never arguments.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../support/tool_paths.dart';

import 'package:encrypted_photo_shared/security/vault_bootstrap_store.dart';
import 'package:encrypted_photo_shared/security/vault_credentials.dart';
import 'package:encrypted_photo_app/security/windows_data_protection.dart';
import 'package:encrypted_photo_app/storage/library_catalog.dart';

const marker = 'ARTIFICIAL_CATALOG_RECOVERY_20261109';

Map<String, Object?> record(String id, String value) => {
  'id': id,
  'kind': 'photo',
  'observedAt': 1,
  'fileName': '$marker-$value-$id.jpg',
  'path': 'C:/$marker/$id.jpg',
};

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == 'child') {
    final input = jsonDecode(stdin.readLineSync()!) as Map;
    final root = Directory(input['root'] as String);
    final password = input['password'] as String;
    final mode = input['mode'] as String;
    final platform = WindowsDataProtection();
    platform.preparePrivateDirectory(root.path);
    final bootstrap = VaultBootstrapStore(File('${root.path}/vault.bootstrap'));
    final credentials = VaultCredentials(bootstrap);
    final file = File('${root.path}/catalog.db');
    LibraryCatalog? catalog;
    try {
      if (mode == 'initialize') {
        final session = await credentials.initialize(
          password: password,
          confirmation: password,
        );
        catalog = LibraryCatalog.create(file, session);
        catalog.transaction(() {
          for (var i = 0; i < 1200; i++) {
            catalog!.putMedia(record('$i', 'old'));
          }
          catalog!.putAlbum(
            id: 'old',
            name: '$marker old',
            hidden: true,
            members: ['0', '1'],
          );
          catalog.putRecord('tracking', 'source', {
            'generation': 1,
            'stopped': false,
          });
          catalog.putRecord('tracking', 'other', {
            'stopped': true,
            'removed': ['0'],
          });
        });
        catalog.verifyIntegrity();
        stdout.writeln('initialized');
        return;
      }
      final header = await bootstrap.read();
      final session = await credentials.unlock(
        password: password,
        expectedVaultId: header.vaultId,
      );
      catalog = LibraryCatalog.open(file, session);
      if (mode == 'verify') {
        catalog.verifyIntegrity();
        final committed = input['committed'] == true;
        final expected = committed ? 'new' : 'old';
        if (catalog.mediaCount != 1200 ||
            catalog.albums().single['id'] != expected ||
            catalog.albumMembers(expected).length != 2 ||
            catalog.record('tracking', 'source')!['generation'] !=
                (committed ? 2 : 1) ||
            catalog.record('tracking', 'other')!['stopped'] != true ||
            !(catalog.media().first['fileName'] as String).contains(
              '-$expected-',
            )) {
          throw StateError('Recovered data differs from atomic expectation');
        }
        stdout.writeln('verified');
        return;
      }
      void checkpoint(String stage) {
        if (mode == stage) {
          stdout.writeln('ready');
          stdin.readLineSync(); // Parent terminates this actual process here.
          throw StateError('Parent did not terminate the waiting child');
        }
      }

      catalog.transaction(() {
        checkpoint('begin');
        catalog!.deleteAlbum('old');
        checkpoint('removed');
        catalog.putAlbum(
          id: 'new',
          name: '$marker new',
          hidden: true,
          members: ['0', '1'],
        );
        checkpoint('created');
        for (var i = 0; i < 1200; i++) {
          catalog.putMedia(record('$i', 'new'));
        }
        catalog.putRecord('tracking', 'source', {
          'generation': 2,
          'stopped': false,
        });
        checkpoint('updated');
      });
      checkpoint('committed');
    } finally {
      catalog?.close();
      credentials.revoke();
    }
    return;
  }
  final resultsRoot = ToolPaths.data('catalog-recovery');
  await resultsRoot.create(recursive: true);
  final run = await resultsRoot.createTemp('run-');
  final evidence = <Map<String, Object?>>[];
  const password = 'isolated artificial catalog process password';

  Future<Process> child(
    Directory root,
    String mode, {
    bool committed = false,
  }) async {
    final process = await Process.start(Platform.resolvedExecutable, ['child']);
    process.stdin.writeln(
      jsonEncode({
        'root': root.absolute.path,
        'password': password,
        'mode': mode,
        'committed': committed,
      }),
    );
    return process;
  }

  Future<void> completed(
    Directory root,
    String mode, {
    bool committed = false,
  }) async {
    final process = await child(root, mode, committed: committed);
    final output = utf8.decoder.bind(process.stdout).join();
    final errors = process.stderr.drain<void>();
    await process.stdin.close();
    final code = await process.exitCode.timeout(const Duration(seconds: 30));
    await errors;
    final text = await output;
    if (code != 0 ||
        !text.contains(mode == 'initialize' ? 'initialized' : 'verified')) {
      throw StateError('Isolated child $mode failed (exit $code)');
    }
  }

  for (final stage in ['begin', 'removed', 'created', 'updated', 'committed']) {
    final root = Directory('${run.path}/$stage');
    await completed(root, 'initialize');
    final process = await child(root, stage);
    final errors = process.stderr.drain<void>();
    try {
      await utf8.decoder
          .bind(process.stdout)
          .transform(const LineSplitter())
          .firstWhere((line) => line == 'ready')
          .timeout(const Duration(seconds: 30));
      if (!process.kill()) throw StateError('Could not terminate child');
      await process.exitCode;
      await errors;
      // Inspect actual journal/database residues before a new process opens them.
      var checkedBytes = 0;
      for (final file in root.listSync().whereType<File>()) {
        final bytes = file.readAsBytesSync();
        checkedBytes += bytes.length;
        if (latin1.decode(bytes).contains(marker)) {
          throw StateError('Artificial plaintext marker found in residue');
        }
      }
      await completed(root, 'verify', committed: stage == 'committed');
      evidence.add({
        'stage': stage,
        'passed': true,
        'residue_bytes_checked': checkedBytes,
        'expected': stage == 'committed'
            ? 'new complete transaction'
            : 'old complete transaction',
      });
      stdout.writeln('$stage: passed');
    } finally {
      process.kill();
      await process.stdin.close();
    }
  }
  await ToolPaths.reportFile(
    'catalog-recovery',
    '${run.uri.pathSegments.where((s) => s.isNotEmpty).last}.json',
  ).writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'recorded_at_utc': DateTime.now().toUtc().toIso8601String(),
      'platform': Platform.operatingSystemVersion,
      'production_implementation': 'lib/storage/library_catalog.dart',
      'passed': evidence.length,
      'stages': evidence,
      'scope': 'Actual production catalog, native encryption, forced process termination and fresh process recovery. Artificial data only. No power-loss or disk-full claim.',
    }),
  );
  stdout.writeln(
    'report directory: ${ToolPaths.reports('catalog-recovery').path}',
  );
}
