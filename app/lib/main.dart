import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_config.dart';
import 'services/connectivity_service.dart';
import 'services/download_service.dart';
import 'services/library_service.dart';
import 'services/player_service.dart';
import 'services/recommender.dart';
import 'services/room_service.dart';
import 'services/taste_service.dart';
import 'services/url_signer.dart';
import 'ui/home_shell.dart';
import 'ui/setup_screens.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Windows and Linux play audio through media_kit (libmpv).
  JustAudioMediaKit.ensureInitialized(linux: true, windows: true);
  if (PlayerService.backgroundSupported) {
    // Keeps music going with the screen off, with lock-screen controls.
    await JustAudioBackground.init(
      androidNotificationChannelId: 'com.zoro.vibe.playback',
      androidNotificationChannelName: 'Music playback',
      androidNotificationOngoing: true,
    );
  }
  final config = await AppConfig.load();
  if (config != null) await _initSupabase(config);
  runApp(VibeApp(configured: config != null));
}

Future<void> _initSupabase(AppConfig c) => Supabase.initialize(url: c.supabaseUrl, publishableKey: c.supabaseKey);

ThemeData _theme(Brightness b) => ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF7C4DFF), brightness: b),
    );

class VibeApp extends StatefulWidget {
  const VibeApp({super.key, required this.configured});
  final bool configured;

  @override
  State<VibeApp> createState() => _VibeAppState();
}

class _VibeAppState extends State<VibeApp> {
  late bool _configured = widget.configured;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vibe',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: ThemeMode.dark,
      home: _configured
          ? const _AuthGate()
          : ServerSetupScreen(onSaved: () async {
              await _initSupabase((await AppConfig.load())!);
              setState(() => _configured = true);
            }),
    );
  }
}

class _AuthGate extends StatelessWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context) {
    final auth = Supabase.instance.client.auth;
    return StreamBuilder<AuthState>(
      stream: auth.onAuthStateChange,
      builder: (context, _) {
        final user = auth.currentUser;
        if (user == null) return const LoginScreen();
        return _SignedIn(key: ValueKey(user.id));
      },
    );
  }
}

/// Everything that needs a signed-in user. Rebuilt from scratch per account.
class _SignedIn extends StatefulWidget {
  const _SignedIn({super.key});

  @override
  State<_SignedIn> createState() => _SignedInState();
}

class _SignedInState extends State<_SignedIn> {
  final client = Supabase.instance.client;
  late final signer = UrlSigner(client);
  late final connectivity = ConnectivityService();
  late final library = LibraryService(client);
  late final downloads = DownloadService(signer);
  late final taste = TasteService(client);
  late final recommender = Recommender(taste);
  late final player = PlayerService(
    library: library,
    downloads: downloads,
    signer: signer,
    taste: taste,
    connectivity: connectivity,
    recommender: recommender,
  );
  late final rooms = RoomService(client, player, library, recommender);

  bool? _hasName;

  @override
  void initState() {
    super.initState();
    taste.onLiked = (id) {
      final s = library.byId(id);
      if (s != null && downloads.autoDownloadLiked) downloads.download(s);
    };
    unawaited(connectivity.start());
    unawaited(downloads.start());
    unawaited(taste.start());
    unawaited(library.start());
    _checkName();
  }

  Future<void> _checkName() async {
    try {
      final row = await client.from('profiles').select('display_name').eq('id', client.auth.currentUser!.id).maybeSingle();
      setState(() => _hasName = row != null);
    } catch (_) {
      setState(() => _hasName = true); // offline: don't block the app on this
    }
  }

  @override
  void dispose() {
    rooms.dispose();
    player.dispose();
    library.dispose();
    connectivity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_hasName == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (_hasName == false) return NameScreen(onDone: () => setState(() => _hasName = true));
    return MultiProvider(
      providers: [
        Provider.value(value: signer),
        Provider.value(value: recommender),
        ChangeNotifierProvider.value(value: connectivity),
        ChangeNotifierProvider.value(value: library),
        ChangeNotifierProvider.value(value: downloads),
        ChangeNotifierProvider.value(value: taste),
        ChangeNotifierProvider.value(value: player),
        ChangeNotifierProvider.value(value: rooms),
      ],
      child: const HomeShell(),
    );
  }
}
