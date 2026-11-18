import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

class R2StorageService {
  R2StorageService._();

  static final R2StorageService instance = R2StorageService._();
  static final Map<String, ({String url, DateTime expiresAt})> _downloadCache = {};

  static const _functionsRegion = 'us-central1';
  static const _maxUploadBytes = 250 * 1024 * 1024;

  Future<String?> uploadImage({
    required String bucket,
    required String path,
    required Uint8List bytes,
    String? chatId,
  }) {
    return _upload(
      bucket: bucket,
      path: path,
      bytes: bytes,
      contentType: 'image/jpeg',
      chatId: chatId,
    );
  }

  Future<String?> uploadVideo({
    required String bucket,
    required String path,
    required Uint8List bytes,
    String? chatId,
  }) {
    return _upload(
      bucket: bucket,
      path: path,
      bytes: bytes,
      contentType: 'video/mp4',
      chatId: chatId,
    );
  }

  Future<String?> uploadAudio({
    required String bucket,
    required String path,
    required Uint8List bytes,
    String? chatId,
  }) {
    return _upload(
      bucket: bucket,
      path: path,
      bytes: bytes,
      contentType: 'audio/mp4',
      chatId: chatId,
    );
  }

  Future<String?> uploadFile({
    required String bucket,
    required String path,
    required Uint8List bytes,
    String contentType = 'application/octet-stream',
    String? chatId,
  }) {
    return _upload(
      bucket: bucket,
      path: path,
      bytes: bytes,
      contentType: contentType,
      chatId: chatId,
    );
  }

  Future<String> downloadPrivateMediaUrl({
    required String mediaRef,
    required String chatId,
  }) async {
    if (!mediaRef.startsWith('r2://')) return mediaRef;
    final objectKey = mediaRef.substring('r2://'.length);
    final cacheKey = '$chatId:$objectKey';
    final cached = _downloadCache[cacheKey];
    if (cached != null && DateTime.now().isBefore(cached.expiresAt)) {
      return cached.url;
    }

    final result = await _callFunction('createR2DownloadUrl', {
      'chatId': chatId,
      'objectKey': objectKey,
    });
    final url = result['url'] as String?;
    if (url == null || url.isEmpty) {
      throw const FormatException('The download link was not returned.');
    }
    final expiresIn = (result['expiresIn'] as num?)?.toInt() ?? 900;
    _downloadCache[cacheKey] = (
      url: url,
      expiresAt: DateTime.now().add(Duration(seconds: expiresIn - 30)),
    );
    return url;
  }

  Future<String?> _upload({
    required String bucket,
    required String path,
    required Uint8List bytes,
    required String contentType,
    String? chatId,
  }) async {
    if (bytes.isEmpty || bytes.length > _maxUploadBytes) {
      throw const FormatException('Files must be smaller than 250 MB.');
    }
    final upload = await _callFunction('createR2UploadUrl', {
      'category': bucket,
      'fileName': path.split('/').last,
      'contentType': contentType,
      'sizeBytes': bytes.length,
      if (chatId != null) 'chatId': chatId,
    });
    final uploadUrl = upload['uploadUrl'] as String?;
    if (uploadUrl == null || uploadUrl.isEmpty) {
      throw const FormatException('The upload link was not returned.');
    }

    final client = HttpClient();
    try {
      final request = await client.putUrl(Uri.parse(uploadUrl));
      request.headers.set(HttpHeaders.contentTypeHeader, contentType);
      request.contentLength = bytes.length;
      request.add(bytes);
      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final code = RegExp(r'<Code>(.*?)</Code>')
            .firstMatch(responseBody)
            ?.group(1);
        final message = RegExp(r'<Message>(.*?)</Message>')
            .firstMatch(responseBody)
            ?.group(1);
        final details = [code, message]
            .whereType<String>()
            .where((value) => value.isNotEmpty)
            .join(': ');
        throw HttpException(
          'R2 upload failed (${response.statusCode})'
          '${details.isEmpty ? '.' : ': $details'}',
        );
      }
    } finally {
      client.close(force: true);
    }

    if (upload['mediaRef'] is String) return upload['mediaRef'] as String;
    return upload['publicUrl'] as String?;
  }

  Future<Map<String, dynamic>> _callFunction(
    String functionName,
    Map<String, Object?> data,
  ) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw StateError('Sign in before uploading media.');
    final idToken = await user.getIdToken();
    if (idToken == null || idToken.isEmpty) {
      throw StateError('Could not verify your signed-in account.');
    }

    final projectId = Firebase.app().options.projectId;
    final endpoint = Uri.https(
      '$_functionsRegion-$projectId.cloudfunctions.net',
      functionName,
    );
    final client = HttpClient();
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
        throw HttpException(message?.toString() ?? 'Media request failed.');
      }
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid response from media service.');
      }
      final result = decoded['result'] ?? decoded['data'];
      if (result is! Map<String, dynamic>) {
        throw const FormatException('Invalid response from media service.');
      }
      return result;
    } finally {
      client.close(force: true);
    }
  }
}
