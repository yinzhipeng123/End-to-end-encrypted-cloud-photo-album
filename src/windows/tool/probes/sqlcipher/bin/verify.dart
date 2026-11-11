import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:miyu_sqlcipher_probe/probe.dart';
import 'package:sqlite3/sqlite3.dart';

Future<void> main(List<String> args) async {
  try {
    if (args.length == 4 && args[0] == '--child') {
      await child(args[1], args[2], args[3]);
      return;
    }
    require(args.length == 2, 'usage-data-parent-and-report-parent');
    final parent = Directory(args[0])..createSync(recursive: true);
    final reportParent = Directory(args[1])..createSync(recursive: true);
    final run = parent.createTempSync('run-');
    final core = runCoreProbe(Directory('${run.path}/core')..createSync());
    print(jsonEncode({'core': core}));
    final crashes = <Map<String, Object?>>[];
    for (final mode in ['DELETE', 'WAL']) {
      for (final point in [
        'begin',
        'ended',
        'created',
        'observed',
        'committed',
      ]) {
        print('Checking forced recovery: $mode / $point');
        final result = await crashProbe(
          Directory('${run.path}/$mode-$point')..createSync(),
          mode,
          point,
        );
        crashes.add(result);
        print(jsonEncode({'crash': result}));
      }
    }
    final report = {
      'executedAtUtc': DateTime.now().toUtc().toIso8601String(),
      'platform': Platform.operatingSystem,
      'dart': Platform.version.split(' ').first,
      'core': core,
      'crashes': crashes,
      'limits': [
        'not-production-key-management',
        'no-power-loss-test',
        'no-ios-runtime-result',
        'no-os-wide-file-trace',
      ],
    };
    File(
      '${reportParent.path}/${run.uri.pathSegments.where((s) => s.isNotEmpty).last}.json',
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
    print(
      'PASS: ${core['checks'] is List ? (core['checks'] as List).length : 0} core checks; ${crashes.length} forced-process recovery cases.',
    );
    print('Report directory: ${reportParent.path}');
  } catch (e) {
    // 不输出异常正文／SQL／测试密钥。编号可用于定位探针断言。
    stderr.writeln('FAIL: ${e is ProbeFailure ? e.check : e.runtimeType}');
    exitCode = 1;
  }
}

Future<void> child(String path, String mode, String point) async {
  final input = jsonDecode(stdin.readLineSync()!) as Map<String, dynamic>;
  final key = input['key'] as String;
  final marker = input['marker'] as String;
  final db = openEncrypted(path, key);
  db.execute('PRAGMA journal_mode = $mode');
  db.execute('PRAGMA wal_autocheckpoint = 0');
  db.execute('PRAGMA cache_size = 8');
  db.execute('PRAGMA cache_spill = ON');
  renameFixture(
    db,
    marker,
    checkpoint: (current) {
      if (current != point) return;
      // 写入确认信号后等父进程强制终止；不执行 close / rollback。
      stdout.writeln('READY');
      // 同步等待保持事务正好停在目标边界，父进程超时会清理子进程。
      stdin.readLineSync();
      throw const ProbeFailure('child-was-not-killed');
    },
  );
  throw const ProbeFailure('checkpoint-not-reached');
}

Future<Map<String, Object?>> crashProbe(
  Directory root,
  String mode,
  String point,
) async {
  final key = randomHex(32);
  final marker = 'MIYU_CRASH_${randomHex(16)}';
  final path = '${root.path}/catalog.db';
  final initial = openEncrypted(path, key, mode: OpenMode.readWriteCreate);
  try {
    seed(initial, marker);
  } finally {
    initial.close();
  }
  // 编译后的 exe 自启动。密钥只经匿名 stdin 管道传递，不在参数或环境中。
  final process = await Process.start(Platform.resolvedExecutable, [
    '--child',
    path,
    mode,
    point,
  ]);
  final errors = process.stderr.drain<void>();
  final ready = Completer<void>();
  final subscription = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(
        (line) {
          if (line == 'READY' && !ready.isCompleted) ready.complete();
        },
        onDone: () {
          if (!ready.isCompleted)
            ready.completeError(
              const ProbeFailure('child-exited-before-checkpoint'),
            );
        },
      );
  try {
    process.stdin.writeln(jsonEncode({'key': key, 'marker': marker}));
    await process.stdin.flush();
    await ready.future.timeout(const Duration(seconds: 25));
    require(process.kill(ProcessSignal.sigkill), 'child-termination-request');
    final code = await process.exitCode.timeout(const Duration(seconds: 10));
    require(code != 0, 'child-terminated-abnormally');
    // Windows 的 WAL 共享内存含跨进程字节锁；在终止后、恢复前检查
    // 保留下来的文件，避免把锁冲突误当作恢复或加密失败。
    final files = inspectFiles(root, marker);
    if (point == 'observed') {
      final suffix = mode == 'WAL' ? '-wal' : '-journal';
      require(
        (files['catalog.db$suffix'] ?? 0) > 4096,
        'crash-journal-observed',
      );
    }
    final recovered = openEncrypted(path, key);
    try {
      checkState(recovered, marker, committed: point == 'committed');
      renameFixture(recovered, marker);
      renameFixture(recovered, marker);
      checkState(recovered, marker, committed: true);
    } finally {
      recovered.close();
    }
    inspectFiles(root, marker);
    return {
      'mode': mode,
      'point': point,
      'recovered': true,
      'replayNoDuplicate': true,
      'filesAtCrash': files,
    };
  } finally {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode.timeout(const Duration(seconds: 10));
    await subscription.cancel();
    await process.stdin.close();
    await errors;
  }
}
