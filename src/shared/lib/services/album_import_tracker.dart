import 'package:encrypted_photo_shared/model/album.dart';
import 'package:encrypted_photo_shared/model/album_source_binding.dart';

class SystemAlbumSnapshot {
  const SystemAlbumSnapshot(this.id, this.name, this.members);
  final String id;
  final String name;
  final Set<String> members;
}

/// 纯状态转换；平台读取、持久化事务由适配层负责，不写入系统相册。
class AlbumImportTracker {
  AlbumImportTracker(this.albums);
  final List<Album> albums;
  final Map<String, AlbumSourceObservation> observations = {};
  final List<AlbumSourceBinding> bindings = [];

  AlbumSourceBinding? activeFor(String sourceId) => bindings
      .where(
        (b) => b.sourceId == sourceId && b.status == AlbumBindingStatus.active,
      )
      .firstOrNull;
  AlbumSourceBinding? bindingFor(String albumId) => bindings
      .where(
        (b) => b.albumId == albumId && b.status == AlbumBindingStatus.active,
      )
      .firstOrNull;

  void reconcile(
    List<SystemAlbumSnapshot> snapshots, {
    required bool complete,
  }) {
    // 不完整的相册快照不能用于推断改名、删除或成员被移出。
    if (!complete) return;
    final current = {for (final s in snapshots) s.id};
    for (final observation in observations.values) {
      if (!current.contains(observation.sourceId) && observation.exists) {
        activeFor(observation.sourceId)?.status = AlbumBindingStatus.detached;
        observation.exists = false;
      }
    }
    for (final snapshot in snapshots) {
      final old = observations[snapshot.id];
      if (old == null) {
        observations[snapshot.id] = AlbumSourceObservation(
          sourceId: snapshot.id,
          systemName: snapshot.name,
        );
        _create(snapshot);
      } else if (old.systemName != snapshot.name || !old.exists) {
        activeFor(snapshot.id)?.status = AlbumBindingStatus.detached;
        old.systemName = snapshot.name;
        old.exists = true;
        _create(snapshot);
      } else {
        final binding = activeFor(snapshot.id);
        if (binding != null) {
          binding.systemMembers = Set.of(snapshot.members);
          _publish(binding);
        }
      }
    }
  }

  String importManually(SystemAlbumSnapshot snapshot) {
    final active = activeFor(snapshot.id);
    if (active != null &&
        observations[snapshot.id]?.systemName == snapshot.name) {
      return active.albumId;
    }
    active?.status = AlbumBindingStatus.detached;
    observations.putIfAbsent(
        snapshot.id,
        () => AlbumSourceObservation(
          sourceId: snapshot.id,
          systemName: snapshot.name,
        ),
      )
      ..systemName = snapshot.name
      ..exists = true;
    return _create(snapshot).albumId;
  }

  AlbumSourceBinding _create(SystemAlbumSnapshot snapshot) {
    final observation = observations[snapshot.id]!;
    observation.generation++;
    final id = 'ios:${snapshot.id}:${observation.generation}';
    final binding = AlbumSourceBinding(
      sourceId: snapshot.id,
      albumId: id,
      generation: observation.generation,
      systemMembers: snapshot.members,
    );
    bindings.add(binding);
    albums.add(
      Album(id: id, name: snapshot.name, members: Set.of(snapshot.members)),
    );
    return binding;
  }

  void setMember(String albumId, String mediaId, bool included) {
    final binding = bindingFor(albumId);
    if (binding != null) {
      binding.setMember(mediaId, included);
      _publish(binding);
    } else {
      final album = albums.where((a) => a.id == albumId).firstOrNull;
      if (included) {
        album?.members.add(mediaId);
      } else {
        album?.members.remove(mediaId);
      }
    }
  }

  void deleteAlbum(String albumId) {
    bindingFor(albumId)?.status = AlbumBindingStatus.stopped;
    albums.removeWhere((a) => a.id == albumId);
  }

  void _publish(AlbumSourceBinding binding) {
    final album = albums.where((a) => a.id == binding.albumId).firstOrNull;
    if (album == null) return;
    album.members
      ..clear()
      ..addAll(binding.effectiveMembers);
  }

  void reset() {
    observations.clear();
    bindings.clear();
  }
}
