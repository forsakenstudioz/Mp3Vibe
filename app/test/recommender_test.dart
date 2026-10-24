import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vibe/models/song.dart';
import 'package:vibe/services/recommender.dart';
import 'package:vibe/services/taste_service.dart';

Song _song(String id, Mood mood, List<double> z, {String artist = 'A'}) => Song(
      id: id,
      title: id,
      artist: artist,
      storageKey: 'audio/$id.mp3',
      fileExt: 'mp3',
      mood: mood,
      moodScores: {for (final m in Mood.values) m.name: m == mood ? 1.0 : 0.1},
      addedAt: DateTime(2026),
    )..z = z;

void main() {
  final taste = TasteService(SupabaseClient('http://localhost', 'test-key'));
  final rec = Recommender(taste);

  final calm = [for (var i = 0; i < 8; i++) _song('calm$i', Mood.calm, [-1, -1, 0.1 * i], artist: 'C$i')];
  final party = [for (var i = 0; i < 8; i++) _song('party$i', Mood.party, [1, 1, 0.1 * i], artist: 'P$i')];
  final pool = [...calm, ...party];

  test('next up after a calm song stays calm', () {
    final picks = rec.nextUp(pool: pool, current: calm.first, count: 5);
    expect(picks.where((s) => s.mood == Mood.calm).length, greaterThanOrEqualTo(4));
    expect(picks.any((s) => s.id == calm.first.id), isFalse);
  });

  test('an explicit mood overrides what is playing', () {
    final picks = rec.nextUp(pool: pool, current: calm.first, mood: Mood.party, count: 5);
    expect(picks.where((s) => s.mood == Mood.party).length, greaterThanOrEqualTo(4));
  });

  test('mood mix only contains songs that fit', () {
    final mix = rec.moodMix(pool, Mood.party, count: 6);
    expect(mix, isNotEmpty);
    expect(mix.every((s) => s.mood == Mood.party), isTrue);
  });

  test('recently played songs are held back', () {
    taste.history
      ..clear()
      ..addAll(['calm1', 'calm2', 'calm3']);
    final picks = rec.nextUp(pool: calm, current: calm.first, count: 3);
    expect(picks.map((s) => s.id), isNot(contains('calm1')));
    taste.history.clear();
  });

  test('similar ranks by sound', () {
    final sim = rec.similar(pool, party.first, count: 3);
    expect(sim.every((s) => s.mood == Mood.party), isTrue);
  });
}
