enum AlbumBindingStatus { active, stopped, detached }

class AlbumSourceObservation {
  AlbumSourceObservation({
    required this.sourceId,
    required this.systemName,
    this.generation = 0,
    this.exists = true,
  });
  final String sourceId;
  String systemName;
  int generation;
  bool exists;
}

class AlbumSourceBinding {
  AlbumSourceBinding({
    required this.sourceId,
    required this.albumId,
    required this.generation,
    required Set<String> systemMembers,
    this.status = AlbumBindingStatus.active,
    Set<String>? added,
    Set<String>? removed,
  }) : systemMembers = Set.of(systemMembers),
       added = added ?? <String>{},
       removed = removed ?? <String>{};

  final String sourceId;
  final String albumId;
  final int generation;
  AlbumBindingStatus status;
  Set<String> systemMembers;
  final Set<String> added;
  final Set<String> removed;

  Set<String> get effectiveMembers =>
      {...systemMembers, ...added}..removeAll(removed);

  void setMember(String mediaId, bool included) {
    if (included) {
      removed.remove(mediaId);
      added.add(mediaId);
    } else {
      added.remove(mediaId);
      removed.add(mediaId);
    }
  }
}
