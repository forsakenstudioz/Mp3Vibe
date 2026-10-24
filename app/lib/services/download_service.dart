import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';
import 'url_signer.dart';

/// Keeps songs on the device for offline listening.
class DownloadService extends ChangeNotifier {
  DownloadService(this._signer);

  final UrlSigner _signer;
  late Directory _dir;
  final Set<String> _done = {};
  final Map<String, double> progress = {};
  final List<Song> _queue = [];
  int _active = 0;
  static const _parallel = 2;

  /// Automatically keep liked songs offline.
  bool autoDownloadLiked = true;

  Future<void> start() async {
    final base = await getApplicationSupportDirectory();
    _dir = Directory('${base.path}/downloads');
    await _dir.create(recursive: true);
    await for (final f in _dir.list()) {
      final name = f.uri.pathSegments.last;
      if (name.endsWith('.part') || name.endsWith('.cover')) continue;
      final dot = name.lastIndexOf('.');
      if (dot > 0) _done.add(name.substring(0, dot));
    }
    final prefs = await SharedPreferences.getInstance();
    autoDownloadLiked = prefs.getBool('auto_download_liked') ?? true;
    notifyListeners();
  }

  Future<void> setAutoDownloadLiked(bool v) async {
    autoDownloadLiked = v;
    notifyListeners();
    (await SharedPreferences.getInstance()).setBool('auto_download_liked', v);
  }

  bool isDownloaded(String id) => _done.contains(id);
  bool isDownloading(String id) => progress.containsKey(id);
  int get count => _done.length;

  String _audioPath(Song s) => '${_dir.path}/${s.id}.${s.fileExt}';
  String coverPath(String songId) => '${_dir.path}/$songId.cover';

  String? localPath(Song s) => isDownloaded(s.id) ? _audioPath(s) : null;

  File? localCover(Song s) {
    if (!isDownloaded(s.id)) return null;
    final f = File(coverPath(s.id));
    return f.existsSync() ? f : null;
  }

  void download(Song s) {
    if (isDownloaded(s.id) || isDownloading(s.id)) return;
    progress[s.id] = 0;
    _queue.add(s);
    notifyListeners();
    _pump();
  }

  void downloadAll(Iterable<Song> songs) {
    for (final s in songs) {
      download(s);
    }
  }

  void _pump() {
    while (_active < _parallel && _queue.isNotEmpty) {
      final s = _queue.removeAt(0);
      _active++;
      _fetch(s).whenComplete(() {
        _active--;
        _pump();
      });
    }
  }

  Future<void> _fetch(Song s) async {
    final part = File('${_audioPath(s)}.part');
    try {
      final url = await _signer.urlFor(s.storageKey);
      if (url == null) throw Exception('offline');
      final res = await http.Client().send(http.Request('GET', Uri.parse(url)));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final total = res.contentLength ?? s.fileSize;
      var got = 0;
      final sink = part.openWrite();
      await for (final chunk in res.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) {
          progress[s.id] = got / total;
          notifyListeners();
        }
      }
      await sink.close();
      await part.rename(_audioPath(s));
      if (s.coverKey != null) {
        final coverUrl = await _signer.urlFor(s.coverKey!);
        if (coverUrl != null) {
          final c = await http.get(Uri.parse(coverUrl));
          if (c.statusCode == 200) await File(coverPath(s.id)).writeAsBytes(c.bodyBytes);
        }
      }
      _done.add(s.id);
    } catch (e) {
      if (await part.exists()) await part.delete();
      debugPrint('Download failed for ${s.title}: $e');
    } finally {
      progress.remove(s.id);
      notifyListeners();
    }
  }

  Future<void> remove(Song s) async {
    _done.remove(s.id);
    notifyListeners();
    for (final p in [_audioPath(s), coverPath(s.id)]) {
      final f = File(p);
      if (await f.exists()) await f.delete();
    }
  }

  Future<int> bytesUsed() async {
    var total = 0;
    await for (final f in _dir.list()) {
      if (f is File) total += await f.length();
    }
    return total;
  }
}
