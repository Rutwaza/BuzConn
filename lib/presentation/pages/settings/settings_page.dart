import 'package:firebase_auth/firebase_auth.dart';
import 'package:businessfinder/features/admin/admin_service.dart';
import 'package:businessfinder/features/admin/admin_panel_page.dart';
import 'package:businessfinder/core/widgets/legal_links.dart';
import 'package:businessfinder/core/services/r2_storage_service.dart';
import 'package:businessfinder/core/services/lite_mode_service.dart';
import 'package:businessfinder/core/i18n/tr.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:businessfinder/features/verification/verification_sheet.dart';
import 'package:businessfinder/features/chat/data/presence_service.dart';
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
    await PresenceService.instance.goOffline();
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
        title: Text(tr('Delete your account?')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr('This permanently deletes your account, profile, posts, pages, statuses, comments and follows. Enter your password to confirm.'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: passwordController,
              obscureText: true,
              autofocus: true,
              decoration: InputDecoration(
                labelText: tr('Account password'),
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.lock_outline_rounded),
              ),
              onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(tr('Cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () =>
                Navigator.of(dialogContext).pop(passwordController.text),
            child: Text(tr('Delete account')),
          ),
        ],
      ),
    );
    passwordController.dispose();
    return password;
  }

  Future<bool> _confirmDeleteByTyping() async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('Delete your account?')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('This permanently deletes your account, profile, posts, pages, statuses, comments and follows. Type DELETE to confirm.')),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'DELETE',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(tr('Cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(dialogContext)
                .pop(controller.text.trim().toUpperCase() == 'DELETE'),
            child: Text(tr('Delete account')),
          ),
        ],
      ),
    );
    controller.dispose();
    return ok == true;
  }

  /// Google Play requires that every user can delete their account in the
  /// app. The server (functions/account.js -> deleteAccount) removes the data;
  /// it only accepts a sign-in from the last 15 minutes.
  Future<void> _deleteAccount() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final hasPasswordLogin = user.email != null &&
        user.providerData.any((provider) => provider.providerId == 'password');

    if (hasPasswordLogin) {
      final password = await _askForAccountDeletionPassword();
      if (password == null || !mounted) return;
      if (password.isEmpty) {
        messenger.showSnackBar(
          SnackBar(content: Text(tr('Enter your password to continue.'))),
        );
        return;
      }
      setState(() => _isDeletingAccount = true);
      try {
        await user.reauthenticateWithCredential(
          EmailAuthProvider.credential(email: user.email!, password: password),
        );
      } on FirebaseAuthException catch (error) {
        if (mounted) setState(() => _isDeletingAccount = false);
        messenger.showSnackBar(SnackBar(
          content: Text(error.code == 'wrong-password' || error.code == 'invalid-credential'
              ? tr('That password did not match this account.')
              : (error.message ?? tr('Account deletion failed. Please try again.'))),
        ));
        return;
      }
    } else {
      final lastSignIn = user.metadata.lastSignInTime;
      if (lastSignIn == null ||
          DateTime.now().difference(lastSignIn) > const Duration(minutes: 14)) {
        messenger.showSnackBar(SnackBar(
          content: Text(tr('For your safety, sign out and sign in again, then delete your account within 15 minutes.')),
          duration: const Duration(seconds: 6),
        ));
        return;
      }
      if (!await _confirmDeleteByTyping() || !mounted) return;
      setState(() => _isDeletingAccount = true);
    }

    try {
      await user.getIdToken(true);
      await R2StorageService.instance.callFunction('deleteAccount', {});
      await FirebaseAuth.instance.signOut();
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(tr('Your account was deleted.'))));
      context.go(AppRoutes.login);
    } catch (error) {
      if (!mounted) return;
      final text = error.toString().contains('recent-login-required')
          ? tr('For your safety, sign out and sign in again, then delete your account within 15 minutes.')
          : '${tr('Account deletion failed. Please try again.')} ($error)';
      messenger.showSnackBar(SnackBar(content: Text(text)));
    } finally {
      if (mounted) setState(() => _isDeletingAccount = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Settings')),
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
                  tr('Your space, your vibe'),
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 6),
                Text(
                  tr('Tune the app to match how you like to discover, post, and connect.'),
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
                    : Icons.light_mode,
                title: tr('Theme Mode'),
                subtitle: mode == AppThemeMode.dark ? tr('Dark') : tr('Light'),
                onTap: () async {
                  await ThemeModeService.instance.toggle();
                  if (mounted) {
                    setState(() {});
                  }
                },
              );
            },
          ),
          ValueListenableBuilder<LiteMode>(
            valueListenable: LiteModeService.instance.mode,
            builder: (context, lite, _) => _SettingsTile(
              icon: Icons.data_saver_on_rounded,
              title: tr('Lite mode (save data)'),
              subtitle: switch (lite) {
                LiteMode.auto => tr('Auto: on when using mobile data'),
                LiteMode.on => tr('On: videos play only when you tap'),
                LiteMode.off => tr('Off'),
              },
              onTap: () => LiteModeService.instance.set(
                LiteMode.values[(lite.index + 1) % LiteMode.values.length],
              ),
            ),
          ),
          ValueListenableBuilder<AppLanguage>(
            valueListenable: LanguageService.instance.language,
            builder: (context, lang, _) => _SettingsTile(
              icon: Icons.translate_rounded,
              title: tr('Language'),
              subtitle: lang.label,
              onTap: () async {
                final picked = await showModalBottomSheet<AppLanguage>(
                  context: context,
                  showDragHandle: true,
                  builder: (context) => SafeArea(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final l in AppLanguage.values)
                          ListTile(
                            title: Text(l.label),
                            trailing: l == lang
                                ? const Icon(Icons.check_rounded)
                                : null,
                            onTap: () => Navigator.of(context).pop(l),
                          ),
                      ],
                    ),
                  ),
                );
                if (picked != null) await LanguageService.instance.set(picked);
              },
            ),
          ),
          _SettingsTile(
            icon: Icons.person_outline,
            title: tr('Edit Profile'),
            subtitle: tr('Update your photo, bio, and contact details'),
            onTap: () => context.push(AppRoutes.profile),
          ),
          _SettingsTile(
            icon: Icons.verified_rounded,
            title: tr('Get verified'),
            subtitle: tr('Ask for the blue ✓ for your account'),
            onTap: () => showVerificationSheet(context, kind: 'user'),
          ),
          // Only the Duhuze team sees this (README -> "Admin panel").
          FutureBuilder<StaffRole>(
            future: AdminService.instance.role(),
            builder: (context, snap) {
              final role = snap.data ?? StaffRole.none;
              if (role == StaffRole.none) return const SizedBox.shrink();
              return _SettingsTile(
                icon: Icons.admin_panel_settings_rounded,
                title: role == StaffRole.admin ? 'Admin panel' : 'Moderator panel',
                subtitle: 'Dashboard, reports, users, pages, verification',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AdminPanelPage()),
                ),
              );
            },
          ),
          _GhostModeSetting(),
          _SettingsTile(
            icon: Icons.privacy_tip_outlined,
            title: tr('Privacy policy'),
            subtitle: tr('What we collect and your rights'),
            onTap: () => openLegalPage('privacy'),
          ),
          _SettingsTile(
            icon: Icons.description_outlined,
            title: tr('Terms of use'),
            subtitle: tr('Community rules'),
            onTap: () => openLegalPage('terms'),
          ),
          _SettingsTile(
            icon: Icons.child_care_rounded,
            title: tr('Child safety standards'),
            subtitle: tr('How to report harm to children'),
            onTap: () => openLegalPage('child-safety'),
          ),
          const SizedBox(height: 18),
          _SettingsTile(
            icon: Icons.delete_forever_outlined,
            title: tr('Delete Account'),
            subtitle: _isDeletingAccount
                ? tr('Deleting your account…')
                : tr('Permanently delete your profile and content'),
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
            label: Text(tr('Log Out')),
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
                tr('Privacy & Safety'),
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
                title: Text(tr('Ghost mode by default'),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(
                    tr('Choose whether new messages start in ghost mode.'),
                    style: const TextStyle(color: AppColors.grey, fontSize: 13)),
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
