import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import '../models/song.dart';
import 'connectivity_service.dart';
import 'download_service.dart';
import 'library_service.dart';
import 'recommender.dart';
import 'taste_service.dart';
import 'url_signer.dart';

/// While you're in a listening room, the room decides what plays. The player
/// forwards your button presses to it instead of acting on them directly.
abstract class RoomControl {
  void requestPlay(Song song);
  void requestToggle();
  void requestNext();
  void requestSeek(Duration position);
  void requestEnqueue(Song song);
  void onTrackEnded();
  List<Song> get upNext;
}

class PlayerService extends ChangeNotifier {
  PlayerService({
    required this.library,
    required this.downloads,
    required this.signer,
    required this.taste,
    required this.connectivity,
    required this.recommender,
  }) {
    _player.processingStateStream.listen((st) {
      if (st == ProcessingState.completed) _onCompleted();
    });
    _player.playingStream.listen((_) => notifyListeners());
  }

  final LibraryService library;
  final DownloadService downloads;
  final UrlSigner signer;
  final TasteService taste;
  final ConnectivityService connectivity;
  final Recommender recommender;

  final AudioPlayer _player = AudioPlayer();
  final _messages = StreamController<String>.broadcast();

  List<Song> _queue = [];
  int _index = -1;
  Song? _current;

  /// Keep adding suggestions so the music never stops.
  bool smartQueue = true;

  /// Mood the smart queue follows. Null means "follow whatever is playing".
  Mood? activeMood;

  RoomControl? room;

  Stream<String> get messages => _messages.stream;
  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;
  Stream<Duration> get bufferedStream => _player.bufferedPositionStream;
  Duration get position => _player.position;
  Duration? get duration => _player.duration;
  bool get playing => _player.playing;
  Song? get current => _current;
  bool get inRoom => room != null;

  List<Song> get upNext {
    if (room != null) return room!.upNext;
    return _index + 1 < _queue.length ? _queue.sublist(_index + 1) : const [];
  }

  // -- what you press -------------------------------------------------------

  /// Play [song]. If [list] is given, the songs after it in that list play next.
  Future<void> play(Song song, {List<Song>? list, Mood? mood}) async {
    if (room != null) return room!.requestPlay(song);
    activeMood = mood;
    if (list != null) {
      final start = list.indexWhere((s) => s.id == song.id);
      _queue = start >= 0 ? list.sublist(start) : [song, ...list];
    } else {
      _queue = [song];
    }
    _index = 0;
    _topUp();
    await _playIndex(0);
  }

  Future<void> playMood(Mood mood) async {
    final mix = recommender.moodMix(_playable(library.songs), mood);
    if (mix.isEmpty) {
      _messages.add(connectivity.online
          ? 'No ${mood.label.toLowerCase()} songs yet. Add some to your folder!'
          : 'No downloaded ${mood.label.toLowerCase()} songs for offline listening.');
      return;
    }
    await play(mix.first, list: mix, mood: mood);
  }

  Future<void> toggle() async {
    if (room != null) return room!.requestToggle();
    if (_current == null) return;
    _player.playing ? await _player.pause() : await _player.play();
  }

  Future<void> next() async {
    if (room != null) return room!.requestNext();
    final cur = _current;
    final dur = _player.duration;
    if (cur != null && dur != null && dur.inMilliseconds > 0 && _player.position < dur * 0.5) {
      taste.recordSkip(cur, _player.position);
    }
    await _advance();
  }

  Future<void> previous() async {
    if (room != null) return room!.requestSeek(Duration.zero);
    if (_player.position > const Duration(seconds: 4) || _index <= 0) {
      await _player.seek(Duration.zero);
    } else {
      await _playIndex(_index - 1);
    }
  }

  Future<void> seek(Duration d) async {
    if (room != null) return room!.requestSeek(d);
    await _player.seek(d);
  }

  void enqueue(Song s) {
    if (room != null) return room!.requestEnqueue(s);
    _queue.insert(_index + 1 + _manualCount(), s);
    _manualAdds.add(s.id);
    _messages.add('Added "${s.title}" to the queue');
    notifyListeners();
  }

  void removeFromQueue(int upNextIndex) {
    final i = _index + 1 + upNextIndex;
    if (i < _queue.length) {
      _queue.removeAt(i);
      _topUp();
      notifyListeners();
    }
  }

  void setSmartQueue(bool v) {
    smartQueue = v;
    _topUp();
    notifyListeners();
  }

