import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

/// Calls our Firebase "callable" Cloud Functions over HTTPS with the signed-in
/// user's ID token. Same approach as [R2StorageService], so no extra package.
class CloudFunctionsClient {
  CloudFunctionsClient._();

  static final CloudFunctionsClient instance = CloudFunctionsClient._();

  static const _region = 'us-central1';

  Future<Map<String, dynamic>> call(
    String functionName,
    Map<String, dynamic> data,
  ) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw StateError('Sign in first.');
    final idToken = await user.getIdToken();
    if (idToken == null || idToken.isEmpty) {
      throw StateError('Could not verify your signed-in account.');
    }

    final projectId = Firebase.app().options.projectId;
    final endpoint = Uri.https(
      '$_region-$projectId.cloudfunctions.net',
      functionName,
    );
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.postUrl(endpoint);
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $idToken');
      request.write(jsonEncode({'data': data}));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final decoded = body.isEmpty ? <String, dynamic>{} : jsonDecode(body);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final message = decoded is Map
            ? (decoded['error']?['message'] ?? decoded['message'])
            : null;
        throw HttpException(message?.toString() ?? 'Request failed.');
      }
      final result = decoded is Map ? (decoded['result'] ?? decoded['data']) : null;
      if (result is Map<String, dynamic>) return result;
      return <String, dynamic>{};
    } finally {
      client.close(force: true);
    }
  }
}
