import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/i18n/tr.dart';
import '../../core/theme/colors.dart';

/// Report and block (required by Google Play for apps with user content).
///
/// Reports go to `reports/{id}` (only admins can read them; the server
/// notifies the admin: functions/moderation.js). Blocks are kept in
/// `users/{me}/blocked/{otherUid}`: their posts and statuses are hidden for
/// me, and the rules stop them from sending me messages.
class BlockService {
  BlockService._();
  static final BlockService instance = BlockService._();

  final ValueNotifier<Set<String>> blocked = ValueNotifier(<String>{});
  final _db = FirebaseFirestore.instance;

  bool isBlocked(String? uid) => uid != null && blocked.value.contains(uid);

  CollectionReference<Map<String, dynamic>>? get _mine {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    return uid == null ? null : _db.collection('users').doc(uid).collection('blocked');
  }

  Future<void> load() async {
    final ref = _mine;
    if (ref == null) return;
    final snap = await ref.limit(1000).get();
    blocked.value = snap.docs.map((d) => d.id).toSet();
  }

  Future<void> block(String uid) async {
    await _mine?.doc(uid).set({'createdAt': FieldValue.serverTimestamp()});
    blocked.value = {...blocked.value, uid};
  }

  Future<void> unblock(String uid) async {
    await _mine?.doc(uid).delete();
    blocked.value = {...blocked.value}..remove(uid);
  }
}

const _reasons = <String, String>{
  'spam': 'Spam or misleading',
  'sexual': 'Nudity or sexual content',
  'child_safety': 'Child safety',
  'hate': 'Hate speech or harassment',
  'violence': 'Violence or threats',
  'scam': 'Scam, fraud or fake shop',
  'fake': 'Fake account or impersonation',
  'other': 'Something else',
};

/// Asks why, then saves the report. [targetType]: post, user, chat, status,
/// comment or page.
Future<void> showReportSheet(
  BuildContext context, {
  required String targetType,
  required String targetId,
  String? targetOwnerId,
  String? preview,
}) async {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) return;
  final details = TextEditingController();
  final messenger = ScaffoldMessenger.of(context);
  final reason = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(tr('Why are you reporting this?'),
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: TextField(
                  controller: details,
                  maxLength: 500,
                  maxLines: 2,
                  decoration: InputDecoration(labelText: tr('More details (optional)')),
                ),
              ),
              for (final e in _reasons.entries)
                ListTile(
                  leading: Icon(
                    e.key == 'child_safety' ? Icons.child_care_rounded : Icons.flag_outlined,
                    color: e.key == 'child_safety' ? AppColors.error : null,
                  ),
                  title: Text(tr(e.value)),
                  onTap: () => Navigator.of(context).pop(e.key),
                ),
            ],
          ),
        ),
      ),
    ),
  );
  final text = details.text.trim();
  details.dispose();
  if (reason == null) return;
  try {
    await FirebaseFirestore.instance.collection('reports').add({
      'reporterId': uid,
      'targetType': targetType,
      'targetId': targetId,
      'targetOwnerId': targetOwnerId,
      'reason': reason,
      'details': text,
      'preview': (preview ?? '').length > 300 ? preview!.substring(0, 300) : (preview ?? ''),
      'status': 'open',
      'createdAt': FieldValue.serverTimestamp(),
    });
    messenger.showSnackBar(SnackBar(content: Text(tr('Thank you. We will review this report.'))));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('${tr('Could not send the report.')} $e')));
  }
}

/// Block with a confirmation. Returns true when blocked.
Future<bool> confirmBlock(BuildContext context, {required String userId, required String name}) async {
  final messenger = ScaffoldMessenger.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('${tr('Block')} $name?'),
      content: Text(tr('You will not see their posts or statuses, and they cannot message you. They are not told.')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.error),
          onPressed: () => Navigator.pop(context, true),
          child: Text(tr('Block')),
        ),
      ],
    ),
  );
  if (ok != true) return false;
  await BlockService.instance.block(userId);
  messenger.showSnackBar(SnackBar(content: Text('$name ${tr('is blocked.')}')));
  return true;
}

/// Bottom sheet with Report + Block/Unblock for a person.
Future<void> showUserSafetySheet(
  BuildContext context, {
  required String userId,
  required String name,
  String reportType = 'user',
  String? reportId,
  String? preview,
}) async {
  if (userId == FirebaseAuth.instance.currentUser?.uid) return;
  final isBlocked = BlockService.instance.isBlocked(userId);
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.flag_outlined),
            title: Text(tr('Report')),
            onTap: () => Navigator.pop(context, 'report'),
          ),
          ListTile(
            leading: Icon(isBlocked ? Icons.lock_open_rounded : Icons.block_rounded,
                color: AppColors.error),
            title: Text(isBlocked ? '${tr('Unblock')} $name' : '${tr('Block')} $name'),
            onTap: () => Navigator.pop(context, isBlocked ? 'unblock' : 'block'),
          ),
        ],
      ),
    ),
  );
  if (!context.mounted) return;
  switch (choice) {
    case 'report':
      await showReportSheet(context,
          targetType: reportType, targetId: reportId ?? userId, targetOwnerId: userId, preview: preview);
    case 'block':
      await confirmBlock(context, userId: userId, name: name);
    case 'unblock':
      await BlockService.instance.unblock(userId);
  }
}
