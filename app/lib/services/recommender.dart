import 'dart:math' as math;

import '../models/song.dart';
import 'taste_service.dart';

/// Picks what to play next.
///
/// Each candidate gets a score from:
///  * how much it *sounds like* what you've just been playing (audio fingerprint),
///  * how well it fits the current mood (picked by you, or carried over from the song),
///  * your taste: likes and full listens push it up, skips push it down,
///  * freshness: songs you heard recently are held back,
///  * a little randomness so the same seed doesn't always give the same mix.
class Recommender {
  Recommender(this.taste);

  final TasteService taste;
  final _rng = math.Random();

  List<Song> nextUp({
    required List<Song> pool,
    Song? current,
    Mood? mood,
    int count = 10,
    Set<String> exclude = const {},
    List<Song> recent = const [],
  }) {
    final context = _contextVector(current, recent);
    final recentIds = taste.history.take(40).toList();
    final followMood = mood ?? current?.effectiveMood;

    final scored = <(Song, double)>[];
    for (final s in pool) {
      if (s.id == current?.id || exclude.contains(s.id)) continue;
      var score = 0.0;

      // A mood you picked is a firm request: songs that don't fit it drop out,
      // and sound-alike matters less than it does when just following the song.
      if (context != null && s.z != null) score += (mood != null ? 0.5 : 1.0) * _cosine(context, s.z!);
      if (followMood != null) {
        final fit = s.moodScore(followMood);
        score += (mood != null ? 1.6 : 0.8) * fit;
        if (mood != null && fit < 0.45) score -= 3;
      }
      score += 0.6 * taste.affinity(s.id);

      final seen = recentIds.indexOf(s.id);
      if (seen >= 0) score -= 1.2 * (1 - seen / recentIds.length);

      if (current != null && s.artist == current.artist) score += 0.1;
      score += _rng.nextDouble() * 0.25;
      scored.add((s, score));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));

    // Spread out artists so the queue doesn't become one album.
    final picked = <Song>[];
    final artistCount = <String, int>{};
    final shortlist = scored.take(count * 4).toList();
    while (picked.length < count && shortlist.isNotEmpty) {
      var bestI = 0;
      var best = double.negativeInfinity;
      for (var i = 0; i < shortlist.length; i++) {
        final (s, sc) = shortlist[i];
        final adj = sc - 0.35 * (artistCount[s.artist] ?? 0);
        if (adj > best) {
          best = adj;
          bestI = i;
        }
      }
      final s = shortlist.removeAt(bestI).$1;
      picked.add(s);
      artistCount[s.artist] = (artistCount[s.artist] ?? 0) + 1;
    }
    return picked;
  }

  /// A fresh mix for a mood: best mood fits, shaped by your taste, shuffled a bit.
  List<Song> moodMix(List<Song> pool, Mood mood, {int count = 40}) {
    final candidates = pool.where((s) => s.moodScore(mood) >= 0.45).toList();
    if (candidates.isEmpty) return [];
    Song? seed;
    double best = -1;
    for (final s in candidates) {
      final v = s.moodScore(mood) + 0.5 * taste.affinity(s.id) + _rng.nextDouble() * 0.4;
      if (v > best) {
        best = v;
        seed = s;
      }
    }
    return [seed!, ...nextUp(pool: candidates, current: seed, mood: mood, count: count - 1)];
  }

  /// Home screen picks: songs close to what you love and finish, that you haven't heard lately.
  List<Song> forYou(List<Song> pool, {int count = 20}) {
    final loved = pool.where((s) => taste.affinity(s.id) > 0.2 && s.z != null).toList();
    if (loved.isEmpty) {
      final shuffled = List.of(pool)..shuffle(_rng);
      return shuffled.take(count).toList();
    }
    loved.shuffle(_rng);
    return nextUp(pool: pool, recent: loved.take(5).toList(), count: count, exclude: loved.take(5).map((s) => s.id).toSet());
  }

  /// Songs most like [s] by sound alone.
  List<Song> similar(List<Song> pool, Song s, {int count = 20}) {
    if (s.z == null) return nextUp(pool: pool, current: s, count: count);
    final ranked = pool.where((o) => o.id != s.id && o.z != null).map((o) => (o, _cosine(s.z!, o.z!))).toList()
      ..sort((a, b) => b.$2.compareTo(a.$2));
    return ranked.take(count).map((e) => e.$1).toList();
  }

  List<double>? _contextVector(Song? current, List<Song> recent) {
    final parts = <(List<double>, double)>[];
    if (current?.z != null) parts.add((current!.z!, 1.5));
    const weights = [1.0, 0.6, 0.35, 0.2, 0.1];
    for (var i = 0; i < recent.length && i < weights.length; i++) {
      if (recent[i].z != null) parts.add((recent[i].z!, weights[i]));
    }
    if (parts.isEmpty) return null;
    final dim = parts.first.$1.length;
    final out = List<double>.filled(dim, 0);
    for (final (v, w) in parts) {
      if (v.length != dim) continue;
      for (var i = 0; i < dim; i++) {
        out[i] += v[i] * w;
      }
    }
    return out;
  }

  static double _cosine(List<double> a, List<double> b) {
    if (a.length != b.length) return 0;
    var dot = 0.0, na = 0.0, nb = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    if (na == 0 || nb == 0) return 0;
    return dot / (math.sqrt(na) * math.sqrt(nb));
  }
}
