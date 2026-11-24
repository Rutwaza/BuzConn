import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Lite mode (data saver).
///   auto: on when the phone uses mobile data, off on Wi-Fi (default)
///   on:   always
///   off:  never
/// While active: feed videos wait for a tap instead of downloading and
/// autoplaying, and the next reels are not downloaded in advance.
enum LiteMode { auto, on, off }

class LiteModeService {
  LiteModeService._() {
    _watchNetwork();
  }
  static final LiteModeService instance = LiteModeService._();

  final ValueNotifier<LiteMode> mode = ValueNotifier(LiteMode.auto);
  bool _onMobileData = false;
  StreamSubscription<List<ConnectivityResult>>? _sub;

  /// True when Duhuze should save data right now.
  bool get enabled =>
      mode.value == LiteMode.on || (mode.value == LiteMode.auto && _onMobileData);

  void _watchNetwork() {
    final c = Connectivity();
    void apply(List<ConnectivityResult> r) {
      _onMobileData = r.contains(ConnectivityResult.mobile) &&
          !r.contains(ConnectivityResult.wifi) &&
          !r.contains(ConnectivityResult.ethernet);
    }

    c.checkConnectivity().then(apply).catchError((_) {});
    _sub ??= c.onConnectivityChanged.listen(apply, onError: (_) {});
  }

  Future<void> loadFromUser() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final doc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
    final saved = doc.data()?['liteMode'];
    if (saved is String && LiteMode.values.any((m) => m.name == saved)) {
      mode.value = LiteMode.values.byName(saved);
    }
  }

  Future<void> set(LiteMode m) async {
    mode.value = m;
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).update({
        'liteMode': m.name,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
  }
}
