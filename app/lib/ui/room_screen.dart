import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../services/library_service.dart';
import '../services/player_service.dart';
import '../services/room_service.dart';
import 'widgets.dart';

void openRoom(BuildContext context) {
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RoomScreen()));
}

class RoomScreen extends StatefulWidget {
  const RoomScreen({super.key});

  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends State<RoomScreen> {
  final _floating = <_FloatingEmoji>[];
  StreamSubscription<String>? _sub;
  final _rng = math.Random();

  @override
  void initState() {
    super.initState();
    _sub = context.read<RoomService>().reactions.listen((emoji) {
      final f = _FloatingEmoji(emoji, _rng.nextDouble(), UniqueKey());
      setState(() => _floating.add(f));
      Future.delayed(const Duration(milliseconds: 2200), () {
        if (mounted) setState(() => _floating.remove(f));
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rooms = context.watch<RoomService>();
    if (!rooms.inRoom) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('You left the room')));
    }
    final wide = MediaQuery.sizeOf(context).width > 900;
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(rooms.roomName ?? ''),
          Text(
            rooms.connected ? '${rooms.members.length} listening · ${_syncLabel(rooms.driftMs)}' : 'Connecting...',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ]),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: Text(rooms.code ?? ''),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: rooms.code ?? ''));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Room code copied. Send it to your friends!')));
            },
          ),
          IconButton(
            tooltip: 'Leave room',
            icon: const Icon(Icons.logout_rounded),
            onPressed: () async {
              await rooms.leave();
              if (context.mounted) Navigator.pop(context);
            },
          ),
        ],
      ),
      body: Stack(children: [
        wide
            ? Row(children: [
                const Expanded(flex: 3, child: _RoomPlayer()),
                const VerticalDivider(width: 1),
                Expanded(flex: 2, child: _Chat(rooms: rooms)),
              ])
            : DefaultTabController(
                length: 2,
                child: Column(children: [
                  const TabBar(tabs: [Tab(text: 'Music'), Tab(text: 'Chat')]),
                  Expanded(child: TabBarView(children: [const _RoomPlayer(), _Chat(rooms: rooms)])),
                ]),
              ),
        for (final f in _floating) _FloatingEmojiView(key: f.key, emoji: f.emoji, x: f.x),
      ]),
    );
  }

  String _syncLabel(int drift) => drift.abs() < 80 ? 'in sync' : 'syncing (${drift.abs()} ms)';
}

class _RoomPlayer extends StatelessWidget {
  const _RoomPlayer();

  @override
  Widget build(BuildContext context) {
    final rooms = context.watch<RoomService>();
    final player = context.watch<PlayerService>();
    final lib = context.watch<LibraryService>();
    final song = lib.byId(rooms.state.songId);
    final queue = rooms.upNext;
    return ListView(padding: const EdgeInsets.all(16), children: [
      SizedBox(
        height: 40,
        child: ListView(scrollDirection: Axis.horizontal, children: [
          for (final m in rooms.members)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Chip(avatar: CircleAvatar(child: Text(m.name.isEmpty ? '?' : m.name[0].toUpperCase())), label: Text(m.name)),
            ),
        ]),
      ),
      const SizedBox(height: 12),
      if (song == null)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(children: [
              const Icon(Icons.queue_music_rounded, size: 48),
              const SizedBox(height: 8),
              const Text('Nothing playing yet'),
              const SizedBox(height: 12),
              FilledButton.icon(icon: const Icon(Icons.add_rounded), label: const Text('Pick a song'), onPressed: () => _pickSong(context)),
              TextButton(onPressed: rooms.requestNext, child: const Text('Or let the room DJ choose')),
            ]),
          ),
        )
      else
        Row(children: [
          CoverArt(song, size: 120, radius: 16),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(song.title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold), maxLines: 2),
              Text(song.artist),
              if (song.effectiveMood != null) Padding(padding: const EdgeInsets.only(top: 6), child: MoodBadge(song.effectiveMood!)),
            ]),
          ),
        ]),
      if (song != null) ...[
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
                onChanged: (_) {},
                onChangeEnd: (v) => rooms.requestSeek(Duration(milliseconds: v.round())),
              ),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(formatDuration(pos)), Text(formatDuration(total))]),
            ]);
          },
        ),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          IconButton(iconSize: 36, icon: const Icon(Icons.replay_rounded), onPressed: () => rooms.requestSeek(Duration.zero)),
          const SizedBox(width: 12),
          IconButton.filled(
            iconSize: 48,
            icon: Icon(rooms.state.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
            onPressed: rooms.requestToggle,
          ),
          const SizedBox(width: 12),
          IconButton(iconSize: 36, icon: const Icon(Icons.skip_next_rounded), onPressed: rooms.requestNext),
        ]),
      ],
      const SizedBox(height: 8),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        for (final e in ['🔥', '❤️', '😂', '🕺', '😭', '🙌'])
          IconButton(onPressed: () => rooms.react(e), icon: Text(e, style: const TextStyle(fontSize: 24))),
      ]),
      const Divider(),
      Row(children: [
        Text('Room queue', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
        const Spacer(),
        TextButton.icon(icon: const Icon(Icons.add_rounded), label: const Text('Add song'), onPressed: () => _pickSong(context)),
      ]),
      if (queue.isEmpty)
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text('Queue is empty. When the song ends, the room DJ picks one that matches the vibe.'),
        ),
      for (final s in queue)
        SongTile(
          song: s,
          onTap: () => rooms.requestPlay(s),
          trailing: IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => rooms.removeFromQueue(s.id)),
        ),
    ]);
  }

  Future<void> _pickSong(BuildContext context) async {
    final song = await showModalBottomSheet<Song>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _SongPicker(),
    );
    if (song != null && context.mounted) context.read<RoomService>().requestEnqueue(song);
  }
}

