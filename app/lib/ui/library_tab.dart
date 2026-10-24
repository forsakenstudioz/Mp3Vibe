import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../services/download_service.dart';
import '../services/library_service.dart';
import '../services/player_service.dart';
import '../services/taste_service.dart';
import 'widgets.dart';

enum _Sort { newest, title, artist }

class LibraryTab extends StatefulWidget {
  const LibraryTab({super.key});

  @override
  State<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends State<LibraryTab> {
  String _query = '';
  Mood? _mood;
  bool _likedOnly = false;
  _Sort _sort = _Sort.newest;

  @override
  Widget build(BuildContext context) {
    final lib = context.watch<LibraryService>();
    final taste = context.watch<TasteService>();
    var songs = lib.search(_query);
    if (_mood != null) songs = songs.where((s) => s.effectiveMood == _mood).toList();
    if (_likedOnly) songs = songs.where((s) => taste.isLiked(s.id)).toList();
    songs = List.of(songs);
    switch (_sort) {
      case _Sort.title:
        songs.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      case _Sort.artist:
        songs.sort((a, b) => a.artist.toLowerCase().compareTo(b.artist.toLowerCase()));
      case _Sort.newest:
        break;
    }

    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: SearchBar(
          hintText: 'Search ${lib.songs.length} songs',
          leading: const Icon(Icons.search_rounded),
          onChanged: (v) => setState(() => _query = v),
          trailing: [
            PopupMenuButton<_Sort>(
              icon: const Icon(Icons.sort_rounded),
              initialValue: _sort,
              onSelected: (v) => setState(() => _sort = v),
              itemBuilder: (_) => const [
                PopupMenuItem(value: _Sort.newest, child: Text('Newest first')),
                PopupMenuItem(value: _Sort.title, child: Text('Title A-Z')),
                PopupMenuItem(value: _Sort.artist, child: Text('Artist A-Z')),
              ],
            ),
          ],
        ),
      ),
      SizedBox(
        height: 48,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: FilterChip(label: const Text('♥ Liked'), selected: _likedOnly, onSelected: (v) => setState(() => _likedOnly = v)),
          ),
          for (final m in Mood.values)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: FilterChip(
                label: Text('${m.emoji} ${m.label}'),
                selected: _mood == m,
                onSelected: (v) => setState(() => _mood = v ? m : null),
              ),
            ),
        ]),
      ),
      if (songs.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Text('${songs.length} songs', style: Theme.of(context).textTheme.bodySmall),
            const Spacer(),
            TextButton.icon(
              icon: const Icon(Icons.download_rounded, size: 18),
              label: const Text('Download all'),
              onPressed: () => context.read<DownloadService>().downloadAll(songs),
            ),
            TextButton.icon(
              icon: const Icon(Icons.shuffle_rounded, size: 18),
              label: const Text('Shuffle'),
              onPressed: () {
                final shuffled = List.of(songs)..shuffle();
                context.read<PlayerService>().play(shuffled.first, list: shuffled);
              },
            ),
          ]),
        ),
      Expanded(
        child: songs.isEmpty
            ? const Center(child: Text('No songs match'))
            : ListView.builder(itemCount: songs.length, itemBuilder: (_, i) => SongTile(song: songs[i], list: songs)),
      ),
    ]);
  }
}
