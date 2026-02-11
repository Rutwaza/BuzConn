import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseStorageService {
  SupabaseStorageService._();

  static final SupabaseStorageService instance = SupabaseStorageService._();

  SupabaseClient get _client => Supabase.instance.client;

  Future<String?> uploadImage({
    required String bucket,
    required String path,
    required Uint8List bytes,
  }) async {
    return _upload(
      bucket: bucket,
      path: path,
      bytes: bytes,
      contentType: 'image/jpeg',
    );
  }

  Future<String?> uploadVideo({
    required String bucket,
    required String path,
    required Uint8List bytes,
  }) async {
    return _upload(
      bucket: bucket,
      path: path,
      bytes: bytes,
      contentType: 'video/mp4',
    );
  }

  Future<String?> _upload({
    required String bucket,
    required String path,
    required Uint8List bytes,
    required String contentType,
  }) async {
    await _client.storage.from(bucket).uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: contentType, upsert: true),
        );
    return _client.storage.from(bucket).getPublicUrl(path);
  }
}
