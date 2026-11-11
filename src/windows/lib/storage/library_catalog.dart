import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'package:encrypted_photo_shared/model/library_query.dart';
import 'package:encrypted_photo_shared/security/vault_credentials.dart';

enum CatalogFailureCode {
  alreadyExists,
  missing,
  unreadable,
  backendMismatch,
  unsupportedVersion,
  closed,
  invalidRecord,
  writeFailed,
}

final class CatalogFailure implements Exception {
  const CatalogFailure(this.code);
  final CatalogFailureCode code;
  @override
  String toString() => 'CatalogFailure(${code.name})';
}

/// Real encrypted catalog. Original media are never moved into this database.
/// All paths, filenames, organization, queue and replica data stay inside it.
final class LibraryCatalog {
  LibraryCatalog._(this._db, this._session, this._checkAccess) {
    _unsubscribe = _session.onClose(close);
  }
  static const schemaVersion = 3;
  final Database _db;
  final VaultCredentialSession _session;
  final void Function()? _checkAccess;
  void Function()? _unsubscribe;
  bool _closed = false;
  bool _transaction = false;

  static LibraryCatalog create(File file, VaultCredentialSession session) {
    if (session.isClosed) throw const CatalogFailure(CatalogFailureCode.closed);
    try {
      file.createSync(exclusive: true);
    } on FileSystemException {
      if (file.existsSync())
        throw const CatalogFailure(CatalogFailureCode.alreadyExists);
      throw const CatalogFailure(CatalogFailureCode.writeFailed);
    }
    return _open(file, session, creating: true);
  }

  static LibraryCatalog open(
    File file,
    VaultCredentialSession session, {
    void Function()? checkAccess,
  }) => _open(file, session, creating: false, checkAccess: checkAccess);

