class HomeContentRefresh {
  const HomeContentRefresh({
    required this.syncMatches,
    required this.syncChats,
  });

  final Future<void> Function() syncMatches;
  final Future<void> Function() syncChats;

  Future<void> run() async {
    await Future.wait([syncMatches(), syncChats()]);
  }
}
