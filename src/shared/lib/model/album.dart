class Album {
  Album({
    required this.id,
    required this.name,
    this.hiddenFromLibrary = false,
    Set<String>? members,
  }) : members = members ?? <String>{};

  final String id;
  String name;
  bool hiddenFromLibrary;
  final Set<String> members;
}