  static LibraryCatalog _open(
    File file,
    VaultCredentialSession session, {
    required bool creating,
    void Function()? checkAccess,
  }) {
    Database? database;
    try {
      if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const CatalogFailure(CatalogFailureCode.missing);
      }
      if (!creating && file.lengthSync() == 0)
        throw const CatalogFailure(CatalogFailureCode.unreadable);
      database = sqlite3.open(file.path, mode: OpenMode.readWrite);
      final db = database;
      final version = db.select('PRAGMA cipher_version');
      if (version.isEmpty ||
          version.single.values.single != '4.20.0 community') {
        throw const CatalogFailure(CatalogFailureCode.backendMismatch);
      }
      db.execute('PRAGMA cipher_log_level = NONE');
      session.configureCatalogConnection((key) {
        final hex = key
            .map((value) => value.toRadixString(16).padLeft(2, '0'))
            .join();
        // This API accepts a SQLCipher raw random key. Never log SQL or errors.
        db.execute('PRAGMA key = "x\'$hex\'"');
      });
      db.execute('PRAGMA temp_store = MEMORY');
      db.execute('PRAGMA cipher_memory_security = ON');
      db.execute('PRAGMA foreign_keys = ON');
      db.execute('PRAGMA busy_timeout = 5000');
      db.execute('PRAGMA synchronous = FULL');
      if (_scalar(db, 'PRAGMA temp_store') != 2 ||
          _scalar(db, 'PRAGMA foreign_keys') != 1 ||
          // SQLCipher returns TEXT "1" for this pragma, unlike SQLite's
          // integer-valued pragmas above. Require the exact enabled result.
          _scalar(db, 'PRAGMA cipher_memory_security') != '1' ||
          _scalar(db, 'PRAGMA synchronous') != 2) {
        throw const CatalogFailure(CatalogFailureCode.backendMismatch);
      }
      // First real page read: key pragma success alone is not authentication.
      db.select('SELECT count(*) FROM sqlite_master');
      final schema = _scalar(db, 'PRAGMA user_version');
      if (!creating &&
          (schema is! int || schema < 1 || schema > schemaVersion)) {
        throw const CatalogFailure(CatalogFailureCode.unsupportedVersion);
      }
      if (creating &&
          (schema != 0 ||
              _scalar(db, 'SELECT count(*) FROM sqlite_master') != 0)) {
        throw const CatalogFailure(CatalogFailureCode.alreadyExists);
      }
      if (_scalar(db, 'PRAGMA journal_mode = DELETE') != 'delete') {
        throw const CatalogFailure(CatalogFailureCode.backendMismatch);
      }
      if (creating) {
        db.execute('BEGIN IMMEDIATE');
        try {
          db.execute(_schema);
          db.execute(
            'INSERT INTO catalog_identity(vault_id, catalog_id) VALUES (?, ?)',
            [_hex(session.vaultId), _hex(session.catalogId)],
          );
          db.execute('PRAGMA user_version = 1');
          db.execute('COMMIT');
        } catch (_) {
          db.execute('ROLLBACK');
          rethrow;
        }
      }
      final identity = db.select(
        'SELECT vault_id, catalog_id FROM catalog_identity',
      );
      if (identity.length != 1 ||
          identity.single['vault_id'] != _hex(session.vaultId) ||
          identity.single['catalog_id'] != _hex(session.catalogId)) {
        throw const CatalogFailure(CatalogFailureCode.unreadable);
      }
      _migrate(db);
      db.createFunction(
        functionName: 'epa_lower',
        argumentCount: const AllowedArgumentCount(1),
        deterministic: true,
        function: (arguments) =>
            (arguments.single as String? ?? '').toLowerCase(),
      );
      final catalog = LibraryCatalog._(db, session, checkAccess);
      database = null;
      return catalog;
    } on CatalogFailure {
      rethrow;
    } catch (_) {
      throw const CatalogFailure(CatalogFailureCode.unreadable);
    } finally {
      database?.close();
    }
  }

  static Object? _scalar(Database db, String sql) =>
      db.select(sql).single.values.single;

  /// Every supported upgrade is a single encrypted transaction. Version 0 is
  /// accepted only by create(), never as an excuse to reinitialize an old file.
  static void _migrate(Database db) {
    final current = _scalar(db, 'PRAGMA user_version') as int;
    if (current == schemaVersion) return;
    db.execute('BEGIN EXCLUSIVE');
    try {
      if (current == 1) {
        // Sources need durable scan/access state as well as their root path.
        // This schema does not choose the later media identity/sync protocol.
        db.execute(
          "ALTER TABLE sources ADD COLUMN state TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(state))",
        );
        db.execute('PRAGMA user_version = 2');
      } else if (current != 2) {
        throw const CatalogFailure(CatalogFailureCode.unsupportedVersion);
      }
      db.execute('''CREATE TABLE import_files(
        source_id TEXT NOT NULL REFERENCES sources(id), path TEXT NOT NULL,
        media_id TEXT REFERENCES media(id), native_id TEXT, created INTEGER,
        size INTEGER NOT NULL, modified INTEGER NOT NULL, epoch TEXT NOT NULL,
        status TEXT NOT NULL, ready_at INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
        issue TEXT, PRIMARY KEY(source_id,path));
        CREATE INDEX import_due ON import_files(status,ready_at);
        CREATE INDEX import_identity ON import_files(native_id,created);
        CREATE INDEX import_media ON import_files(media_id);
        PRAGMA user_version=3;''');
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  static String _hex(List<int> bytes) =>
      bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

  void _requireOpen() {
    if (_closed || _session.isClosed)
      throw const CatalogFailure(CatalogFailureCode.closed);
    _checkAccess?.call();
  }

  T transaction<T>(T Function() action) {
    _requireOpen();
    if (_transaction) return action();
    _transaction = true;
    try {
      _db.execute('BEGIN IMMEDIATE');
      try {
        final result = action();
        if (result is Future)
          throw const CatalogFailure(CatalogFailureCode.invalidRecord);
        _requireOpen();
        _db.execute('COMMIT');
        return result;
      } catch (_) {
        if (!_closed) _db.execute('ROLLBACK');
        rethrow;
      }
    } on SqliteException {
      throw const CatalogFailure(CatalogFailureCode.writeFailed);
    } finally {
      _transaction = false;
    }
  }

  List<Map<String, Object?>> media({int limit = 200, int offset = 0}) {
    _requireOpen();
    if (limit < 1 || limit > 1000 || offset < 0)
      throw const CatalogFailure(CatalogFailureCode.invalidRecord);
    try {
      return _db
          .select(
            'SELECT body FROM media ORDER BY observed_at DESC, id LIMIT ? OFFSET ?',
            [limit, offset],
          )
          .map(
            (row) => Map<String, Object?>.from(
              jsonDecode(row['body'] as String) as Map,
            ),
          )
          .toList();
    } catch (_) {
      throw const CatalogFailure(CatalogFailureCode.unreadable);
    }
  }

  int get mediaCount {
    _requireOpen();
    try {
      return _scalar(_db, 'SELECT count(*) FROM media') as int;
    } catch (_) {
      throw const CatalogFailure(CatalogFailureCode.unreadable);
    }
  }

  Map<String, Object?>? mediaById(String id) {
    final rows = _rows('SELECT body FROM media WHERE id=?', [id]);
    return rows.isEmpty
        ? null
        : Map<String, Object?>.from(
            jsonDecode(rows.single['body'] as String) as Map,
          );
  }

  /// One predicate for pages, counts, selection snapshots and execution-time
  /// validation. Bind search/IDs as data; '%' and '_' are literal characters.
  (String, List<Object?>) _libraryWhere(
    LibraryQuery query,
    Iterable<String>? ids,
  ) {
    final clauses = <String>[
      "json_extract(m.body,'\$.pairedComponentOf') IS NULL",
      "coalesce(json_extract(m.body,'\$.deletedFromLibrary'),0)!=1",
    ];
    final arguments = <Object?>[];
    if (query.albumId case final album?) {
      clauses.add(
        'EXISTS(SELECT 1 FROM album_members a WHERE a.album_id=? AND a.media_id=m.id)',
      );
      arguments.add(album);
    } else {
      clauses.add(
        'NOT EXISTS(SELECT 1 FROM album_members a JOIN albums b ON b.id=a.album_id WHERE a.media_id=m.id AND b.hidden=1)',
      );
    }
    if (query.favoritesOnly)
      clauses.add("json_extract(m.body,'\$.favorite')=1");
    final term = query.search.trim().toLowerCase();
    if (term.isNotEmpty) {
      clauses.add(
        "(instr(epa_lower(json_extract(m.body,'\$.fileName')),?)>0 OR EXISTS(SELECT 1 FROM json_each(m.body,'\$.resources') r WHERE instr(epa_lower(json_extract(r.value,'\$.fileName')),?)>0))",
      );
      arguments.addAll([term, term]);
    }
    final connection = record('preferences', 'github-connection');
    final repository = connection?['repository'];
    final targetId = repository is Map ? repository['id'] : null;
    final receiptPrefix = targetId is int
        ? 'receipt:github:$targetId:${_hex(_session.vaultId)}:'
        : 'unselected:';
    final remote =
        "EXISTS(SELECT 1 FROM records r WHERE r.namespace='replicas' AND r.id=?||m.id AND json_extract(r.body,'\$.status') IN ('listed','verified') AND json_extract(r.body,'\$.sourceVersion')=json_extract(m.body,'\$.version'))";
    final verified =
        "EXISTS(SELECT 1 FROM records r WHERE r.namespace='replicas' AND r.id=?||m.id AND json_extract(r.body,'\$.status')='verified' AND json_extract(r.body,'\$.sourceVersion')=json_extract(m.body,'\$.version'))";
    switch (query.filter) {
      case LibraryFilter.all:
        break;
      case LibraryFilter.synced:
        clauses.add(verified);
        arguments.add(receiptPrefix);
        break;
      case LibraryFilter.remoteOnly:
        clauses.add(
          "coalesce(json_extract(m.body,'\$.local'),0)!=1 AND $remote",
        );
        arguments.add(receiptPrefix);
        break;
      case LibraryFilter.pending:
        clauses.add(
          "json_extract(m.body,'\$.local')=1 AND coalesce(json_extract(m.body,'\$.autoUploadSuppressed'),0)!=1 AND NOT $verified",
        );
        arguments.add(receiptPrefix);
        break;
      case LibraryFilter.localOnly:
        clauses.add("json_extract(m.body,'\$.local')=1 AND NOT $remote");
        arguments.add(receiptPrefix);
    }
    if (ids != null) {
      clauses.add('m.id IN (SELECT value FROM json_each(?))');
      arguments.add(jsonEncode(ids.toSet().toList()));
    }
    return (clauses.join(' AND '), arguments);
  }

  List<Map<String, Object?>> queryMedia(LibraryQuery query, {int page = 0}) {
    if (page < 0) throw const CatalogFailure(CatalogFailureCode.invalidRecord);
    final (where, args) = _libraryWhere(query, null);
    return _rows(
          'SELECT m.body FROM media m WHERE $where ORDER BY m.observed_at DESC,m.id LIMIT 200 OFFSET ?',
          [...args, page * 200],
        )
        .map(
          (r) =>
              Map<String, Object?>.from(jsonDecode(r['body'] as String) as Map),
        )
        .toList();
  }

  int queryCount(LibraryQuery query) {
    final (where, args) = _libraryWhere(query, null);
    return _rows(
          'SELECT count(*) AS n FROM media m WHERE $where',
          args,
        ).single['n']
        as int;
  }

  /// Only IDs are materialized for full-result select-all, never media bodies.
  List<String> queryIds(LibraryQuery query, {Iterable<String>? within}) {
    final (where, args) = _libraryWhere(query, within);
    return _rows(
      'SELECT m.id FROM media m WHERE $where ORDER BY m.observed_at DESC,m.id',
      args,
    ).map((r) => r['id'] as String).toList();
  }

  Map<String, Object?>? albumById(String id) {
    final rows = _rows('SELECT id,name,hidden FROM albums WHERE id=?', [id]);
    return rows.isEmpty ? null : rows.single;
  }

  void _requireAlbum(String id) {
    if (albumById(id) == null)
      throw const CatalogFailure(CatalogFailureCode.missing);
  }

  void renameAlbum(String id, String name) => transaction(() {
    _requireAlbum(id);
    if (name.trim().isEmpty)
      throw const CatalogFailure(CatalogFailureCode.invalidRecord);
    _db.execute('UPDATE albums SET name=? WHERE id=?', [name.trim(), id]);
  });

  void setAlbumHidden(String id, bool hidden) => transaction(() {
    _requireAlbum(id);
    _db.execute('UPDATE albums SET hidden=? WHERE id=?', [hidden ? 1 : 0, id]);
  });

  /// Whole batch is one encrypted transaction. Failure never leaves an
  /// acknowledged partial batch; stale/hidden IDs are excluded before writing.
  int organize(
    LibraryQuery query,
    Iterable<String> requested, {
    bool? favorite,
    String? albumId,
    bool remove = false,
  }) => transaction(() {
    if ((favorite == null) == (albumId == null))
      throw const CatalogFailure(CatalogFailureCode.invalidRecord);
    if (albumId != null) _requireAlbum(albumId);
    final valid = queryIds(query, within: requested);
    if (valid.isEmpty) return 0;
    final ids = jsonEncode(valid);
    if (favorite != null) {
      _db.execute(
        "UPDATE media SET body=json_set(body,'\$.favorite',json(?)) WHERE id IN (SELECT value FROM json_each(?))",
        [favorite ? 'true' : 'false', ids],
      );
    } else if (remove) {
      _db.execute(
        'DELETE FROM album_members WHERE album_id=? AND media_id IN (SELECT value FROM json_each(?))',
        [albumId, ids],
      );
    } else {
      _db.execute(
        'INSERT OR IGNORE INTO album_members(album_id,media_id) SELECT ?,value FROM json_each(?)',
        [albumId, ids],
      );
    }
    return valid.length;
  });

  void observeImport({
    required String source,
    required String path,
    required int size,
    required int modified,
    required String epoch,
    required int now,
    required int quietMilliseconds,
    required bool force,
  }) {
    transaction(() {
      final rows = _rows(
        'SELECT * FROM import_files WHERE source_id=? AND path=?',
        [source, path],
      );
      final old = rows.isEmpty ? null : rows.single;
      final changed =
          old == null ||
          old['size'] != size ||
          old['modified'] != modified ||
          old['status'] == 'missing';
      if (changed || (force && old['status'] != 'pending')) {
        _db.execute(
          '''INSERT INTO import_files(source_id,path,size,modified,epoch,status,ready_at)
          VALUES(?,?,?,?,?,'pending',?) ON CONFLICT(source_id,path) DO UPDATE SET
          size=excluded.size,modified=excluded.modified,epoch=excluded.epoch,
          native_id=CASE WHEN import_files.status='missing' THEN NULL ELSE import_files.native_id END,
          created=CASE WHEN import_files.status='missing' THEN NULL ELSE import_files.created END,
          status='pending',ready_at=excluded.ready_at,attempts=0,issue=NULL''',
          [source, path, size, modified, epoch, now + quietMilliseconds],
        );
      } else {
        _db.execute(
          'UPDATE import_files SET epoch=? WHERE source_id=? AND path=?',
          [epoch, source, path],
        );
      }
    });
  }

  List<Map<String, Object?>> importCandidates(int now) => _rows(
    "SELECT f.*,s.path AS root FROM import_files f JOIN sources s ON s.id=f.source_id WHERE f.status='pending' AND ready_at<=? AND f.epoch=json_extract(s.state,'\$.epoch') ORDER BY ready_at,f.source_id,f.path LIMIT 128",
    [now],
  );

  int get pendingImportCount =>
      _rows("SELECT count(*) AS n FROM import_files WHERE status='pending'")
              .single['n']
          as int;

  List<Map<String, Object?>> sourceImportCounts() => _rows(
    "SELECT source_id,status,epoch,count(*) AS count FROM import_files GROUP BY source_id,status,epoch",
  );

  void retryImport(
    String source,
    String path,
    int now,
    String issue, {
    bool unsupported = false,
  }) {
    transaction(() {
      final row = _rows(
        'SELECT attempts FROM import_files WHERE source_id=? AND path=?',
        [source, path],
      );
      if (row.isEmpty) return;
      final attempts = (row.single['attempts'] as int) + 1;
      final seconds = attempts == 1
          ? 5
          : attempts == 2
          ? 15
          : 60;
      _db.execute(
        'UPDATE import_files SET attempts=?,ready_at=?,status=?,issue=? WHERE source_id=? AND path=?',
        [
          attempts,
          now + seconds * 1000,
          unsupported ? 'unsupported' : 'pending',
          issue,
          source,
          path,
        ],
      );
    });
  }

  String commitImport({
    required String source,
    required String path,
    required String newId,
    required String? nativeId,
    required int created,
    required Map<String, Object?> observed,
  }) => transaction(() {
    final refs = nativeId == null
        ? <Map<String, Object?>>[]
        : _rows(
            "SELECT DISTINCT media_id FROM import_files WHERE native_id=? AND created=? AND status!='missing' AND media_id IS NOT NULL LIMIT 2",
            [nativeId, created],
          );
    final current = _rows(
      'SELECT * FROM import_files WHERE source_id=? AND path=?',
      [source, path],
    );
    if (current.isEmpty)
      throw const CatalogFailure(CatalogFailureCode.invalidRecord);
    final previousId = current.single['media_id'] as String?;
    String? id;
    if (refs.length == 1) id = refs.single['media_id'] as String;
    if (nativeId == null &&
        previousId != null &&
        current.single['status'] != 'missing' &&
        current.single['created'] == created) {
      final prior = mediaById(previousId);
      if (prior?['version'] == observed['version']) id = previousId;
    }
    id ??= newId;
    final previous = mediaById(id);
    final sameVersion = previous?['version'] == observed['version'];
    putMedia({
      ...?previous,
      ...observed,
      'id': id,
      'observedAt': previous?['observedAt'] ?? observed['observedAt'],
      'local': true,
      'deletedFromLibrary': false,
      'sourceMissing': false,
      'remoteVersionVerified': sameVersion
          ? (previous?['remoteVersionVerified'])
          : null,
    });
    _db.execute(
      "UPDATE import_files SET media_id=?,native_id=?,created=?,status='ready',issue=NULL,attempts=0 WHERE source_id=? AND path=?",
      [id, nativeId, created, source, path],
    );
    if (previousId != null && previousId != id) _refreshLocal(previousId);
    return id;
  });

  void _refreshLocal(String id) {
    final item = mediaById(id);
    if (item == null) return;
    final refs = _rows(
      "SELECT path FROM import_files WHERE media_id=? AND status!='missing' ORDER BY path LIMIT 1",
      [id],
    );
    putMedia({
      ...item,
      'local': refs.isNotEmpty,
      'sourceMissing': refs.isEmpty,
      if (refs.isNotEmpty) 'path': refs.single['path'],
    });
  }

  /// Bounded sweep, called only after a complete and accessible enumeration.
  int markMissingImportPage(String source, String epoch) => transaction(() {
    final rows = _rows(
      "SELECT path,media_id FROM import_files WHERE source_id=? AND epoch!=? AND status!='missing' LIMIT 100",
      [source, epoch],
    );
    for (final row in rows) {
      _db.execute(
        "UPDATE import_files SET status='missing',issue=NULL WHERE source_id=? AND path=?",
        [source, row['path']],
      );
      if (row['media_id'] case final String id) _refreshLocal(id);
    }
    return rows.length;
  });

  String? mediaRoot(String id, String path) {
    final refs = _rows(
      "SELECT s.path FROM sources s JOIN import_files f ON s.id=f.source_id WHERE f.media_id=? AND f.path=? AND f.status!='missing' LIMIT 1",
      [id, path],
    );
    return refs.isEmpty ? null : refs.single['path'] as String;
  }

  void markOriginalRemoved(String id, String path) => transaction(() {
    _db.execute(
      "UPDATE import_files SET status='missing',issue=NULL WHERE media_id=? AND path=?",
      [id, path],
    );
    _refreshLocal(id);
  });

  void markOriginalRestored(String id, String path) => transaction(() {
    _db.execute(
      "UPDATE import_files SET status='ready',issue=NULL WHERE media_id=? AND path=?",
      [id, path],
    );
    _refreshLocal(id);
    final record = mediaById(id);
    if (record != null)
      putMedia({
        ...record,
        'deletedFromLibrary': false,
        'autoUploadSuppressed': true,
        'pendingRemoteDeletion': null,
      });
  });

  List<Map<String, Object?>> livePhotoCandidates(String after) => _rows(
    "SELECT json_extract(body,'\$.sourceMetadata.appleContentIdentifier') AS pairing FROM media WHERE json_extract(body,'\$.local')=1 AND json_extract(body,'\$.kind') IN ('photo','video') AND json_extract(body,'\$.sourceMetadata.appleContentIdentifier')>? GROUP BY pairing HAVING count(*)=2 ORDER BY pairing LIMIT 100",
    [after],
  );

  List<Map<String, Object?>> livePhotoComponents(String pairing) =>
      _rows(
            "SELECT body FROM media WHERE json_extract(body,'\$.local')=1 AND json_extract(body,'\$.kind') IN ('photo','video') AND json_extract(body,'\$.sourceMetadata.appleContentIdentifier')=? ORDER BY id",
            [pairing],
          )
          .map(
            (row) => Map<String, Object?>.from(
              jsonDecode(row['body'] as String) as Map,
            ),
          )
          .toList();

  void saveLivePhoto(
    Map<String, Object?> composite,
    List<Map<String, Object?>> parts,
  ) => transaction(() {
    final firstPairing = mediaById(composite['id'] as String) == null;
    putMedia(composite);
    final id = composite['id'] as String;
    for (final part in parts) {
      putMedia({...part, 'pairedComponentOf': id});
      if (firstPairing)
        _db.execute(
          'INSERT OR IGNORE INTO album_members(album_id,media_id) SELECT album_id,? FROM album_members WHERE media_id=?',
          [id, part['id']],
        );
    }
  });

  void putMedia(Map<String, Object?> record) {
    _requireOpen();
    final id = record['id'];
    final observed = record['observedAt'];
    if (id is! String ||
        id.isEmpty ||
        observed is! int ||
        record['kind'] is! String) {
      throw const CatalogFailure(CatalogFailureCode.invalidRecord);
    }
    transaction(
      () => _db.execute(
        'INSERT INTO media(id, observed_at, body) VALUES (?, ?, ?) '
        'ON CONFLICT(id) DO UPDATE SET observed_at=excluded.observed_at, body=excluded.body',
        [id, observed, jsonEncode(record)],
      ),
    );
  }

  void putSource({
    required String id,
    required String path,
    Map<String, Object?> state = const {},
  }) {
    _requireOpen();
    if (id.isEmpty || path.isEmpty)
      throw const CatalogFailure(CatalogFailureCode.invalidRecord);
    transaction(
      () => _db.execute(
        'INSERT INTO sources(id, path, state) VALUES (?, ?, ?) '
        'ON CONFLICT(id) DO UPDATE SET path=excluded.path, state=excluded.state',
        [id, path, jsonEncode(state)],
      ),
    );
  }

  List<Map<String, Object?>> sources() =>
      _rows('SELECT id, path, state FROM sources ORDER BY id')
          .map(
            (row) => {
              ...row,
              'state': Map<String, Object?>.from(
                jsonDecode(row['state'] as String) as Map,
              ),
            },
          )
          .toList();

  void putAlbum({
    required String id,
    required String name,
    required bool hidden,
    required Iterable<String> members,
  }) {
    _requireOpen();
    if (id.isEmpty || name.trim().isEmpty)
      throw const CatalogFailure(CatalogFailureCode.invalidRecord);
    transaction(() {
      _db.execute(
        'INSERT INTO albums(id, name, hidden) VALUES (?, ?, ?) '
        'ON CONFLICT(id) DO UPDATE SET name=excluded.name, hidden=excluded.hidden',
        [id, name, hidden ? 1 : 0],
      );
      _db.execute('DELETE FROM album_members WHERE album_id=?', [id]);
      for (final mediaId in members.toSet()) {
        _db.execute(
          'INSERT INTO album_members(album_id, media_id) VALUES (?, ?)',
          [id, mediaId],
        );
      }
    });
  }

  List<Map<String, Object?>> albums() =>
      _rows('SELECT id, name, hidden FROM albums ORDER BY name, id');
  List<String> albumMembers(String id) => _rows(
    'SELECT media_id FROM album_members WHERE album_id=? ORDER BY media_id',
    [id],
  ).map((row) => row['media_id'] as String).toList();

  void deleteAlbum(String id) {
    _requireOpen();
    transaction(() => _db.execute('DELETE FROM albums WHERE id=?', [id]));
  }

  static const _namespaces = {'preferences', 'tracking', 'jobs', 'replicas'};
  void pruneRecordPrefix(String namespace, String prefix, String keepPrefix) {
    _requireOpen();
    if (!_namespaces.contains(namespace) ||
        prefix.isEmpty ||
        !keepPrefix.startsWith(prefix) ||
        keepPrefix == prefix)
      throw const CatalogFailure(CatalogFailureCode.invalidRecord);
    transaction(
      () => _db.execute(
        'DELETE FROM records WHERE namespace=? AND substr(id,1,?)=? AND substr(id,1,?)<>?',
        [namespace, prefix.length, prefix, keepPrefix.length, keepPrefix],
      ),
    );
  }

  int get cipherCacheBytes =>
      _rows(
            "SELECT coalesce(sum(json_extract(body,'\$.size')),0) AS n FROM records WHERE namespace='replicas' AND id LIKE 'cipher-cache:%'",
          ).single['n']
          as int;

  Map<String, Object?>? get oldestCipherCache {
    final rows = _rows(
      "SELECT body FROM records WHERE namespace='replicas' AND id LIKE 'cipher-cache:%' ORDER BY json_extract(body,'\$.usedAt'),id LIMIT 1",
    );
    return rows.isEmpty
        ? null
        : Map<String, Object?>.from(
            jsonDecode(rows.single['body'] as String) as Map,
          );
  }

  void putRecord(String namespace, String id, Map<String, Object?> body) {
    _requireOpen();
    if (!_namespaces.contains(namespace) || id.isEmpty)
      throw const CatalogFailure(CatalogFailureCode.invalidRecord);
    transaction(
      () => _db.execute(
        'INSERT INTO records(namespace, id, body) VALUES (?, ?, ?) '
        'ON CONFLICT(namespace, id) DO UPDATE SET body=excluded.body',
        [namespace, id, jsonEncode(body)],
      ),
    );
  }

  Map<String, Object?>? record(String namespace, String id) {
    _requireOpen();
    if (!_namespaces.contains(namespace))
      throw const CatalogFailure(CatalogFailureCode.invalidRecord);
    final rows = _rows('SELECT body FROM records WHERE namespace=? AND id=?', [
      namespace,
      id,
    ]);
    if (rows.isEmpty) return null;
    try {
      return Map<String, Object?>.from(
        jsonDecode(rows.single['body'] as String) as Map,
      );
    } catch (_) {
      throw const CatalogFailure(CatalogFailureCode.unreadable);
    }
  }

  List<Map<String, Object?>> recordPage(
    String namespace,
    String prefix, {
    String after = '',
    int limit = 100,
    bool descending = false,
    Set<String>? phases,
  }) {
    _requireOpen();
    if (!_namespaces.contains(namespace) ||
        prefix.isEmpty ||
        limit < 1 ||
        limit > 256) {
      throw const CatalogFailure(CatalogFailureCode.invalidRecord);
    }
    final boundary = after.isEmpty ? '' : ' AND id ${descending ? '<' : '>'} ?';
    final phaseFilter = phases == null
        ? ''
        : ' AND json_extract(body,\'\$.phase\') IN (${List.filled(phases.length, '?').join(',')})';
    return _rows(
          'SELECT id,body FROM records WHERE namespace=? AND substr(id,1,?)=?$boundary$phaseFilter ORDER BY id ${descending ? 'DESC' : 'ASC'} LIMIT ?',
          [
            namespace,
            prefix.length,
            prefix,
            if (after.isNotEmpty) after,
            ...?phases,
            limit,
          ],
        )
        .map(
          (row) => {
            'recordId': row['id'],
            'body': Map<String, Object?>.from(
              jsonDecode(row['body'] as String) as Map,
            ),
          },
        )
        .toList();
  }

  Map<String, int> recordPhaseCounts(String namespace, String prefix) {
    _requireOpen();
    if (!_namespaces.contains(namespace) || prefix.isEmpty) {
      throw const CatalogFailure(CatalogFailureCode.invalidRecord);
    }
    return {
      for (final row in _rows(
        "SELECT coalesce(json_extract(body,'\$.phase'),'unknown') AS phase,count(*) AS total FROM records WHERE namespace=? AND substr(id,1,?)=? GROUP BY phase",
        [namespace, prefix.length, prefix],
      ))
        row['phase'] as String: row['total'] as int,
    };
  }

  void deleteRecordPrefix(String namespace, String prefix) {
    _requireOpen();
    if (!_namespaces.contains(namespace) || prefix.isEmpty)
      throw const CatalogFailure(CatalogFailureCode.invalidRecord);
    transaction(
      () => _db.execute(
        'DELETE FROM records WHERE namespace=? AND substr(id,1,?)=?',
        [namespace, prefix.length, prefix],
      ),
    );
  }

  List<Map<String, Object?>> _rows(
    String sql, [
    List<Object?> arguments = const [],
  ]) {
    _requireOpen();
    try {
      return _db
          .select(sql, arguments)
          .map((row) => Map<String, Object?>.from(row))
          .toList();
    } catch (_) {
      throw const CatalogFailure(CatalogFailureCode.unreadable);
    }
  }

  void verifyIntegrity() {
    _requireOpen();
    try {
      if (_db.select('PRAGMA cipher_integrity_check').isNotEmpty ||
          _scalar(_db, 'PRAGMA integrity_check') != 'ok' ||
          _db.select('PRAGMA foreign_key_check').isNotEmpty) {
        throw const CatalogFailure(CatalogFailureCode.unreadable);
      }
    } catch (_) {
      throw const CatalogFailure(CatalogFailureCode.unreadable);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _unsubscribe?.call();
    _unsubscribe = null;
    _db.close();
  }

  static const _schema = '''
CREATE TABLE catalog_identity(vault_id TEXT NOT NULL, catalog_id TEXT NOT NULL);
CREATE TABLE sources(id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE);
CREATE TABLE media(id TEXT PRIMARY KEY, observed_at INTEGER NOT NULL,
  body TEXT NOT NULL CHECK(json_valid(body)));
CREATE INDEX media_observed ON media(observed_at DESC, id);
CREATE TABLE albums(id TEXT PRIMARY KEY, name TEXT NOT NULL,
  hidden INTEGER NOT NULL CHECK(hidden IN (0,1)));
CREATE TABLE album_members(album_id TEXT NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
  media_id TEXT NOT NULL REFERENCES media(id), PRIMARY KEY(album_id, media_id));
CREATE TABLE records(namespace TEXT NOT NULL, id TEXT NOT NULL,
  body TEXT NOT NULL CHECK(json_valid(body)), PRIMARY KEY(namespace, id));
''';
}
