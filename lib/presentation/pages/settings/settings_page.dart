import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/theme_mode_service.dart';
import '../../../core/theme/colors.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _isDeletingAccount = false;

  Future<void> _signOut() async {
    await FirebaseAuth.instance.signOut();
    if (!mounted) return;
    context.go(AppRoutes.login);
  }

  Future<String?> _askForAccountDeletionPassword() async {
    final passwordController = TextEditingController();
    final password = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded, color: Colors.redAccent),
        title: const Text('Delete your account?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This permanently deletes your account, profile, posts, pages, and outgoing follows. Enter your password to confirm.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: passwordController,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Account password',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.lock_outline_rounded),
              ),
              onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () =>
                Navigator.of(dialogContext).pop(passwordController.text),
            child: const Text('Delete account'),
          ),
        ],
      ),
    );
    passwordController.dispose();
    return password;
  }

  Future<void> _deleteOwnedDocuments({
    required String collection,
    required String field,
    required String userId,
  }) async {
    final firestore = FirebaseFirestore.instance;
    while (true) {
      final snapshot = await firestore
          .collection(collection)
          .where(field, isEqualTo: userId)
          .limit(400)
          .get();
      if (snapshot.docs.isEmpty) return;
      final batch = firestore.batch();
      for (final document in snapshot.docs) {
        batch.delete(document.reference);
      }
      await batch.commit();
    }
  }

  Future<void> _deleteAccount() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final password = await _askForAccountDeletionPassword();
    if (password == null || !mounted) return;
    if (password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter your password to continue.')),
      );
      return;
    }

    final hasPasswordLogin =
        user.providerData.any((provider) => provider.providerId == 'password');
    if (!hasPasswordLogin || user.email == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This account has no password sign-in. Add an email and password before deleting it.',
          ),
        ),
      );
      return;
    }

    setState(() => _isDeletingAccount = true);
    try {
      await user.reauthenticateWithCredential(
        EmailAuthProvider.credential(email: user.email!, password: password),
      );
      await user.getIdToken(true);

      await _deleteOwnedDocuments(
        collection: 'posts',
        field: 'ownerId',
        userId: user.uid,
      );
      await _deleteOwnedDocuments(
        collection: 'businesses',
        field: 'ownerId',
        userId: user.uid,
      );
      await _deleteOwnedDocuments(
        collection: 'user_follows',
        field: 'followerId',
        userId: user.uid,
      );
      await _deleteOwnedDocuments(
        collection: 'page_follows',
        field: 'followerId',
        userId: user.uid,
      );
      await _deleteOwnedDocuments(
        collection: 'notifications',
        field: 'toUserId',
        userId: user.uid,
      );
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .delete();
      await user.delete();
      if (!mounted) return;
      context.go(AppRoutes.login);
    } on FirebaseAuthException catch (error) {
      if (!mounted) return;
      final message = switch (error.code) {
        'wrong-password' || 'invalid-credential' =>
          'That password did not match this account.',
        'requires-recent-login' =>
          'Sign out, sign in again, then retry account deletion.',
        _ => error.message ?? 'Account deletion failed. Please try again.',
      };
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Account deletion failed: $error')),
      );
    } finally {
      if (mounted) setState(() => _isDeletingAccount = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF151A24) : Colors.white,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: isDark ? Colors.white10 : Colors.black12,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Your space, your vibe',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Tune the app to match how you like to discover, post, and connect.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppColors.grey,
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          ValueListenableBuilder<AppThemeMode>(
            valueListenable: ThemeModeService.instance.mode,
            builder: (context, mode, _) {
              return _SettingsTile(
                icon: mode == AppThemeMode.dark
                    ? Icons.dark_mode
                    : mode == AppThemeMode.cyber
                        ? Icons.bolt
                        : Icons.light_mode,
                title: 'Theme Mode',
                subtitle: mode == AppThemeMode.dark
                    ? 'Dark'
                    : mode == AppThemeMode.cyber
                        ? 'Cyber'
                        : 'Light',
                onTap: () async {
                  await ThemeModeService.instance.toggle();
                  if (mounted) {
                    setState(() {});
                  }
                },
              );
            },
          ),
          _SettingsTile(
            icon: Icons.person_outline,
            title: 'Edit Profile',
            subtitle: 'Update your photo, bio, and contact details',
            onTap: () => context.push(AppRoutes.profile),
          ),
          _GhostModeSetting(),
          const SizedBox(height: 18),
          _SettingsTile(
            icon: Icons.delete_forever_outlined,
            title: 'Delete Account',
            subtitle: _isDeletingAccount
                ? 'Deleting your account…'
                : 'Permanently delete your profile and content',
            onTap: _isDeletingAccount ? () {} : _deleteAccount,
          ),
          const SizedBox(height: 6),
          FilledButton.icon(
            onPressed: _signOut,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB3261E),
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
            ),
            icon: const Icon(Icons.logout),
            label: const Text('Log Out'),
          ),
        ],
      ),
    );
  }
}

class _GhostModeSetting extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return const SizedBox.shrink();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .snapshots(),
      builder: (context, snapshot) {
        final ghostMode = snapshot.data?.data()?['ghostModeDefault'] != false;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 8),
              child: Text(
                'Privacy & Safety',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
            Container(
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF151A24) : Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isDark ? Colors.white10 : Colors.black12,
                ),
              ),
              child: SwitchListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                secondary: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withOpacity(0.14),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.visibility_off_outlined,
                      color: AppColors.primary),
                ),
                title: const Text('Ghost mode by default',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: const Text(
                    'Choose whether new messages start in ghost mode.',
                    style: TextStyle(color: AppColors.grey, fontSize: 13)),
                value: ghostMode,
                onChanged: snapshot.connectionState == ConnectionState.waiting
                    ? null
                    : (value) async {
                        await FirebaseFirestore.instance
                            .collection('users')
                            .doc(user.uid)
                            .set({
                          'ghostModeDefault': value,
                          'updatedAt': FieldValue.serverTimestamp(),
                        }, SetOptions(merge: true));
                      },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF151A24) : Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isDark ? Colors.white10 : Colors.black12,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.primary.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: AppColors.primary),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: AppColors.grey,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}
