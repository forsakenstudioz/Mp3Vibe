import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../services/connectivity_service.dart';
import '../services/download_service.dart';
import '../services/library_service.dart';
import '../services/player_service.dart';
import '../services/recommender.dart';
import '../services/taste_service.dart';
import 'widgets.dart';

class HomeTab extends StatefulWidget {
  const HomeTab({super.key});

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  List<Song>? _forYou;
  int _libraryVersion = -1;

  @override
  Widget build(BuildContext context) {
    final lib = context.watch<LibraryService>();
    final taste = context.read<TasteService>();
    final online = context.watch<ConnectivityService>().online;
    final downloads = context.watch<DownloadService>();
    final player = context.read<PlayerService>();
    final pool = online ? lib.songs : lib.songs.where((s) => downloads.isDownloaded(s.id)).toList();

    // Pick "for you" once per library change, not on every rebuild.
    if (_forYou == null || _libraryVersion != pool.length) {
      _forYou = context.read<Recommender>().forYou(pool, count: 12);
      _libraryVersion = pool.length;
    }
    final recent = taste.history.take(12).map(lib.byId).whereType<Song>().toList();

    if (lib.songs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: lib.loading
              ? const CircularProgressIndicator()
              : Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.library_music_rounded, size: 64),
                  const SizedBox(height: 16),
                  Text(lib.error ?? 'No songs yet', style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  const Text('Start the sync program on your laptop and add songs to your music folder. They show up here automatically.',
                      textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  FilledButton.tonal(onPressed: lib.refresh, child: const Text('Refresh')),
                ]),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: lib.refresh,
      child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        if (!online)
          const MaterialBanner(
            content: Text('Offline. Playing from your downloads.'),
            leading: Icon(Icons.cloud_off_rounded),
            actions: [SizedBox.shrink()],
          ),
        const SectionHeader("What's the vibe?"),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: LayoutBuilder(builder: (context, c) {
            final cols = c.maxWidth > 900 ? 6 : (c.maxWidth > 560 ? 3 : 2);
            return GridView.count(
              crossAxisCount: cols,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 2.3,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              children: [for (final m in Mood.values) _MoodCard(mood: m, onTap: () => player.playMood(m))],
            );
          }),
        ),
        if (lib.justAdded.isNotEmpty) ...[
          const SectionHeader('Just added from your laptop'),
          _Shelf(songs: lib.justAdded.take(12).toList()),
        ],
        if (_forYou!.isNotEmpty) ...[
          SectionHeader('Picked for you',
              action: IconButton(
                icon: const Icon(Icons.refresh_rounded),
                tooltip: 'New picks',
                onPressed: () => setState(() => _forYou = null),
              )),
          _Shelf(songs: _forYou!),
        ],
        if (recent.isNotEmpty) ...[
          const SectionHeader('Recently played'),
          _Shelf(songs: recent),
        ],
        const SectionHeader('Newest in your library'),
        for (final s in pool.take(15)) SongTile(song: s, list: pool),
      ]),
    );
  }
}

class _MoodCard extends StatelessWidget {
  const _MoodCard({required this.mood, required this.onTap});
  final Mood mood;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Ink(
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [mood.color, mood.color.withValues(alpha: 0.45)]),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(children: [
              Text(mood.emoji, style: const TextStyle(fontSize: 26)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(mood.label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.white)),
                  Text(mood.blurb, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.white70)),
                ]),
              ),
            ]),
          ),
        ),
      );
}

class _Shelf extends StatelessWidget {
  const _Shelf({required this.songs});
  final List<Song> songs;

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerService>();
    return SizedBox(
      height: 190,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: songs.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, i) {
          final s = songs[i];
          return GestureDetector(
            onTap: () => player.play(s, list: songs),
            onLongPress: () => showSongOptions(context, s),
            child: SizedBox(
              width: 136,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                CoverArt(s, size: 136, radius: 12),
                const SizedBox(height: 6),
                Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(s.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ]),
            ),
          );
        },
      ),
    );
  }
}
