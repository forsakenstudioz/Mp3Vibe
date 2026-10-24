import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/song.dart';
import 'library_service.dart';
import 'player_service.dart';
import 'recommender.dart';

/// Shared playback for a room. Everyone holds the same small state:
///
///   "song X was at position P at server time T, and is playing / paused"
///
/// plus the queue. From that, each device works out where the song should be
/// right now and nudges its own player to match. Any member can change the
/// state; each change bumps a version number and the highest version wins.
class RoomState {
  const RoomState({
    this.songId,
    this.positionMs = 0,
    this.anchorMs = 0,
    this.playing = false,
    this.queue = const [],
    this.version = 0,
    this.by = '',
  });

  final String? songId;
  final int positionMs;
  final double anchorMs;
  final bool playing;
  final List<String> queue;
  final int version;
  final String by;

  /// Where playback should be at [serverNowMs]. Negative means "starts soon".
  int expectedPositionAt(double serverNowMs) => playing ? positionMs + (serverNowMs - anchorMs).round() : positionMs;

  /// Higher version wins; ties are broken the same way on every device.
  bool isNewerThan(RoomState o) => version > o.version || (version == o.version && by.compareTo(o.by) < 0);

  RoomState copyWith({String? songId, int? positionMs, double? anchorMs, bool? playing, List<String>? queue, int? version, String? by}) =>
      RoomState(
        songId: songId ?? this.songId,
        positionMs: positionMs ?? this.positionMs,
        anchorMs: anchorMs ?? this.anchorMs,
        playing: playing ?? this.playing,
        queue: queue ?? this.queue,
        version: version ?? this.version,
        by: by ?? this.by,
      );

  Map<String, dynamic> toJson() => {
        'song_id': songId,
        'position_ms': positionMs,
        'anchor_ms': anchorMs,
        'playing': playing,
        'queue': queue,
        'version': version,
        'by': by,
      };

  factory RoomState.fromJson(Map<String, dynamic> j) => RoomState(
        songId: j['song_id'] as String?,
        positionMs: (j['position_ms'] as num?)?.toInt() ?? 0,
        anchorMs: (j['anchor_ms'] as num?)?.toDouble() ?? 0,
        playing: j['playing'] as bool? ?? false,
        queue: ((j['queue'] as List?) ?? const []).cast<String>(),
        version: (j['version'] as num?)?.toInt() ?? 0,
        by: j['by'] as String? ?? '',
      );
}

class RoomMember {
  RoomMember(this.userId, this.name);
  final String userId;
  final String name;
}

class ChatMessage {
  ChatMessage(this.name, this.text, this.at, {this.system = false});
  final String name;
  final String text;
  final DateTime at;
  final bool system;
}

class RoomInfo {
  RoomInfo(this.code, this.name, this.activeAt);
  final String code;
  final String name;
  final DateTime activeAt;
}

/// Estimates the gap between this device's clock and the server's, so that
/// "server time T" means the same moment on every device.
class ServerClock {
  ServerClock(this._client);
  final SupabaseClient _client;
  double offsetMs = 0;
  DateTime? _lastSync;

  double get nowMs => DateTime.now().millisecondsSinceEpoch + offsetMs;

  Future<void> sync({bool force = false}) async {
    if (!force && _lastSync != null && DateTime.now().difference(_lastSync!) < const Duration(minutes: 2)) return;
    double? bestRtt;
    for (var i = 0; i < 5; i++) {
      final t0 = DateTime.now().millisecondsSinceEpoch.toDouble();
      final server = (await _client.rpc('server_now') as num).toDouble();
      final t1 = DateTime.now().millisecondsSinceEpoch.toDouble();
      final rtt = t1 - t0;
      // The fastest round trip gives the most trustworthy reading.
      if (bestRtt == null || rtt < bestRtt) {
        bestRtt = rtt;
        offsetMs = server + rtt / 2 - t1;
      }
    }
    _lastSync = DateTime.now();
  }
}

class RoomService extends ChangeNotifier implements RoomControl {
  RoomService(this._client, this.player, this.library, this.recommender) : clock = ServerClock(_client);

