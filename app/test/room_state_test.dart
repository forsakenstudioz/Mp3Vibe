import 'package:flutter_test/flutter_test.dart';
import 'package:vibe/services/room_service.dart';

void main() {
  test('expected position advances only while playing', () {
    const s = RoomState(songId: 'a', positionMs: 10000, anchorMs: 1000000, playing: true, version: 3);
    expect(s.expectedPositionAt(1000000), 10000);
    expect(s.expectedPositionAt(1002500), 12500);
    expect(s.copyWith(playing: false).expectedPositionAt(1002500), 10000);
  });

  test('scheduled start gives a negative position before the anchor', () {
    const s = RoomState(songId: 'a', positionMs: 0, anchorMs: 5000, playing: true);
    expect(s.expectedPositionAt(3500), -1500);
  });

  test('newer version wins and ties resolve the same way everywhere', () {
    const a = RoomState(version: 5, by: 'alice');
    const b = RoomState(version: 5, by: 'bob');
    const c = RoomState(version: 6, by: 'zed');
    expect(c.isNewerThan(a), isTrue);
    expect(a.isNewerThan(c), isFalse);
    expect(a.isNewerThan(b), isTrue);
    expect(b.isNewerThan(a), isFalse);
  });

  test('state survives a JSON round trip', () {
    const s = RoomState(songId: 'x', positionMs: 42, anchorMs: 123.5, playing: true, queue: ['y', 'z'], version: 9, by: 'me');
    final back = RoomState.fromJson(s.toJson());
    expect(back.songId, 'x');
    expect(back.queue, ['y', 'z']);
    expect(back.anchorMs, 123.5);
    expect(back.version, 9);
  });
}
