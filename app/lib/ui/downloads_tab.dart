import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/download_service.dart';
import '../services/library_service.dart';
import 'widgets.dart';

class DownloadsTab extends StatelessWidget {
  const DownloadsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final downloads = context.watch<DownloadService>();
    final lib = context.watch<LibraryService>();
    final saved = lib.songs.where((s) => downloads.isDownloaded(s.id)).toList();
    final inProgress = lib.songs.where((s) => downloads.isDownloading(s.id)).toList();
    return ListView(children: [
      SwitchListTile(
        secondary: const Icon(Icons.favorite_rounded),
        title: const Text('Keep liked songs offline'),
        subtitle: const Text('Songs you like are downloaded automatically'),
        value: downloads.autoDownloadLiked,
        onChanged: downloads.setAutoDownloadLiked,
      ),
      FutureBuilder<int>(
        future: downloads.bytesUsed(),
        builder: (context, snap) => ListTile(
          leading: const Icon(Icons.sd_storage_rounded),
          title: Text('${saved.length} songs saved on this device'),
          subtitle: Text(snap.hasData ? '${(snap.data! / 1e6).toStringAsFixed(0)} MB used' : ''),
        ),
      ),
      if (inProgress.isNotEmpty) ...[
        SectionHeader('Downloading (${inProgress.length})'),
        for (final s in inProgress) SongTile(song: s),
      ],
      const SectionHeader('Available offline'),
      if (saved.isEmpty)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Text('Nothing downloaded yet. Use the ⋮ menu on any song, or "Download all" in the library.', textAlign: TextAlign.center),
        ),
      for (final s in saved) SongTile(song: s, list: saved),
    ]);
  }
}
