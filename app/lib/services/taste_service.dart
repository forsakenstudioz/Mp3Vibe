import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/song.dart';

/// What you like: likes, plays, skips and recent history.
/// Kept on the device and mirrored to Supabase so it follows you across devices.
class TasteService extends ChangeNotifier {
  TasteService(this._client);

  final SupabaseClient _client;
  final Set<String> likes = {};
  final Map<String, int> plays = {};
  final Map<String, int> skips = {};
  final Map<String, int> completes = {};

  /// Most recent first.
  final List<String> history = [];

  /// Called when a song is liked, so downloads can keep it offline.
  void Function(String songId)? onLiked;

  String? get _uid => _client.auth.currentUser?.id;

  Future<void> start() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('taste_${_uid ?? 'anon'}');
    if (raw != null) {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      likes.addAll((j['likes'] as List).cast<String>());
      history.addAll((j['history'] as List).cast<String>());
      plays.addAll((j['plays'] as Map).cast<String, int>());
      skips.addAll((j['skips'] as Map).cast<String, int>());
      completes.addAll((j['completes'] as Map? ?? {}).cast<String, int>());
    }
    notifyListeners();
    await _pull();
  }

  /// Merge what this account did on other devices.
  Future<void> _pull() async {
    try {
      final liked = await _client.from('likes').select('song_id');
      likes
        ..clear()
        ..addAll(liked.map((r) => r['song_id'] as String));
      final events = await _client
          .from('listen_events')
          .select('song_id, kind')
          .order('created_at', ascending: false)
          .limit(5000);
      plays.clear();
      skips.clear();
      completes.clear();
      for (final e in events) {
        final id = e['song_id'] as String;
        final map = switch (e['kind']) { 'skip' => skips, 'complete' => completes, _ => plays };
        map[id] = (map[id] ?? 0) + 1;
      }
      await _save();
      notifyListeners();
    } catch (_) {
      // Offline: the local copy is good enough.
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'taste_${_uid ?? 'anon'}',
      jsonEncode({
        'likes': likes.toList(),
        'history': history.take(200).toList(),
        'plays': plays,
        'skips': skips,
        'completes': completes,
      }),
    );
  }

  bool isLiked(String id) => likes.contains(id);

  Future<void> toggleLike(Song s) async {
    final nowLiked = !likes.contains(s.id);
    nowLiked ? likes.add(s.id) : likes.remove(s.id);
    notifyListeners();
    await _save();
    if (nowLiked) onLiked?.call(s.id);
    try {
      if (nowLiked) {
        await _client.from('likes').upsert({'song_id': s.id});
      } else {
        await _client.from('likes').delete().eq('song_id', s.id);
      }
    } catch (_) {}
  }

  void recordPlay(Song s) {
    plays[s.id] = (plays[s.id] ?? 0) + 1;
    history
      ..remove(s.id)
      ..insert(0, s.id);
    _event(s, 'play', 0);
  }

  void recordSkip(Song s, Duration listened) {
    skips[s.id] = (skips[s.id] ?? 0) + 1;
    _event(s, 'skip', listened.inMilliseconds);
  }

  void recordComplete(Song s) {
    completes[s.id] = (completes[s.id] ?? 0) + 1;
    _event(s, 'complete', s.durationMs);
  }

  void _event(Song s, String kind, int ms) {
    notifyListeners();
    _save();
    _client
        .from('listen_events')
        .insert({'song_id': s.id, 'kind': kind, 'listened_ms': ms})
        .then((_) {}, onError: (_) {});
  }

  /// -1 (always skipped) .. +1 (loved and finished every time).
  double affinity(String id) {
    final p = plays[id] ?? 0;
    final sk = skips[id] ?? 0;
    final c = completes[id] ?? 0;
    var a = likes.contains(id) ? 0.5 : 0.0;
    if (p > 0) a += (c - 1.5 * sk) / (p + 2);
    return a.clamp(-1.0, 1.0);
  }
}
