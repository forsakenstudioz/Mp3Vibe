import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../services/download_service.dart';
import '../services/player_service.dart';
import '../services/taste_service.dart';
import 'widgets.dart';

void openNowPlaying(BuildContext context) {
  Navigator.of(context).push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const NowPlayingScreen()));
}

class NowPlayingScreen extends StatelessWidget {
  const NowPlayingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    final song = player.current;
    final wide = MediaQuery.sizeOf(context).width > 900;
    if (song == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('Nothing playing')));
    }
    final color = song.effectiveMood?.color ?? Theme.of(context).colorScheme.primary;
    final controls = _Controls(song: song);
    final queue = _UpNext(player: player);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.keyboard_arrow_down_rounded), onPressed: () => Navigator.pop(context)),
        title: Text(player.inRoom ? 'Playing in room' : 'Now playing'),
        backgroundColor: Colors.transparent,
      ),
      extendBodyBehindAppBar: true,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [color.withValues(alpha: 0.35), Theme.of(context).colorScheme.surface],
            begin: Alignment.topCenter,
            end: Alignment.center,
          ),
        ),
        child: SafeArea(
          child: wide
              ? Row(children: [
                  Expanded(flex: 3, child: controls),
                  const VerticalDivider(width: 1),
                  Expanded(flex: 2, child: queue),
                ])
              : ListView(children: [controls, const Divider(), SizedBox(height: 420, child: queue)]),
        ),
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.song});
  final Song song;

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    final taste = context.watch<TasteService>();
    final downloads = context.watch<DownloadService>();
    final liked = taste.isLiked(song.id);
    final artSize = (MediaQuery.sizeOf(context).shortestSide * 0.7).clamp(180.0, 380.0);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        CoverArt(song, size: artSize, radius: 20),
        const SizedBox(height: 24),
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(song.title, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold), maxLines: 2),
              Text(song.artist, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ]),
          ),
          IconButton(
            icon: Icon(liked ? Icons.favorite_rounded : Icons.favorite_border_rounded, color: liked ? Colors.pinkAccent : null),
            onPressed: () => taste.toggleLike(song),
          ),
          IconButton(
            icon: Icon(downloads.isDownloaded(song.id) ? Icons.download_done_rounded : Icons.download_rounded),
            onPressed: downloads.isDownloaded(song.id) ? null : () => downloads.download(song),
          ),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          if (song.effectiveMood != null)
            ActionChip(
              avatar: Text(song.effectiveMood!.emoji),
              label: Text(song.effectiveMood!.label),
              onPressed: () => pickMood(context, song),
            ),
          if (song.bpm != null) Chip(label: Text('${song.bpm!.round()} BPM')),
        ]),
        const SizedBox(height: 8),
        StreamBuilder<Duration>(
          stream: player.positionStream,
          builder: (context, snap) {
            final pos = snap.data ?? Duration.zero;
            final total = player.duration ?? song.duration;
            final max = total.inMilliseconds.toDouble().clamp(1.0, double.infinity);
            return Column(children: [
              Slider(
                value: pos.inMilliseconds.toDouble().clamp(0, max),
                max: max,
                onChanged: (v) => player.seek(Duration(milliseconds: v.round())),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text(formatDuration(pos)),
                  Text(formatDuration(total)),
                ]),
              ),
            ]);
          },
        ),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          IconButton(iconSize: 40, icon: const Icon(Icons.skip_previous_rounded), onPressed: player.previous),
          const SizedBox(width: 16),
          IconButton.filled(
            iconSize: 56,
            icon: Icon(player.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
            onPressed: player.toggle,
          ),
          const SizedBox(width: 16),
          IconButton(iconSize: 40, icon: const Icon(Icons.skip_next_rounded), onPressed: player.next),
        ]),
      ]),
    );
  }
}

class _UpNext extends StatelessWidget {
  const _UpNext({required this.player});
  final PlayerService player;

  @override
  Widget build(BuildContext context) {
    final upNext = player.upNext;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
        child: Row(children: [
          Text('Up next', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
          const Spacer(),
          if (!player.inRoom) ...[
            const Text('Smart queue'),
            Switch(value: player.smartQueue, onChanged: player.setSmartQueue),
          ],
        ]),
      ),
      if (!player.inRoom)
        SizedBox(
          height: 44,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: ChoiceChip(label: const Text('Follow the song'), selected: player.activeMood == null, onSelected: (_) => player.setMood(null)),
            ),
            for (final m in Mood.values)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: ChoiceChip(
                  label: Text('${m.emoji} ${m.label}'),
                  selected: player.activeMood == m,
                  onSelected: (_) => player.setMood(m),
                ),
              ),
          ]),
        ),
      Expanded(
        child: upNext.isEmpty
            ? const Center(child: Text('Queue is empty'))
            : ListView.builder(
                itemCount: upNext.length,
                itemBuilder: (context, i) => SongTile(
                  song: upNext[i],
                  onTap: () => player.play(upNext[i], list: upNext),
                  trailing: player.inRoom
                      ? null
                      : IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => player.removeFromQueue(i)),
                ),
              ),
      ),
    ]);
  }
}
