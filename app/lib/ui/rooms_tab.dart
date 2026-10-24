import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/room_service.dart';
import 'room_screen.dart';

class RoomsTab extends StatefulWidget {
  const RoomsTab({super.key});

  @override
  State<RoomsTab> createState() => _RoomsTabState();
}

class _RoomsTabState extends State<RoomsTab> {
  final _code = TextEditingController();
  late Future<List<RoomInfo>> _recent;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _recent = context.read<RoomService>().recentRooms();
  }

  Future<void> _join(String code) async {
    setState(() => _busy = true);
    final rooms = context.read<RoomService>();
    try {
      await rooms.join(code);
      if (mounted) openRoom(context);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final c = TextEditingController(text: 'Vibe room');
        return AlertDialog(
          title: const Text('New room'),
          content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(labelText: 'Room name')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Create')),
          ],
        );
      },
    );
    if (name == null || name.isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      final code = await context.read<RoomService>().create(name);
      await _join(code);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final rooms = context.watch<RoomService>();
    return RefreshIndicator(
      onRefresh: () async => setState(() => _recent = rooms.recentRooms()),
      child: ListView(padding: const EdgeInsets.all(16), children: [
        Text('Listen together', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        const Text('Everyone in a room hears the same song at the same moment. Anyone can play, skip or queue songs.'),
        const SizedBox(height: 16),
        if (rooms.inRoom)
          Card(
            child: ListTile(
              leading: const Icon(Icons.headphones_rounded),
              title: Text('You are in "${rooms.roomName}"'),
              subtitle: Text('${rooms.members.length} listening · code ${rooms.code}'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => openRoom(context),
            ),
          ),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _code,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(labelText: 'Room code', border: OutlineInputBorder(), prefixIcon: Icon(Icons.tag_rounded)),
              onSubmitted: _join,
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(onPressed: _busy ? null : () => _join(_code.text), child: const Text('Join')),
        ]),
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          onPressed: _busy ? null : _create,
          icon: const Icon(Icons.add_rounded),
          label: const Text('Create a room'),
        ),
        const SizedBox(height: 24),
        Text('Recent rooms', style: Theme.of(context).textTheme.titleMedium),
        FutureBuilder<List<RoomInfo>>(
          future: _recent,
          builder: (context, snap) {
            if (!snap.hasData) {
              return Padding(
                padding: const EdgeInsets.all(16),
                child: snap.hasError ? const Text('Could not load rooms') : const Center(child: CircularProgressIndicator()),
              );
            }
            if (snap.data!.isEmpty) return const Padding(padding: EdgeInsets.all(16), child: Text('No rooms yet'));
            return Column(children: [
              for (final r in snap.data!)
                ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.groups_rounded)),
                  title: Text(r.name),
                  subtitle: Text('Code ${r.code}'),
                  onTap: _busy ? null : () => _join(r.code),
                ),
            ]);
          },
        ),
      ]),
    );
  }
}
