import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/song.dart';

/// The song list. Loads instantly from a local copy, then refreshes from
/// Supabase and listens for songs the laptop adds while the app is open.
class LibraryService extends ChangeNotifier {
  LibraryService(this._client);

  final SupabaseClient _client;
  final Map<String, Song> _byId = {};
  List<Song> _songs = [];
  RealtimeChannel? _channel;
  bool loading = true;
  String? error;
  DateTime? lastSynced;

  /// Songs that arrived live since the app opened, newest first.
  final List<Song> justAdded = [];

  List<Song> get songs => _songs;
  Song? byId(String? id) => id == null ? null : _byId[id];

  Future<File> get _cacheFile async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/library.json');
  }

  Future<void> start() async {
    await _loadCache();
    await refresh();
    _subscribe();
  }

  Future<void> _loadCache() async {
    try {
      final f = await _cacheFile;
      if (await f.exists()) {
        final rows = (jsonDecode(await f.readAsString()) as List).cast<Map<String, dynamic>>();
        _replaceAll(rows.map(Song.fromJson));
      }
    } catch (_) {
      // A broken cache is not worth failing over; the network copy replaces it.
    }
  }

  Future<void> refresh() async {
    loading = true;
    notifyListeners();
    try {
      final rows = <Map<String, dynamic>>[];
      const page = 1000;
      for (var from = 0;; from += page) {
        final chunk = await _client
            .from('songs')
            .select()
            .eq('deleted', false)
            .order('added_at', ascending: false)
            .range(from, from + page - 1);
        rows.addAll(chunk);
        if (chunk.length < page) break;
      }
      _replaceAll(rows.map(Song.fromJson));
      error = null;
      lastSynced = DateTime.now();
      final f = await _cacheFile;
      await f.writeAsString(jsonEncode(_songs.map((s) => s.toJson()).toList()));
    } catch (e) {
      error = _songs.isEmpty ? 'Could not load your library. Check your connection.' : null;
    }
    loading = false;
    notifyListeners();
  }

  void _subscribe() {
    _channel = _client
        .channel('public:songs')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'songs',
          callback: (payload) {
            final row = payload.newRecord;
            if (row.isEmpty) {
              final id = payload.oldRecord['id'] as String?;
              if (id != null && _byId.remove(id) != null) _rebuild();
              return;
            }
            final song = Song.fromJson(row);
            final isNew = !_byId.containsKey(song.id);
            if (song.deleted) {
              _byId.remove(song.id);
            } else {
              _byId[song.id] = song;
              if (isNew) justAdded.insert(0, song);
            }
            _rebuild();
          },
        )
        .subscribe();
  }

  void _replaceAll(Iterable<Song> songs) {
    _byId
      ..clear()
      ..addEntries(songs.where((s) => !s.deleted).map((s) => MapEntry(s.id, s)));
    _rebuild();
  }

  void _rebuild() {
    _songs = _byId.values.toList()..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    _standardise();
    notifyListeners();
  }

  /// Puts every feature on the same scale so no single measurement (like BPM)
  /// dominates "sounds like" comparisons.
  void _standardise() {
    final withFeatures = _songs.where((s) => s.features != null && s.features!.isNotEmpty).toList();
    if (withFeatures.length < 2) {
      for (final s in _songs) {
        s.z = null;
      }
      return;
    }
    final counts = <int, int>{};
    for (final s in withFeatures) {
      counts[s.features!.length] = (counts[s.features!.length] ?? 0) + 1;
    }
    final dim = counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    final usable = withFeatures.where((s) => s.features!.length == dim).toList();
    final mean = List<double>.filled(dim, 0);
    final sd = List<double>.filled(dim, 0);
    for (final s in usable) {
      for (var i = 0; i < dim; i++) {
        mean[i] += s.features![i] / usable.length;
      }
    }
    for (final s in usable) {
      for (var i = 0; i < dim; i++) {
        sd[i] += math.pow(s.features![i] - mean[i], 2) / usable.length;
      }
    }
    for (var i = 0; i < dim; i++) {
      sd[i] = math.sqrt(sd[i]);
      if (sd[i] < 1e-6) sd[i] = 1;
    }
    for (final s in _songs) {
      final f = s.features;
      s.z = (f == null || f.length != dim) ? null : [for (var i = 0; i < dim; i++) (f[i] - mean[i]) / sd[i]];
    }
  }

  Future<void> setMoodOverride(Song song, Mood? mood) async {
    song.moodOverride = mood;
    notifyListeners();
    await _client.from('songs').update({'mood_override': mood?.name}).eq('id', song.id);
  }

  List<Song> search(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return _songs;
    return _songs
        .where((s) =>
            s.title.toLowerCase().contains(q) ||
            s.artist.toLowerCase().contains(q) ||
            (s.album?.toLowerCase().contains(q) ?? false) ||
            (s.genre?.toLowerCase().contains(q) ?? false))
        .toList();
  }

  @override
  void dispose() {
    _channel?.unsubscribe();
    super.dispose();
  }
}