  void setMood(Mood? m) {
    activeMood = m;
    // Re-pick the suggested part of the queue to match the new mood.
    if (_index >= 0) {
      _queue = _queue.sublist(0, _index + 1 + _manualCount());
      _topUp();
    }
    notifyListeners();
  }

  // Songs you added by hand stay ahead of suggestions.
  final Set<String> _manualAdds = {};
  int _manualCount() {
    var n = 0;
    for (var i = _index + 1; i < _queue.length && _manualAdds.contains(_queue[i].id); i++) {
      n++;
    }
    return n;
  }

  // -- internals ------------------------------------------------------------

  List<Song> _playable(List<Song> songs) =>
      connectivity.online ? songs : songs.where((s) => downloads.isDownloaded(s.id)).toList();

  void _topUp() {
    if (!smartQueue || _queue.isEmpty) return;
    final ahead = _queue.length - _index - 1;
    if (ahead >= 5) return;
    final recent = taste.history.take(5).map(library.byId).whereType<Song>().toList();
    _queue.addAll(recommender.nextUp(
      pool: _playable(library.songs),
      current: _queue.last,
      mood: activeMood,
      count: 10 - ahead,
      exclude: _queue.map((s) => s.id).toSet(),
      recent: recent,
    ));
  }

  Future<void> _advance() async {
    if (_index + 1 >= _queue.length) _topUp();
    if (_index + 1 < _queue.length) {
      await _playIndex(_index + 1);
    } else {
      await _player.pause();
      await _player.seek(Duration.zero);
    }
  }

  Future<void> _playIndex(int i) async {
    // Skip over songs we can't reach (e.g. offline and not downloaded).
    for (var tries = 0; i < _queue.length && tries < 10; i++, tries++) {
      final song = _queue[i];
      _index = i;
      _manualAdds.remove(song.id);
      if (await _load(song)) {
        taste.recordPlay(song);
        _topUp();
        notifyListeners();
        await _player.play();
        return;
      }
    }
    _messages.add(connectivity.online ? 'Could not play that song.' : 'You are offline. Download songs to play them without internet.');
    notifyListeners();
  }

  void _onCompleted() {
    final cur = _current;
    if (room != null) return room!.onTrackEnded();
    if (cur != null) taste.recordComplete(cur);
    _advance();
  }

  Future<bool> _load(Song song) async {
    _current = song;
    notifyListeners();
    Uri uri;
    final local = downloads.localPath(song);
    if (local != null) {
      uri = Uri.file(local);
    } else {
      final url = connectivity.online ? await signer.urlFor(song.storageKey) : null;
      if (url == null) return false;
      uri = Uri.parse(url);
    }
    Uri? art;
    final localCover = downloads.localCover(song);
    if (localCover != null) {
      art = localCover.uri;
    } else if (song.coverKey != null && connectivity.online) {
      final u = await signer.urlFor(song.coverKey!);
      if (u != null) art = Uri.parse(u);
    }
    try {
      await _player.setAudioSource(AudioSource.uri(
        uri,
        tag: MediaItem(id: song.id, title: song.title, artist: song.artist, album: song.album, artUri: art, duration: song.duration),
      ));
      return true;
    } catch (e) {
      debugPrint('Could not load ${song.title}: $e');
      return false;
    }
  }

  // -- used by RoomService ---------------------------------------------------

  Future<bool> roomLoad(Song song) async {
    if (_current?.id == song.id && _player.duration != null) return true;
    return _load(song);
  }

  Future<void> roomPlayFrom(Duration pos) async {
    await _player.seek(pos);
    if (!_player.playing) unawaited(_player.play());
  }

  Future<void> roomPause(Duration pos) async {
    await _player.pause();
    await _player.seek(pos);
  }

  Future<void> roomSeek(Duration pos) => _player.seek(pos);

  Future<void> setRate(double r) => _player.setSpeed(r);

  void roomRecordPlay(Song s) => taste.recordPlay(s);

  void enterRoom(RoomControl r) {
    room = r;
    notifyListeners();
  }

  Future<void> leaveRoom() async {
    room = null;
    await _player.setSpeed(1);
    await _player.pause();
    if (_current != null) {
      _queue = [_current!];
      _index = 0;
      _topUp();
    }
    notifyListeners();
  }

  void notifyRoomChanged() => notifyListeners();

  static bool get backgroundSupported => !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  @override
  void dispose() {
    _player.dispose();
    _messages.close();
    super.dispose();
  }
}
