import 'package:flutter/material.dart';

import '../model/demo_store.dart';
import 'components.dart';
import 'dialogs.dart';
import 'library_screen.dart';
import 'settings_screen.dart';
import 'sync_screen.dart';

import 'package:encrypted_photo_app/ui/theme.dart';

enum AppPage { library, favorites, albums, sync, settings }

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.store});
  final DemoStore store;
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final _scaffold = GlobalKey<ScaffoldState>();
  final _search = TextEditingController();
  AppPage _page = AppPage.library;
  String? _album;
  String _query = '';
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _navigate(AppPage page, [String? album]) {
    setState(() {
      _page = page;
      _album = album;
      _query = '';
      _search.clear();
    });
    if (_scaffold.currentState?.isDrawerOpen ?? false) Navigator.pop(context);
  }

  String get _title =>
      widget.store.albumById(_album)?.name ??
      switch (_page) {
        AppPage.library => '所有照片',
        AppPage.favorites => '我的收藏',
        AppPage.albums => '我的相册',
        AppPage.sync => '同步中心',
        AppPage.settings => '偏好设置',
      };

  Widget _sidebar() {
    final store = widget.store;
    return Container(
      width: 236,
      color: AppColors.pine,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(26, 30, 22, 36),
              child: Row(
                children: [
                  VaultMark(dark: true),
                  SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '密屿',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 5,
                        ),
                      ),
                      Text(
                        'MIYU PHOTOS',
                        style: TextStyle(
                          color: Color(0xFFADBFAF),
                          fontSize: 8,
                          letterSpacing: 1,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(left: 14, bottom: 12),
                      child: Text(
                        '我的图库',
                        style: TextStyle(
                          color: Color(0xFF9EB5A6),
                          fontSize: 10,
                          letterSpacing: 2,
                        ),
                      ),
                    ),
                    _navItem(
                      Icons.grid_view_rounded,
                      '所有照片',
                      AppPage.library,
                      count: '${store.visibleCount}',
                    ),
                    _navItem(
                      Icons.favorite_border_rounded,
                      '我的收藏',
                      AppPage.favorites,
                      count: '${store.favoriteCount}',
                    ),
                    _navItem(
                      Icons.photo_album_outlined,
                      '我的相册',
                      AppPage.albums,
                    ),
                    _navItem(
                      Icons.sync_rounded,
                      '同步中心',
                      AppPage.sync,
                      count: store.pending.isEmpty
                          ? null
                          : '${store.pending.length}',
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 18,
                      ),
                      child: Divider(color: Color(0xFF406356), height: 1),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 14, bottom: 12),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              '相册集',
                              style: TextStyle(
                                color: Color(0xFF9EB5A6),
                                fontSize: 10,
                                letterSpacing: 2,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: '新建相册',
                            visualDensity: VisualDensity.compact,
                            onPressed: () =>
                                showCreateAlbumDialog(context, store),
                            icon: const Icon(
                              Icons.add,
                              size: 17,
                              color: Color(0xFFB6C6BA),
                            ),
                          ),
                        ],
                      ),
                    ),
                    for (final album in store.albums)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () => _navigate(AppPage.library, album.id),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 15,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: _album == album.id
                                  ? const Color(0xFF365F4D)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.folder_outlined,
                                  size: 17,
                                  color: Color(0xFF9EB5A6),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    album.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Color(0xFFCCD8CD),
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(15),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2E5848),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFF436858)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            const Icon(
                              Icons.science_outlined,
                              size: 15,
                              color: const Color(0xFFCFD8B9),
                            ),
                            const SizedBox(width: 8),
                            const Text(
                              '交互原型',
                              style: const TextStyle(
                                color: const Color(0xFFE2E6CE),
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          store.previewMode
                              ? '本机来源仅在内存预览\n尚未加密或上传'
                              : '内置样片演示\n不会上传或删除真实照片',
                          style: const TextStyle(
                            color: const Color(0xFFB7C6B9),
                            fontSize: 10,
                            height: 1.8,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _navItem(Icons.tune_rounded, '偏好设置', AppPage.settings),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _navItem(IconData icon, String title, AppPage page, {String? count}) {
    final selected = _page == page && _album == null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _navigate(page),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFE3E9D7) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 19,
                color: selected ? AppColors.pine : const Color(0xFFB6C8BA),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: selected ? AppColors.pine : const Color(0xFFD3DED5),
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              if (count != null)
                Text(
                  count,
                  style: TextStyle(
                    fontSize: 11,
                    color: selected ? AppColors.green : const Color(0xFF9BB3A4),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final desktop = constraints.maxWidth >= 900;
      final showSearch = constraints.maxWidth >= 1160;
      final store = widget.store;
      return Scaffold(
        key: _scaffold,
        drawer: desktop ? null : Drawer(width: 236, child: _sidebar()),
        body: Row(
          children: [
            if (desktop) _sidebar(),
            Expanded(
              child: Column(
                children: [
                  Container(
                    height: 75,
                    padding: EdgeInsets.symmetric(
                      horizontal: desktop ? 32 : 16,
                    ),
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      border: Border(bottom: BorderSide(color: AppColors.line)),
                    ),
                    child: Row(
                      children: [
                        if (!desktop) ...[
                          IconButton(
                            tooltip: '打开导航',
                            onPressed: () =>
                                _scaffold.currentState?.openDrawer(),
                            icon: const Icon(Icons.menu),
                          ),
                          const SizedBox(width: 10),
                        ],
                        const Text(
                          '我的空间',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.muted,
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 12),
                          child: Text(
                            '/',
                            style: TextStyle(color: AppColors.line),
                          ),
                        ),
                        Text(
                          _album != null ? '相册' : _title,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const Spacer(),
                        if (showSearch &&
                            (_page == AppPage.library ||
                                _page == AppPage.favorites))
                          SizedBox(
                            width: 270,
                            height: 40,
                            child: TextField(
                              key: const ValueKey('photo-search'),
                              controller: _search,
                              onChanged: (value) =>
                                  setState(() => _query = value),
                              style: const TextStyle(fontSize: 12),
                              decoration: const InputDecoration(
                                hintText: '搜索原文件名…',
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                prefixIcon: Icon(Icons.search, size: 18),
                              ),
                            ),
                          ),
                        const SizedBox(width: 18),
                        if (constraints.maxWidth >= 600)
                          const Pill('本地演示', icon: Icons.circle_outlined),
                        const SizedBox(width: 10),
                        IconButton(
                          tooltip: '锁定应用',
                          onPressed: store.lock,
                          icon: const Icon(
                            Icons.lock_outline_rounded,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const CircleAvatar(
                          radius: 17,
                          backgroundColor: AppColors.sage,
                          child: Text(
                            '我',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.green,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      key: PageStorageKey('${_page.name}/$_album'),
                      padding: EdgeInsets.all(desktop ? 32 : 20),
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 1440),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          _title,
                                          style: Theme.of(context)
                                              .textTheme
                                              .headlineLarge,
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          switch (_page) {
                                            AppPage.library =>
                                              _album == null
                                                  ? '让每一段回忆，只属于你。'
                                                  : '把喜欢的瞬间，慢慢收集。',
                                            AppPage.favorites =>
                                              '那些让你忍不住再看一眼的瞬间。',
                                            AppPage.albums => '为不同的故事，留一个位置。',
                                            AppPage.sync => '每一次同步，都有迹可循。',
                                            AppPage.settings => '按你的习惯，照顾你的回忆。',
                                          },
                                          style: const TextStyle(
                                            color: AppColors.muted,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (_page == AppPage.library ||
                                      _page == AppPage.favorites)
                                    FilledButton.icon(
                                      onPressed: () =>
                                          showImportDialog(context, store),
                                      icon: const Icon(Icons.add, size: 18),
                                      label: const Text('导入照片'),
                                    ),
                                  if (_page == AppPage.albums)
                                    FilledButton.icon(
                                      onPressed: () =>
                                          showCreateAlbumDialog(context, store),
                                      icon: const Icon(Icons.add, size: 18),
                                      label: const Text('新建相册'),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 28),
                              if (_page == AppPage.library ||
                                  _page == AppPage.favorites) ...[
                                if (!showSearch) ...[
                                  TextField(
                                    controller: _search,
                                    onChanged: (value) =>
                                        setState(() => _query = value),
                                    decoration: const InputDecoration(
                                      hintText: '搜索原文件名…',
                                      prefixIcon: Icon(Icons.search),
                                    ),
                                  ),
                                  const SizedBox(height: 18),
                                ],
                                LibraryScreen(
                                  store: store,
                                  query: _query,
                                  favoritesOnly: _page == AppPage.favorites,
                                  album: _album,
                                  onOpenSync: () => _navigate(AppPage.sync),
                                ),
                              ],
                              if (_page == AppPage.albums)
                                AlbumsScreen(
                                  store: store,
                                  onOpenAlbum: (album) =>
                                      _navigate(AppPage.library, album),
                                ),
                              if (_page == AppPage.sync)
                                SyncScreen(store: store),
                              if (_page == AppPage.settings)
                                SettingsScreen(store: store),
                              const SizedBox(height: 26),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Container(
                    height: 30,
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      border: Border(top: BorderSide(color: AppColors.line)),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.science_outlined,
                          size: 12,
                          color: AppColors.muted,
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            store.previewMode
                                ? '本机预览 · 加密索引待实现，关闭后需重新导入'
                                : '原型演示 · 数据仅保留在本次会话',
                            style: const TextStyle(
                              fontSize: 10,
                              color: AppColors.muted,
                            ),
                          ),
                        ),
                        if (constraints.maxWidth >= 600)
                          const Text(
                            'WINDOWS  ·  v0.1.0',
                            style: TextStyle(
                              fontSize: 9,
                              letterSpacing: 1,
                              color: AppColors.muted,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}
