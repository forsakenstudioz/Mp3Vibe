import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../services/download_service.dart';
import '../services/library_service.dart';
import '../services/player_service.dart';
import '../services/recommender.dart';
import '../services/taste_service.dart';
import '../services/url_signer.dart';
import 'now_playing.dart';

class CoverArt extends StatelessWidget {
  const CoverArt(this.song, {super.key, this.size = 48, this.radius = 8});

  final Song? song;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final s = song;
    final fallback = _Placeholder(song: s, size: size);
    Widget child = fallback;
    if (s != null) {
      final local = context.watch<DownloadService>().localCover(s);
      if (local != null) {
        child = Image.file(local, width: size, height: size, fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback);
      } else if (s.coverKey != null) {
        child = FutureBuilder<String?>(
          future: context.read<UrlSigner>().urlFor(s.coverKey!),
          builder: (context, snap) => snap.data == null
              ? fallback
              : CachedNetworkImage(
                  imageUrl: snap.data!,
                  cacheKey: s.coverKey, // stable even though signed links change
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                  placeholder: (_, _) => fallback,
                  errorWidget: (_, _, _) => fallback,
                ),
        );
      }
    }
    return ClipRRect(borderRadius: BorderRadius.circular(radius), child: SizedBox(width: size, height: size, child: child));
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.song, required this.size});
  final Song? song;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = song?.effectiveMood?.color ?? Theme.of(context).colorScheme.primary;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [color.withValues(alpha: 0.85), color.withValues(alpha: 0.35)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      alignment: Alignment.center,
      child: Icon(Icons.music_note_rounded, size: size * 0.45, color: Colors.white70),
    );
  }
}

class MoodBadge extends StatelessWidget {
  const MoodBadge(this.mood, {super.key});
  final Mood mood;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(color: mood.color.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(6)),
        child: Text('${mood.emoji} ${mood.label}', style: TextStyle(fontSize: 11, color: mood.color)),
      );
}

class SongTile extends StatelessWidget {
  const SongTile({super.key, required this.song, this.list, this.onTap, this.trailing});

  final Song song;
  final List<Song>? list;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    final downloads = context.watch<DownloadService>();
    final isCurrent = player.current?.id == song.id;
    final progress = downloads.progress[song.id];
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: CoverArt(song),
      title: Text(song.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: isCurrent ? scheme.primary : null, fontWeight: isCurrent ? FontWeight.w600 : null)),
      subtitle: Row(children: [
        if (downloads.isDownloaded(song.id))
          Padding(padding: const EdgeInsets.only(right: 4), child: Icon(Icons.download_done_rounded, size: 14, color: scheme.primary)),
        if (progress != null)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, value: progress == 0 ? null : progress)),
          ),
        Flexible(child: Text(song.artist, maxLines: 1, overflow: TextOverflow.ellipsis)),
        if (song.effectiveMood != null) ...[const SizedBox(width: 6), MoodBadge(song.effectiveMood!)],
      ]),
      trailing: trailing ??
          IconButton(icon: const Icon(Icons.more_vert_rounded), onPressed: () => showSongOptions(context, song)),
      onTap: onTap ?? () => player.play(song, list: list),
      onLongPress: () => showSongOptions(context, song),
    );
  }
}

Future<void> showSongOptions(BuildContext context, Song song) {
  return showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      final taste = ctx.watch<TasteService>();
      final downloads = ctx.watch<DownloadService>();
      final player = ctx.read<PlayerService>();
      final liked = taste.isLiked(song.id);
      return SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: CoverArt(song), title: Text(song.title), subtitle: Text(song.artist)),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.queue_music_rounded),
            title: Text(player.inRoom ? 'Add to room queue' : 'Play next'),
            onTap: () {
              player.enqueue(song);
              Navigator.pop(ctx);
            },
          ),
          ListTile(
            leading: Icon(liked ? Icons.favorite_rounded : Icons.favorite_border_rounded, color: liked ? Colors.pinkAccent : null),
            title: Text(liked ? 'Unlike' : 'Like'),
            onTap: () => taste.toggleLike(song),
          ),
          ListTile(
            leading: const Icon(Icons.auto_awesome_rounded),
            title: const Text('Play similar songs'),
            onTap: () {
              final lib = ctx.read<LibraryService>();
              final similar = ctx.read<Recommender>().similar(lib.songs, song);
              player.play(song, list: [song, ...similar]);
              Navigator.pop(ctx);
            },
          ),
          if (downloads.isDownloaded(song.id))
            ListTile(leading: const Icon(Icons.delete_outline_rounded), title: const Text('Remove download'), onTap: () => downloads.remove(song))
          else
            ListTile(
              leading: const Icon(Icons.download_rounded),
              title: Text(downloads.isDownloading(song.id) ? 'Downloading...' : 'Download for offline'),
              onTap: () => downloads.download(song),
            ),
          ListTile(
            leading: const Icon(Icons.mood_rounded),
            title: const Text('Change mood'),
            subtitle: Text('Currently ${song.effectiveMood?.label ?? 'unknown'}${song.moodOverride != null ? ' (set by you)' : ''}'),
            onTap: () {
              Navigator.pop(ctx);
              pickMood(context, song);
            },
          ),
        ]),
      );
    },
  );
}

Future<void> pickMood(BuildContext context, Song song) async {
  final lib = context.read<LibraryService>();
  final picked = await showDialog<Object>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Text('Mood of "${song.title}"'),
      children: [
        for (final m in Mood.values)
          SimpleDialogOption(onPressed: () => Navigator.pop(ctx, m), child: Text('${m.emoji}  ${m.label}')),
        if (song.moodOverride != null)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'auto'),
            child: Text('Use automatic (${song.mood?.label ?? 'unknown'})'),
          ),
      ],
    ),
  );
  if (picked is Mood) await lib.setMoodOverride(song, picked);
  if (picked == 'auto') await lib.setMoodOverride(song, null);
}

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    final song = player.current;
    if (song == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      child: InkWell(
        onTap: () => openNowPlaying(context),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          StreamBuilder<Duration>(
            stream: player.positionStream,
            builder: (context, snap) {
              final total = player.duration?.inMilliseconds ?? song.durationMs;
              final v = total > 0 ? (snap.data?.inMilliseconds ?? 0) / total : 0.0;
              return LinearProgressIndicator(value: v.clamp(0.0, 1.0), minHeight: 2);
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(children: [
              CoverArt(song, size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(player.inRoom ? '🎧 In a room · ${song.artist}' : song.artist,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
                ]),
              ),
              IconButton(
                icon: Icon(player.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 32),
                onPressed: player.toggle,
              ),
              IconButton(icon: const Icon(Icons.skip_next_rounded), onPressed: player.next),
            ]),
          ),
        ]),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.action});
  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 8, 8),
        child: Row(children: [
          Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold))),
          ?action,
        ]),
      );
}
