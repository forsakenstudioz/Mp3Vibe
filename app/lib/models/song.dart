import 'package:flutter/material.dart';

enum Mood {
  energetic('Energetic', 'Gaana, mass, high energy', '🔥', Color(0xFFFF6B35)),
  party('Party', 'Dance floor, remixes', '🎉', Color(0xFFE040FB)),
  calm('Calm', 'Slow, soft, peaceful', '🌙', Color(0xFF4FC3F7)),
  romantic('Romantic', 'Love songs, melodies', '💗', Color(0xFFFF4081)),
  sad('Sad', 'Feels, heartbreak', '🌧️', Color(0xFF7986CB)),
  focus('Focus', 'Lo-fi, study, instrumental', '🎧', Color(0xFF66BB6A));

  const Mood(this.label, this.blurb, this.emoji, this.color);
  final String label;
  final String blurb;
  final String emoji;
  final Color color;

  static Mood? parse(String? name) {
    for (final m in Mood.values) {
      if (m.name == name) return m;
    }
    return null;
  }
}

class Song {
  Song({
    required this.id,
    required this.title,
    required this.artist,
    required this.storageKey,
    required this.fileExt,
    this.album,
    this.genre,
    this.year,
    this.durationMs = 0,
    this.coverKey,
    this.fileSize = 0,
    this.bpm,
    this.energy,
    this.valence,
    this.danceability,
    this.features,
    this.mood,
    this.moodOverride,
    this.moodScores = const {},
    required this.addedAt,
    this.deleted = false,
  });

  final String id;
  final String title;
  final String artist;
  final String? album;
  final String? genre;
  final int? year;
  final int durationMs;
  final String storageKey;
  final String? coverKey;
  final String fileExt;
  final int fileSize;
  final double? bpm;
  final double? energy;
  final double? valence;
  final double? danceability;
  final List<double>? features;
  final Mood? mood;
  Mood? moodOverride;
  final Map<String, double> moodScores;
  final DateTime addedAt;
  final bool deleted;

  /// Feature vector standardised across the library (set by LibraryService).
  List<double>? z;

  Mood? get effectiveMood => moodOverride ?? mood;

  /// How well this song fits [m], 0..1. A manual override counts as a perfect fit.
  double moodScore(Mood m) {
    if (moodOverride != null) return moodOverride == m ? 1.0 : 0.15;
    return moodScores[m.name] ?? (mood == m ? 1.0 : 0.0);
  }

  Duration get duration => Duration(milliseconds: durationMs);

  static double? _d(dynamic v) => v == null ? null : (v as num).toDouble();

  factory Song.fromJson(Map<String, dynamic> j) => Song(
        id: j['id'] as String,
        title: j['title'] as String? ?? 'Untitled',
        artist: j['artist'] as String? ?? 'Unknown artist',
        album: j['album'] as String?,
        genre: j['genre'] as String?,
        year: j['year'] as int?,
        durationMs: j['duration_ms'] as int? ?? 0,
        storageKey: j['storage_key'] as String,
        coverKey: j['cover_key'] as String?,
        fileExt: j['file_ext'] as String? ?? 'mp3',
        fileSize: (j['file_size'] as num?)?.toInt() ?? 0,
        bpm: _d(j['bpm']),
        energy: _d(j['energy']),
        valence: _d(j['valence']),
        danceability: _d(j['danceability']),
        features: (j['features'] as List?)?.map((e) => (e as num).toDouble()).toList(),
        mood: Mood.parse(j['mood'] as String?),
        moodOverride: Mood.parse(j['mood_override'] as String?),
        moodScores: ((j['mood_scores'] as Map?) ?? const {})
            .map((k, v) => MapEntry(k as String, (v as num).toDouble())),
        addedAt: DateTime.tryParse(j['added_at'] as String? ?? '') ?? DateTime.now(),
        deleted: j['deleted'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'album': album,
        'genre': genre,
        'year': year,
        'duration_ms': durationMs,
        'storage_key': storageKey,
        'cover_key': coverKey,
        'file_ext': fileExt,
        'file_size': fileSize,
        'bpm': bpm,
        'energy': energy,
        'valence': valence,
        'danceability': danceability,
        'features': features,
        'mood': mood?.name,
        'mood_override': moodOverride?.name,
        'mood_scores': moodScores,
        'added_at': addedAt.toIso8601String(),
        'deleted': deleted,
      };
}

String formatDuration(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds % 60;
  if (m >= 60) return '${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  return '$m:${s.toString().padLeft(2, '0')}';
}