  final SupabaseClient _client;
  final PlayerService player;
  final LibraryService library;
  final Recommender recommender;
  final ServerClock clock;

  /// How far ahead a new song is scheduled, so every device has time to buffer it.
  static const _startLeadMs = 1500;

  RealtimeChannel? _channel;
  String? code;
  String? roomName;
  String myName = 'Listener';
  RoomState state = const RoomState();
  List<RoomMember> members = [];
  final List<ChatMessage> chat = [];
  final _reactions = StreamController<String>.broadcast();
  Timer? _driftTimer;
  Timer? _startTimer;
  String? _loadedSongId;
  bool connected = false;

  /// How far this device is from the room, for the sync indicator.
  int driftMs = 0;

  Stream<String> get reactions => _reactions.stream;
  bool get inRoom => code != null;
  String get _me => _client.auth.currentUser!.id;

  // -- rooms list -------------------------------------------------------------

  Future<List<RoomInfo>> recentRooms() async {
    final rows = await _client.from('rooms').select('code, name, active_at').order('active_at', ascending: false).limit(20);
    return rows.map((r) => RoomInfo(r['code'] as String, r['name'] as String, DateTime.parse(r['active_at'] as String))).toList();
  }

  Future<String> create(String name) async {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rng = math.Random.secure();
    for (var attempt = 0; attempt < 5; attempt++) {
      final c = List.generate(6, (_) => alphabet[rng.nextInt(alphabet.length)]).join();
      try {
        await _client.from('rooms').insert({'code': c, 'name': name});
        return c;
      } on PostgrestException catch (e) {
        if (e.code != '23505') rethrow; // code already taken: try another
      }
    }
    throw Exception('Could not create a room, please try again.');
  }

  // -- joining and leaving ------------------------------------------------------

