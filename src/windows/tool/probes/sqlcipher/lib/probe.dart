/// 仅用于人工数据验证，不是生产目录、密码派生或密钥保管实现。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:sqlite3/sqlite3.dart';

class ProbeFailure implements Exception {
  final String check;
  const ProbeFailure(this.check);
}

void require(bool condition, String check) {
  if (!condition) throw ProbeFailure(check);
}

String randomHex(int bytes) {
  final rng = Random.secure();
  return List.generate(
    bytes,
    (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

Object? scalar(Database db, String query) =>
    db.select(query).single.values.single;

Database openEncrypted(
  String path,
  String key, {
  OpenMode mode = OpenMode.readWrite,
}) {
  require(RegExp(r'^[0-9a-f]{64}$').hasMatch(key), 'test-key-shape');
  final db = sqlite3.open(path, mode: mode);
  try {
    final version = db.select('PRAGMA cipher_version');
    require(version.isNotEmpty, 'sqlcipher-required');
    // 不记录 SQL 或密钥。随机测试密钥绕过密码派生，不代表生产 KDF 决策。
    db.execute('PRAGMA cipher_log_level = NONE');
    db.execute('PRAGMA key = "x\'$key\'"');
    db.execute('PRAGMA temp_store = MEMORY');
    db.execute('PRAGMA cipher_memory_security = ON');
    db.execute('PRAGMA foreign_keys = ON');
    db.execute('PRAGMA busy_timeout = 5000');
    db.execute('PRAGMA synchronous = FULL');
    require(scalar(db, 'PRAGMA temp_store') == 2, 'memory-temp-required');
    // key pragma 本身不能证明密钥正确，必须真正读取页面。
    db.select('SELECT count(*) FROM sqlite_master');
    return db;
  } catch (_) {
    db.close();
    rethrow;
  }
}

void seed(Database db, String marker) {
  db.execute('''
    PRAGMA user_version = 1;
    CREATE TABLE sources(id INTEGER PRIMARY KEY, observed TEXT NOT NULL,
      generation INTEGER NOT NULL, stopped INTEGER NOT NULL);
    CREATE TABLE albums(id INTEGER PRIMARY KEY, name TEXT NOT NULL, active INTEGER NOT NULL);
    CREATE TABLE overrides(media INTEGER PRIMARY KEY, action TEXT NOT NULL);
    CREATE TABLE payload(id INTEGER PRIMARY KEY, path TEXT NOT NULL, filename TEXT NOT NULL);
  ''');
  db.execute('BEGIN IMMEDIATE');
  try {
    db.execute('INSERT INTO sources VALUES (1, ?, 1, 0), (2, ?, 1, 1)', [
      '$marker-old',
      '$marker-stopped',
    ]);
    db.execute('INSERT INTO albums VALUES (1, ?, 1)', ['$marker-old']);
    db.execute("INSERT INTO overrides VALUES (11, 'add'), (12, 'remove')");
    final insert = db.prepare('INSERT INTO payload VALUES (?, ?, ?)');
    try {
      for (var i = 0; i < 1200; i++) {
        insert.execute([i, '$marker/目录/$i/${'x' * 1800}', '$marker-照片-$i.jpg']);
      }
    } finally {
      insert.close();
    }
    db.execute('COMMIT');
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  }
}

/// 探针专用的事务示例，验证数据库原子性，不替代正式 AlbumImportTracker 适配。
void renameFixture(
  Database db,
  String marker, {
  void Function(String)? checkpoint,
}) {
  if (db
          .select('SELECT observed FROM sources WHERE id = 1')
          .single['observed'] ==
      '$marker-new')
    return;
  db.execute('BEGIN IMMEDIATE');
  checkpoint?.call('begin');
  db.execute('UPDATE albums SET active = 0 WHERE id = 1');
  checkpoint?.call('ended');
  db.execute('INSERT INTO albums VALUES (2, ?, 1)', ['$marker-new']);
  checkpoint?.call('created');
  db.execute('UPDATE sources SET observed = ?, generation = 2 WHERE id = 1', [
    '$marker-new',
  ]);
  // 小缓存下强制产生可观察的 journal/WAL 页面，用于崩溃及明文检查。
  db.execute('UPDATE payload SET filename = ?', ['$marker-new.jpg']);
  checkpoint?.call('observed');
  db.execute('COMMIT');
  checkpoint?.call('committed');
}

void checkState(Database db, String marker, {required bool committed}) {
  final source = db.select('SELECT * FROM sources WHERE id = 1').single;
  require(source['generation'] == (committed ? 2 : 1), 'generation-atomic');
  require(
    source['observed'] == '$marker-${committed ? 'new' : 'old'}',
    'observation-atomic',
  );
  require(
    scalar(db, 'SELECT count(*) FROM albums') == (committed ? 2 : 1),
    'album-atomic',
  );
  require(
    scalar(db, 'SELECT active FROM albums WHERE id = 1') == (committed ? 0 : 1),
    'old-binding-atomic',
  );
  require(
    scalar(db, 'SELECT stopped FROM sources WHERE id = 2') == 1,
    'stopped-preserved',
  );
  final overrides = db.select('SELECT * FROM overrides ORDER BY media');
  require(
    overrides.length == 2 &&
        overrides[0]['action'] == 'add' &&
        overrides[1]['action'] == 'remove',
    'app-overrides-preserved',
  );
  require(scalar(db, 'PRAGMA integrity_check') == 'ok', 'sqlite-integrity');
  require(
    db.select('PRAGMA cipher_integrity_check').isEmpty,
    'cipher-integrity',
  );
}

bool containsBytes(List<int> bytes, List<int> pattern) {
  for (var i = 0; i <= bytes.length - pattern.length; i++) {
    if (bytes[i] != pattern[0]) continue;
    var found = true;
    for (var j = 1; j < pattern.length; j++) {
      if (bytes[i + j] != pattern[j]) {
        found = false;
        break;
      }
    }
    if (found) return true;
  }
  return false;
}

/// 抽样哨兵检查是辅助证据，不是对所有明文泄漏路径的证明。
Map<String, int> inspectFiles(Directory root, String marker) {
  final utf16le = marker.codeUnits.expand((c) => [c & 255, c >> 8]).toList();
  final utf16be = marker.codeUnits.expand((c) => [c >> 8, c & 255]).toList();
  final patterns = [utf8.encode(marker), utf16le, utf16be];
  final sizes = <String, int>{};
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final bytes = entity.readAsBytesSync();
    for (final pattern in patterns) {
      require(!containsBytes(bytes, pattern), 'no-plaintext-sentinel');
    }
    final name = entity.uri.pathSegments.last;
    require(!name.contains(marker), 'no-metadata-in-filename');
    sizes[name] = bytes.length;
    if (name.endsWith('.db')) {
      require(
        !containsBytes(bytes.take(16).toList(), utf8.encode('SQLite format 3')),
        'encrypted-header',
      );
    }
  }
  return sizes;
}

void expectUnreadable(String path, String? key) {
  final db = sqlite3.open(path, mode: OpenMode.readOnly);
  var rejected = false;
  try {
    db.execute('PRAGMA cipher_log_level = NONE');
    if (key != null) db.execute('PRAGMA key = "x\'$key\'"');
    db.select('SELECT count(*) FROM sqlite_master');
  } on SqliteException {
    rejected = true;
  } finally {
    db.close();
  }
  require(rejected, 'wrong-or-missing-key-rejected');
}

/// 可由桌面 CLI 和独立 iOS integration_test 调用的同进程验证。
Map<String, Object?> runCoreProbe(Directory root) {
  require(
    root.existsSync() && root.listSync().isEmpty,
    'empty-probe-directory-required',
  );
  final key = randomHex(32);
  final marker = 'MIYU_PRIVATE_${randomHex(16)}';
  final checks = <String>[];
  final dbPath = '${root.path}/catalog.db';
  final temp = Directory('${root.path}/temp')..createSync();
  final previousTemp = sqlite3.tempDirectory;
  sqlite3.tempDirectory = temp.path;
  try {
    final db = openEncrypted(dbPath, key, mode: OpenMode.readWriteCreate);
    final info = <String, Object?>{};
    try {
      seed(db, marker);
      info.addAll({
        'cipher': scalar(db, 'PRAGMA cipher_version'),
        'sqlite': scalar(db, 'SELECT sqlite_version()'),
        'provider': scalar(db, 'PRAGMA cipher_provider'),
        'providerVersion': scalar(db, 'PRAGMA cipher_provider_version'),
        'tempStore': scalar(db, 'PRAGMA temp_store'),
        'memorySecurity': scalar(db, 'PRAGMA cipher_memory_security'),
        'compileOptions': db
            .select('PRAGMA compile_options')
            .map((r) => r.values.single)
            .toList(),
      });
      require(
        (info['compileOptions'] as List).contains('TEMP_STORE=2'),
        'compiled-temp-store',
      );
      require(
        scalar(db, 'PRAGMA cipher_plaintext_header_size') == '0' ||
            scalar(db, 'PRAGMA cipher_plaintext_header_size') == 0,
        'no-plaintext-header',
      );
      checks.add('sqlcipher-identity-and-configuration');
      checkState(db, marker, committed: false);
      inspectFiles(root, marker);
      checks.add('encrypted-main-and-integrity');

      db.execute('PRAGMA cache_size = 8');
      db.execute('PRAGMA cache_spill = ON');
      require(
        scalar(db, 'PRAGMA journal_mode = DELETE') == 'delete',
        'delete-journal-mode',
      );
      db.execute('BEGIN IMMEDIATE');
      db.execute('UPDATE payload SET filename = ?', ['$marker-journal.jpg']);
      final journal = File('$dbPath-journal');
      require(
        journal.existsSync() && journal.lengthSync() > 4096,
        'journal-observed',
      );
      info['journalBytes'] = journal.lengthSync();
      inspectFiles(root, marker);
      db.execute('ROLLBACK');
      require(
        db
                .select('SELECT filename FROM payload WHERE id = 0')
                .single['filename'] ==
            '$marker-照片-0.jpg',
        'journal-rollback-data',
      );
      checks.add('rollback-journal-ciphertext-and-rollback');

      require(scalar(db, 'PRAGMA journal_mode = WAL') == 'wal', 'wal-mode');
      db.execute('PRAGMA wal_autocheckpoint = 0');
      renameFixture(db, marker);
      final wal = File('$dbPath-wal');
      require(wal.existsSync() && wal.lengthSync() > 4096, 'wal-observed');
      info['walBytes'] = wal.lengthSync();
      info['activeFiles'] = inspectFiles(root, marker);
      final reader = openEncrypted(dbPath, key);
      try {
        checkState(reader, marker, committed: true);
      } finally {
        reader.close();
      }
      checks.add('wal-ciphertext-and-second-connection-read');
      renameFixture(db, marker);
      checkState(db, marker, committed: true);
      checks.add('rename-replay-stopped-and-overrides');

      db.execute('CREATE TEMP TABLE staging AS SELECT * FROM payload');
      final sorted = db.select(
        'SELECT path FROM staging ORDER BY substr(path, 3) DESC',
      );
      require(sorted.length == 1200, 'temp-sort-count');
      final plan = db.select(
        'EXPLAIN QUERY PLAN SELECT path FROM staging ORDER BY substr(path, 3) DESC',
      );
      require(
        plan.any(
          (r) => r.values.any((v) => v.toString().contains('TEMP B-TREE')),
        ),
        'sort-temp-btree-used',
      );
      require(temp.listSync().isEmpty, 'no-observed-temp-file');
      info['tempSortRows'] = sorted.length;
      inspectFiles(root, marker);
      checks.add('memory-temp-table-and-sort');

      // SQLCipher 推荐的导出方式；目标显式设置独立随机测试密钥。
      final backupKey = randomHex(32);
      final backupPath = '${root.path}/backup.db';
      db.execute('ATTACH DATABASE ? AS encrypted_backup KEY ?', [
        backupPath,
        "x'$backupKey'",
      ]);
      db.select("SELECT sqlcipher_export('encrypted_backup')");
      db.execute('DETACH DATABASE encrypted_backup');
      final backup = openEncrypted(backupPath, backupKey);
      try {
        checkState(backup, marker, committed: true);
      } finally {
        backup.close();
      }
      expectUnreadable(backupPath, key);
      inspectFiles(root, marker);
      checks.add('explicitly-keyed-export');
    } finally {
      db.close();
    }

    final before = File(dbPath).readAsBytesSync();
    expectUnreadable(dbPath, randomHex(32));
    expectUnreadable(dbPath, null);
    require(
      base64Encode(File(dbPath).readAsBytesSync()) == base64Encode(before),
      'rejected-open-does-not-overwrite',
    );
    checks.add('wrong-and-missing-key-no-overwrite');
    final reopened = openEncrypted(dbPath, key);
    try {
      checkState(reopened, marker, committed: true);
    } finally {
      reopened.close();
    }
    checks.add('correct-key-reopen');

    final corruptPath = '${root.path}/tampered.db';
    final corrupt = List<int>.of(before);
    corrupt[100] ^= 1;
    File(corruptPath).writeAsBytesSync(corrupt, flush: true);
    expectUnreadable(corruptPath, key);
    checks.add('tampered-page-rejected');

    final futurePath = '${root.path}/future.db';
    File(dbPath).copySync(futurePath);
    final future = openEncrypted(futurePath, key);
    try {
      future.execute('PRAGMA user_version = 999');
    } finally {
      future.close();
    }
    final futureBefore = File(futurePath).readAsBytesSync();
    final futureReader = openEncrypted(
      futurePath,
      key,
      mode: OpenMode.readOnly,
    );
    try {
      require(
        scalar(futureReader, 'PRAGMA user_version') == 999,
        'future-version-readable',
      );
      // 示例拒绝策略：识别未知版本后不创建表、不迁移、不重置。
    } finally {
      futureReader.close();
    }
    require(
      base64Encode(futureBefore) ==
          base64Encode(File(futurePath).readAsBytesSync()),
      'future-version-no-write',
    );
    checks.add('future-version-read-only-inspection');
    info['finalFiles'] = inspectFiles(root, marker);
    info['checks'] = checks;
    return info;
  } finally {
    sqlite3.tempDirectory = previousTemp;
  }
}
