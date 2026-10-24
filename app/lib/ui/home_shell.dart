import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/connectivity_service.dart';
import '../services/library_service.dart';
import '../services/player_service.dart';
import '../services/room_service.dart';
import 'downloads_tab.dart';
import 'home_tab.dart';
import 'library_tab.dart';
import 'room_screen.dart';
import 'rooms_tab.dart';
import 'widgets.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;
  StreamSubscription<String>? _messages;

  static const _destinations = [
    (Icons.home_outlined, Icons.home_rounded, 'Home'),
    (Icons.library_music_outlined, Icons.library_music_rounded, 'Library'),
    (Icons.groups_outlined, Icons.groups_rounded, 'Rooms'),
    (Icons.download_outlined, Icons.download_rounded, 'Downloads'),
  ];

  @override
  void initState() {
    super.initState();
    _messages = context.read<PlayerService>().messages.listen((m) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    });
  }

  @override
  void dispose() {
    _messages?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 760;
    final online = context.watch<ConnectivityService>().online;
    final rooms = context.watch<RoomService>();
    final body = IndexedStack(index: _tab, children: const [HomeTab(), LibraryTab(), RoomsTab(), DownloadsTab()]);

    final appBar = AppBar(
      title: Row(children: [
        const Icon(Icons.graphic_eq_rounded),
        const SizedBox(width: 8),
        const Text('Vibe', style: TextStyle(fontWeight: FontWeight.bold)),
        if (!online) ...[const SizedBox(width: 12), const Chip(avatar: Icon(Icons.cloud_off_rounded, size: 16), label: Text('Offline'))],
      ]),
      actions: [
        if (rooms.inRoom)
          TextButton.icon(onPressed: () => openRoom(context), icon: const Icon(Icons.headphones_rounded), label: Text(rooms.roomName ?? 'Room')),
        PopupMenuButton<String>(
          onSelected: (v) async {
            if (v == 'refresh') await context.read<LibraryService>().refresh();
            if (v == 'signout') {
              if (rooms.inRoom) await rooms.leave();
              await Supabase.instance.client.auth.signOut();
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'refresh', child: Text('Refresh library')),
            PopupMenuItem(
              value: 'signout',
              child: Text('Sign out (${Supabase.instance.client.auth.currentUser?.email ?? ''})'),
            ),
          ],
        ),
      ],
    );

    if (wide) {
      return Scaffold(
        appBar: appBar,
        body: Row(children: [
          NavigationRail(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            labelType: NavigationRailLabelType.all,
            destinations: [
              for (final d in _destinations) NavigationRailDestination(icon: Icon(d.$1), selectedIcon: Icon(d.$2), label: Text(d.$3)),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: body),
        ]),
        bottomNavigationBar: const MiniPlayer(),
      );
    }
    return Scaffold(
      appBar: appBar,
      body: body,
      bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [
        const MiniPlayer(),
        NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          destinations: [for (final d in _destinations) NavigationDestination(icon: Icon(d.$1), selectedIcon: Icon(d.$2), label: d.$3)],
        ),
      ]),
    );
  }
}