  Future<void> join(String roomCode) async {
    roomCode = roomCode.trim().toUpperCase();
    if (code == roomCode) return;
    if (inRoom) await leave();

    final row = await _client.from('rooms').select().eq('code', roomCode).maybeSingle();
    if (row == null) throw Exception('No room with code $roomCode');
    await clock.sync(force: true);

    final profile = await _client.from('profiles').select('display_name').eq('id', _me).maybeSingle();
    myName = profile?['display_name'] as String? ?? _client.auth.currentUser?.email?.split('@').first ?? 'Listener';

    code = roomCode;
    roomName = row['name'] as String;
    chat.clear();
    members = [];
    state = RoomState.fromJson((row['state'] as Map?)?.cast<String, dynamic>() ?? {});
    state = _settleStale(state);
    player.enterRoom(this);
    notifyListeners();

    final ch = _client.channel('room:$roomCode', opts: RealtimeChannelConfig(key: _me));
    _channel = ch;
    ch
        .onBroadcast(event: 'state', callback: (p) => _receiveState(_body(p)))
        .onBroadcast(event: 'hello', callback: (p) {
          // Someone joined: tell them what's playing.
          if (state.version > 0) _broadcast('state', state.toJson());
        })
        .onBroadcast(event: 'chat', callback: (p) {
          final b = _body(p);
          _addChat(ChatMessage(b['name'] as String? ?? '?', b['text'] as String? ?? '', DateTime.now()));
        })
        .onBroadcast(event: 'react', callback: (p) => _reactions.add(_body(p)['emoji'] as String? ?? '❤️'))
        .onPresenceSync((_) => _updateMembers())
        .onPresenceJoin((p) {
          for (final pr in p.newPresences) {
            if (pr.payload['user_id'] != _me) _addChat(ChatMessage('', '${pr.payload['name']} joined', DateTime.now(), system: true));
          }
        })
        .onPresenceLeave((p) {
          for (final pr in p.leftPresences) {
            _addChat(ChatMessage('', '${pr.payload['name']} left', DateTime.now(), system: true));
          }
        })
        .subscribe((status, error) async {
          connected = status == RealtimeSubscribeStatus.subscribed;
          notifyListeners();
          if (connected) {
            await ch.track({'user_id': _me, 'name': myName});
            _broadcast('hello', {});
          }
        });

    await _apply();
    _driftTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) => _correctDrift());
  }

  Future<void> leave() async {
    _driftTimer?.cancel();
    _startTimer?.cancel();
    final ch = _channel;
    _channel = null;
    if (ch != null) {
      await ch.untrack();
      await _client.removeChannel(ch);
    }
    code = null;
    roomName = null;
    members = [];
    state = const RoomState();
    _loadedSongId = null;
    connected = false;
    await player.leaveRoom();
    notifyListeners();
  }

  /// A room nobody was in for longer than the song: don't jump to a random spot.
  RoomState _settleStale(RoomState s) {
    final song = library.byId(s.songId);
    if (song == null || !s.playing) return s;
    final expected = s.expectedPositionAt(clock.nowMs);
    if (song.durationMs > 0 && expected > song.durationMs) {
      return s.copyWith(playing: false, positionMs: 0);
    }
    return s;
  }

  Map<String, dynamic> _body(Map<String, dynamic> p) {
    final inner = p['payload'];
    return inner is Map ? inner.cast<String, dynamic>() : p;
  }

  void _broadcast(String event, Map<String, dynamic> body) {
    _channel?.sendBroadcastMessage(event: event, payload: body);
  }

  void _updateMembers() {
    final ch = _channel;
    if (ch == null) return;
    final seen = <String, RoomMember>{};
    for (final s in ch.presenceState()) {
      for (final p in s.presences) {
        final id = p.payload['user_id'] as String? ?? s.key;
        seen[id] = RoomMember(id, p.payload['name'] as String? ?? 'Listener');
      }
    }
    members = seen.values.toList();
    notifyListeners();
  }

  void _addChat(ChatMessage m) {
    chat.add(m);
    if (chat.length > 200) chat.removeAt(0);
    notifyListeners();
  }

  // -- state changes ------------------------------------------------------------

  void _receiveState(Map<String, dynamic> json) {
    final incoming = RoomState.fromJson(json);
    if (!incoming.isNewerThan(state)) return;
    state = incoming;
    notifyListeners();
    player.notifyRoomChanged();
    _apply();
  }

  /// Make a change and share it with the room.
  void _commit(RoomState Function(RoomState s, double now) change) {
    final now = clock.nowMs;
    state = change(state, now).copyWith(version: state.version + 1, by: _me);
    notifyListeners();
    player.notifyRoomChanged();
    _broadcast('state', state.toJson());
    _client.rpc('update_room_state', params: {'p_code': code, 'p_state': state.toJson()}).then((_) {}, onError: (_) {});
    _apply();
  }

  Future<void> _applying = Future.value();

  /// Bring this device's player in line with the room state. Runs one at a
  /// time so a burst of changes can't interleave half-finished loads.
  Future<void> _apply() => _applying = _applying.then((_) => _applyNow()).catchError((Object e) {
        debugPrint('Room sync error: $e');
      });

  Future<void> _applyNow() async {
    _startTimer?.cancel();
    final song = library.byId(state.songId);
    if (song == null) {
      if (state.songId != null) await player.roomPause(Duration.zero);
      return;
    }
    if (_loadedSongId != song.id) {
      final ok = await player.roomLoad(song);
      if (!ok) {
        _addChat(ChatMessage('', 'Could not load "${song.title}" on this device', DateTime.now(), system: true));
        return;
      }
      _loadedSongId = song.id;
      player.roomRecordPlay(song);
    }
    if (!state.playing) {
      await player.setRate(1);
      await player.roomPause(Duration(milliseconds: state.positionMs));
      return;
    }
    final expected = state.expectedPositionAt(clock.nowMs);
    if (expected < 0) {
      // Scheduled start: get ready at 0, then go at exactly the shared moment.
      await player.roomPause(Duration.zero);
      _startTimer = Timer(Duration(milliseconds: -expected), () {
        player.roomPlayFrom(Duration(milliseconds: math.max(0, state.expectedPositionAt(clock.nowMs))));
      });
    } else {
      await player.roomPlayFrom(Duration(milliseconds: expected));
    }
  }

  /// Small differences are fixed by playing slightly faster or slower (nobody
  /// notices 3%); big ones by jumping.
  Future<void> _correctDrift() async {
    if (!state.playing || _loadedSongId == null || _loadedSongId != state.songId) return;
    final expected = state.expectedPositionAt(clock.nowMs);
    if (expected < 0) return;
    // Near the end the song is about to finish on its own; let it.
    final total = player.duration?.inMilliseconds ?? library.byId(state.songId)?.durationMs ?? 0;
    if (total > 0 && expected > total - 800) return;
    if (!player.playing) {
      await player.roomPlayFrom(Duration(milliseconds: expected));
      return;
    }
    final drift = player.position.inMilliseconds - expected;
    driftMs = drift;
    if (drift.abs() > 400) {
      await player.setRate(1);
      await player.roomSeek(Duration(milliseconds: expected + 60));
    } else if (drift.abs() > 40) {
      await player.setRate((1 - drift / 3000).clamp(0.97, 1.03));
    } else {
      await player.setRate(1);
    }
    notifyListeners();
    unawaited(clock.sync());
  }

  // -- RoomControl: button presses from anyone in the room ---------------------

  @override
  void requestPlay(Song song) => _commit((s, now) => s.copyWith(
        songId: song.id,
        positionMs: 0,
        anchorMs: now + _startLeadMs,
        playing: true,
        queue: s.queue.where((id) => id != song.id).toList(),
      ));

  @override
  void requestToggle() {
    if (state.songId == null) {
      requestNext();
      return;
    }
    _commit((s, now) {
      final pos = math.max(0, s.expectedPositionAt(now));
      return s.copyWith(playing: !s.playing, positionMs: pos, anchorMs: now + (s.playing ? 0 : 300));
    });
  }

  @override
  void requestSeek(Duration position) =>
      _commit((s, now) => s.copyWith(positionMs: position.inMilliseconds, anchorMs: now + 300));

  @override
  void requestEnqueue(Song song) {
    if (state.songId == null) return requestPlay(song);
    _commit((s, now) => s.copyWith(queue: [...s.queue, song.id]));
    _broadcast('chat', {'name': myName, 'text': 'queued "${song.title}"'});
    _addChat(ChatMessage(myName, 'queued "${song.title}"', DateTime.now()));
  }

  void removeFromQueue(String songId) => _commit((s, now) => s.copyWith(queue: s.queue.where((id) => id != songId).toList()));

  @override
  void requestNext() {
    final expectedVersion = state.version;
    final queue = List<String>.of(state.queue);
    String? nextId;
    while (queue.isNotEmpty && nextId == null) {
      final id = queue.removeAt(0);
      if (library.byId(id) != null) nextId = id;
    }
    // Empty queue: the room DJ picks something that fits what was playing.
    nextId ??= recommender
        .nextUp(pool: library.songs, current: library.byId(state.songId), count: 1, exclude: state.queue.toSet())
        .firstOrNull
        ?.id;
    if (nextId == null || state.version != expectedVersion) return;
    final id = nextId;
    _commit((s, now) => s.copyWith(songId: id, positionMs: 0, anchorMs: now + _startLeadMs, playing: true, queue: queue));
  }

  @override
  void onTrackEnded() {
    // Everyone's player ends at about the same moment and all of them ask for
    // the next song. They pick the same one and the version rule settles it.
    final endedVersion = state.version;
    final jitter = math.Random().nextInt(400);
    Timer(Duration(milliseconds: jitter), () {
      if (state.version == endedVersion && inRoom) requestNext();
    });
  }

  @override
  List<Song> get upNext => state.queue.map(library.byId).whereType<Song>().toList();

  // -- chat ----------------------------------------------------------------------

  void sendChat(String text) {
    text = text.trim();
    if (text.isEmpty) return;
    _broadcast('chat', {'name': myName, 'text': text});
    _addChat(ChatMessage(myName, text, DateTime.now()));
  }

  void react(String emoji) {
    _broadcast('react', {'emoji': emoji});
    _reactions.add(emoji);
  }

  @override
  void dispose() {
    _driftTimer?.cancel();
    _startTimer?.cancel();
    _reactions.close();
    super.dispose();
  }
}
