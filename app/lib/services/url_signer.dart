import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Gets short-lived download links for files in the private R2 bucket.
///
/// Requests made close together are batched into one call, and links are
/// reused until shortly before they expire.
class UrlSigner {
  UrlSigner(this._client);

  final SupabaseClient _client;
  final _cache = <String, ({String url, DateTime expires})>{};
  final _waiting = <String, List<Completer<String?>>>{};
  Timer? _flush;

  Future<String?> urlFor(String key) {
    final hit = _cache[key];
    if (hit != null && hit.expires.isAfter(DateTime.now().add(const Duration(minutes: 20)))) {
      return Future.value(hit.url);
    }
    final c = Completer<String?>();
    _waiting.putIfAbsent(key, () => []).add(c);
    _flush ??= Timer(const Duration(milliseconds: 40), _send);
    return c.future;
  }

  Future<void> _send() async {
    _flush = null;
    final batch = Map.of(_waiting);
    _waiting.clear();
    final keys = batch.keys.toList();
    for (var i = 0; i < keys.length; i += 200) {
      final chunk = keys.sublist(i, i + 200 > keys.length ? keys.length : i + 200);
      Map<String, dynamic> urls = const {};
      var lifetime = 3600;
      try {
        final res = await _client.functions.invoke('sign-url', body: {'keys': chunk});
        final data = res.data as Map<String, dynamic>;
        urls = (data['urls'] as Map).cast<String, dynamic>();
        lifetime = (data['expires_in'] as num?)?.toInt() ?? lifetime;
      } catch (_) {
        // Offline or not configured yet: callers fall back to downloaded files.
      }
      final expires = DateTime.now().add(Duration(seconds: lifetime));
      for (final k in chunk) {
        final url = urls[k] as String?;
        if (url != null) _cache[k] = (url: url, expires: expires);
        for (final c in batch[k]!) {
          c.complete(url);
        }
      }
    }
  }
}
