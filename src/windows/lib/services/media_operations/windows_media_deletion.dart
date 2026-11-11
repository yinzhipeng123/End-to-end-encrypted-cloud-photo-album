import 'package:encrypted_photo_shared/security/vault_crypto.dart';
import 'package:encrypted_photo_shared/sync/sync_format.dart';
import 'package:encrypted_photo_app/sync/windows_sync_service.dart';
import 'package:encrypted_photo_app/services/library/library_organization_service.dart';
import 'package:encrypted_photo_app/services/import/windows_import_service.dart';
import 'package:encrypted_photo_app/services/import/windows_source_reader.dart';

enum MediaDeletionScope { local, repository, all }

/// User-authorized deletion intent is committed before any actual side effect.
/// Local removal is reversible; remote history is never force-rewritten.
final class WindowsMediaDeletion {
  WindowsMediaDeletion(this.imports, this.organization, this.sync);
  final WindowsImportService imports;
  final LibraryOrganizationService organization;
  final WindowsSyncService? sync;

  Future<void> remove(
    String id,
    MediaDeletionScope scope,
    SourceCancellation token,
  ) async {
    final db = organization.catalog;
    final query = organization.query;
    void check() {
      token.check();
      organization.catalog;
      if (query != organization.query)
        throw const SourceFailure(SourceFailureCode.cancelled);
    }

    check();
    if (db.queryIds(query, within: [id]).isEmpty)
      throw const SourceFailure(SourceFailureCode.unavailable);
    final media = db.mediaById(id)!;
    final version = media['version'] as String;
    final target = sync?.targetKey;
    if (sync == null || target == null || !sync!.initialized) {
      throw const SourceFailure(SourceFailureCode.unavailable);
    }
    final key = 'delete-intent:${scope.name}:$target:$id:$version';
    var job = db.record('jobs', key);
    // A completed/cancelled intent belongs to an earlier user action. The same
    // original version may have been restored or explicitly uploaded since.
    if (job?['phase'] == 'complete' || job?['phase'] == 'cancelled') job = null;
    final crypto = await VaultCrypto.load();
    check();
    job ??= {
      'operationId': SyncFormat.newId(crypto),
      'mediaId': id,
      'version': version,
      'scope': scope.name,
      'target': target,
      'localDone': media['local'] != true,
      'remoteDone': scope == MediaDeletionScope.local,
      'phase': 'prepared',
    };
    db.putRecord('jobs', key, job);
    void save(Map<String, Object?> updates) {
      job = {...job!, ...updates};
      db.putRecord('jobs', key, job!);
    }

    try {
      if (scope == MediaDeletionScope.local) {
        if (sync == null || sync!.receipt(id) == null) {
          throw const SourceFailure(SourceFailureCode.unavailable);
        }
        // Read and authenticate every required resource immediately before
        // removing the source; a stale 'verified' flag is insufficient.
        await sync!.readRemoteOriginal(id, version, token, (_, __) async {});
      } else if (scope == MediaDeletionScope.repository) {
        if (media['local'] != true)
          throw const SourceFailure(SourceFailureCode.unavailable);
        await imports.readLocalOriginal(id, version, token, (_) async {});
      }
      check();
      if (scope != MediaDeletionScope.repository && job!['localDone'] != true) {
        await imports.recycleOriginal(
          id,
          version,
          job!['operationId'] as String,
          token,
        );
        check();
        save({'localDone': true, 'phase': 'local-removed'});
      }
      if (scope != MediaDeletionScope.local && job!['remoteDone'] != true) {
        if (sync == null || sync!.targetKey != target)
          throw const SourceFailure(SourceFailureCode.changed);
        await sync!.deleteRemoteOriginal(
          id,
          version,
          job!['operationId'] as String,
          scope == MediaDeletionScope.all ? 'all' : 'repository',
          token,
        );
        check();
        save({'remoteDone': true});
      }
      check();
      db.transaction(() {
        final current = db.mediaById(id);
        if (current != null && scope != MediaDeletionScope.local) {
          db.putMedia({
            ...current,
            'autoUploadSuppressed': true,
            'deletedFromLibrary': current['local'] != true,
          });
        }
        save({'phase': 'complete', 'failure': null});
      });
      organization.refresh();
    } catch (_) {
      try {
        save({'phase': 'incomplete', 'failure': '需检查连接、源文件版本及副本后重试；已完成的部分保留。'});
      } catch (_) {}
      rethrow;
    }
  }
}