class _SongPicker extends StatefulWidget {
  const _SongPicker();

  @override
  State<_SongPicker> createState() => _SongPickerState();
}

class _SongPickerState extends State<_SongPicker> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final songs = context.watch<LibraryService>().search(_q);
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.8,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SearchBar(autoFocus: true, hintText: 'Search songs', onChanged: (v) => setState(() => _q = v)),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: songs.length,
            itemBuilder: (_, i) => SongTile(
              song: songs[i],
              onTap: () => Navigator.pop(context, songs[i]),
              trailing: const Icon(Icons.add_rounded),
            ),
          ),
        ),
      ]),
    );
  }
}

class _Chat extends StatefulWidget {
  const _Chat({required this.rooms});
  final RoomService rooms;

  @override
  State<_Chat> createState() => _ChatState();
}

class _ChatState extends State<_Chat> {
  final _text = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final chat = widget.rooms.chat.reversed.toList();
    return Column(children: [
      Expanded(
        child: chat.isEmpty
            ? const Center(child: Text('Say hi 👋'))
            : ListView.builder(
                reverse: true,
                padding: const EdgeInsets.all(12),
                itemCount: chat.length,
                itemBuilder: (_, i) {
                  final m = chat[i];
                  if (m.system) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(m.text, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
                    );
                  }
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: RichText(
                      text: TextSpan(style: DefaultTextStyle.of(context).style, children: [
                        TextSpan(text: '${m.name}  ', style: TextStyle(fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary)),
                        TextSpan(text: m.text),
                      ]),
                    ),
                  );
                },
              ),
      ),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _text,
                decoration: const InputDecoration(hintText: 'Message', border: OutlineInputBorder(), isDense: true),
                onSubmitted: (_) => _send(),
              ),
            ),
            IconButton(icon: const Icon(Icons.send_rounded), onPressed: _send),
          ]),
        ),
      ),
    ]);
  }

  void _send() {
    widget.rooms.sendChat(_text.text);
    _text.clear();
  }
}

class _FloatingEmoji {
  _FloatingEmoji(this.emoji, this.x, this.key);
  final String emoji;
  final double x;
  final Key key;
}

class _FloatingEmojiView extends StatelessWidget {
  const _FloatingEmojiView({super.key, required this.emoji, required this.x});
  final String emoji;
  final double x;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 2000),
          builder: (context, t, child) => Align(
            alignment: Alignment(x * 1.6 - 0.8, 1 - t * 1.8),
            child: Opacity(opacity: (1 - t).clamp(0, 1), child: Transform.scale(scale: 1 + t * 0.6, child: child)),
          ),
          child: Text(emoji, style: const TextStyle(fontSize: 36)),
        ),
      ),
    );
  }
}
