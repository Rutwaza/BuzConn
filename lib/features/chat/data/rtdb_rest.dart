import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../../../core/constants/app_constants.dart';

/// A tiny Realtime Database client over HTTPS, for Windows.
///
/// The firebase_database plugin has no Windows version, so on desktop we talk
/// to the database's REST API instead: normal requests to write, and the
/// "streaming" mode (Server-Sent Events) to get live updates. The same
/// security rules apply (we send the user's ID token).
/// Docs: https://firebase.google.com/docs/reference/rest/database
class RtdbRest {
  RtdbRest._();
  static final RtdbRest instance = RtdbRest._();

  final HttpClient _http = HttpClient()..connectionTimeout = const Duration(seconds: 20);

  /// Firebase's "server time" placeholder.
  static const Map<String, String> serverTimestamp = {'.sv': 'timestamp'};

  Future<Uri?> _uri(String path, {bool forceRefresh = false}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;
    final token = await user.getIdToken(forceRefresh);
    return Uri.parse('${AppConstants.realtimeDatabaseUrl}/$path.json')
        .replace(queryParameters: {'auth': token});
  }

  Future<void> _send(String method, String path, [Object? body]) async {
    final uri = await _uri(path);
    if (uri == null) return;
    final req = await _http.openUrl(method, uri);
    req.headers.contentType = ContentType.json;
    if (body != null) req.write(jsonEncode(body));
    final res = await req.close();
    await res.drain<void>();
    if (res.statusCode >= 300) {
      throw HttpException('RTDB $method $path failed (${res.statusCode})');
    }
  }

  Future<void> put(String path, Object? value) => _send('PUT', path, value);

  Future<void> delete(String path) => _send('DELETE', path);

  /// Live value of [path]. Emits the whole value (Map, bool, String, ... or
  /// null) every time it changes. Reconnects by itself (network drops,
  /// expired token).
  Stream<Object?> watch(String path) {
    late StreamController<Object?> controller;
    HttpClientRequest? request;
    StreamSubscription<String>? lines;
    Timer? retry;
    var closed = false;
    var attempt = 0;
    Object? value;
    late final void Function() scheduleRetry;

    void applyEvent(String event, String data) {
      switch (event) {
        case 'put':
        case 'patch':
          final decoded = jsonDecode(data) as Map<String, dynamic>;
          final sub = (decoded['path'] as String?) ?? '/';
          final incoming = decoded['data'];
          if (sub == '/') {
            value = event == 'put'
                ? incoming
                : {...(value is Map ? value as Map : {}), ...(incoming as Map? ?? {})};
          } else {
            // A change below our path: update that child.
            final map = Map<String, dynamic>.from(value is Map ? value as Map : {});
            final key = sub.substring(1).split('/').first;
            if (incoming == null) {
              map.remove(key);
            } else {
              map[key] = incoming;
            }
            value = map.isEmpty ? null : map;
          }
          controller.add(value);
        case 'auth_revoked':
        case 'cancel':
          // Token expired (every hour) or rules said no: reconnect with a
          // fresh token (cancel() does not fire onDone, so retry here).
          lines?.cancel();
          scheduleRetry();
      }
    }

    Future<void> connect() async {
      if (closed) return;
      try {
        final uri = await _uri(path, forceRefresh: attempt > 0);
        if (uri == null || closed) return;
        request = await _http.getUrl(uri);
        request!.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
        request!.followRedirects = true;
        final res = await request!.close();
        if (res.statusCode != 200) throw HttpException('stream ${res.statusCode}');
        attempt = 0;
        var event = '';
        lines = res.transform(utf8.decoder).transform(const LineSplitter()).listen(
          (line) {
            if (line.startsWith('event:')) {
              event = line.substring(6).trim();
            } else if (line.startsWith('data:')) {
              try {
                applyEvent(event, line.substring(5).trim());
              } catch (e) {
                if (kDebugMode) debugPrint('RTDB stream parse ($path): $e');
              }
            }
          },
          onDone: () => scheduleRetry(),
          onError: (_) => scheduleRetry(),
          cancelOnError: true,
        );
      } catch (e) {
        if (kDebugMode) debugPrint('RTDB stream ($path): $e');
        scheduleRetry();
      }
    }

    scheduleRetry = () {
      if (closed) return;
      retry?.cancel();
      attempt++;
      final seconds = attempt > 5 ? 30 : attempt * 2;
      retry = Timer(Duration(seconds: seconds), connect);
    };

    controller = StreamController<Object?>(
      onListen: connect,
      onCancel: () async {
        closed = true;
        retry?.cancel();
        await lines?.cancel();
        request?.abort();
      },
    );
    return controller.stream;
  }
}
