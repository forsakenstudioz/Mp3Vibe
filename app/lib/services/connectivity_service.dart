import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

class ConnectivityService extends ChangeNotifier {
  bool online = true;
  StreamSubscription<List<ConnectivityResult>>? _sub;

  Future<void> start() async {
    _apply(await Connectivity().checkConnectivity());
    _sub = Connectivity().onConnectivityChanged.listen(_apply);
  }

  void _apply(List<ConnectivityResult> results) {
    final now = results.any((r) => r != ConnectivityResult.none);
    if (now != online) {
      online = now;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
