import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

class NetworkStatusBanner extends StatefulWidget {
  const NetworkStatusBanner({super.key, required this.child});

  final Widget child;

  @override
  State<NetworkStatusBanner> createState() => _NetworkStatusBannerState();
}

class _NetworkStatusBannerState extends State<NetworkStatusBanner> {
  final _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _sub;
  Timer? _probeTimer;
  Timer? _onlineHideTimer;
  _NetStatus _status = _NetStatus.hidden;
  bool _wasOffline = false;

  @override
  void initState() {
    super.initState();
    _sub = _connectivity.onConnectivityChanged.listen((results) {
      _handleConnectivity(results);
    });
    _connectivity.checkConnectivity().then(_handleConnectivity);
    _startProbing();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _probeTimer?.cancel();
    _onlineHideTimer?.cancel();
    super.dispose();
  }

  void _handleConnectivity(List<ConnectivityResult> results) {
    final hasConnection = results.any((r) =>
        r == ConnectivityResult.mobile || r == ConnectivityResult.wifi);
    if (!hasConnection) {
      _setStatus(_NetStatus.offline);
    } else {
      _probeOnce();
    }
  }

  void _startProbing() {
    _probeTimer?.cancel();
    _probeTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      _probeOnce();
    });
  }

  Future<void> _probeOnce() async {
    final result = await _checkNetworkQuality();
    _setStatus(result);
  }

  void _setStatus(_NetStatus next) {
    if (!mounted) return;
    if (_status == next) return;
    _onlineHideTimer?.cancel();
    if (next == _NetStatus.online && !_wasOffline) {
      // Don't show "online" on first launch if we never went offline.
      setState(() => _status = _NetStatus.hidden);
      return;
    }
    setState(() => _status = next);
    if (next == _NetStatus.offline) {
      _wasOffline = true;
    }
    if (next == _NetStatus.online) {
      _wasOffline = false;
      _onlineHideTimer = Timer(const Duration(seconds: 3), () {
        if (mounted && _status == _NetStatus.online) {
          setState(() => _status = _NetStatus.hidden);
        }
      });
    }
  }

  Future<_NetStatus> _checkNetworkQuality() async {
    final sw = Stopwatch()..start();
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 3);
      final request = await client
          .getUrl(Uri.parse('https://www.google.com/generate_204'))
          .timeout(const Duration(seconds: 3));
      final response = await request.close().timeout(const Duration(seconds: 3));
      await response.drain();
      client.close(force: true);
      sw.stop();
      final ms = sw.elapsedMilliseconds;
      return _NetStatus.online;
    } catch (_) {
      return _NetStatus.offline;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (_status != _NetStatus.hidden)
          Positioned(
            left: 0,
            right: 0,
            bottom: 16,
            child: SafeArea(
              top: false,
              child: Center(
                child: AnimatedOpacity(
                  opacity: _status == _NetStatus.hidden ? 0 : 1,
                  duration: const Duration(milliseconds: 250),
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: _status == _NetStatus.offline
                          ? Colors.red.shade700
                          : Colors.green.shade700,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.2),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Icon(
                      _status == _NetStatus.offline
                          ? Icons.wifi_off
                          : Icons.wifi,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

enum _NetStatus { hidden, offline, online }
