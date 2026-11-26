import '../../../core/services/r2_storage_service.dart';

/// Group chat actions. Everything goes through the `groupAction` server
/// function (functions/groups.js), which checks who is allowed to do what.
class GroupService {
  GroupService._();
  static final GroupService instance = GroupService._();

  Future<Map<String, dynamic>> _call(Map<String, Object?> data) =>
      R2StorageService.instance.callFunction('groupAction', data);

  /// Returns the new chat id.
  Future<String> create({
    required String name,
    required List<String> memberIds,
    String description = '',
    String? imageUrl,
  }) async {
    final r = await _call({
      'action': 'create',
      'name': name,
      'memberIds': memberIds,
      'description': description,
      if (imageUrl != null) 'imageUrl': imageUrl,
    });
    return r['chatId'] as String;
  }

  Future<int> addMembers(String chatId, List<String> userIds) async {
    final r = await _call({'action': 'add', 'chatId': chatId, 'userIds': userIds});
    return (r['added'] as num?)?.toInt() ?? 0;
  }

  Future<void> remove(String chatId, String userId) =>
      _call({'action': 'remove', 'chatId': chatId, 'userId': userId});
  Future<void> leave(String chatId) =>
      _call({'action': 'leave', 'chatId': chatId});
  Future<void> makeAdmin(String chatId, String userId) =>
      _call({'action': 'promote', 'chatId': chatId, 'userId': userId});
  Future<void> removeAdmin(String chatId, String userId) =>
      _call({'action': 'demote', 'chatId': chatId, 'userId': userId});

  Future<void> updateInfo(String chatId,
          {String? name, String? description, String? imageUrl}) =>
      _call({
        'action': 'update',
        'chatId': chatId,
        if (name != null) 'name': name,
        if (description != null) 'description': description,
        if (imageUrl != null) 'imageUrl': imageUrl,
      });

  Future<void> settings(String chatId,
          {bool? onlyAdminsCanSend, bool? onlyAdminsCanEditInfo}) =>
      _call({
        'action': 'settings',
        'chatId': chatId,
        if (onlyAdminsCanSend != null) 'onlyAdminsCanSend': onlyAdminsCanSend,
        if (onlyAdminsCanEditInfo != null)
          'onlyAdminsCanEditInfo': onlyAdminsCanEditInfo,
      });

  Future<String> resetInvite(String chatId) async {
    final r = await _call({'action': 'resetInvite', 'chatId': chatId});
    return r['inviteCode'] as String;
  }

  /// {chatId, name, imageUrl, description, memberCount, alreadyMember}
  Future<Map<String, dynamic>> preview(String code) =>
      _call({'action': 'preview', 'code': code.trim()});

  Future<String> join(String code) async {
    final r = await _call({'action': 'join', 'code': code.trim()});
    return r['chatId'] as String;
  }

  /// The link people can open to join (also works as a plain code).
  static String inviteLink(String code) =>
      'https://duhuze-rw.web.app/g/$code';

  /// Accepts a full link or just the code.
  static String codeFrom(String input) {
    final t = input.trim();
    final i = t.lastIndexOf('/');
    return i >= 0 ? t.substring(i + 1) : t;
  }
}
