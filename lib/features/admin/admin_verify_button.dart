import 'package:flutter/material.dart';

import '../../core/i18n/tr.dart';
import 'admin_service.dart';

/// Shown on a page only to admins: give or remove the verified badge.
class AdminVerifyButton extends StatelessWidget {
  const AdminVerifyButton(
      {super.key, required this.businessId, required this.verified});

  final String businessId;
  final bool verified;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<StaffRole>(
      future: AdminService.instance.role(),
      builder: (context, snap) {
        if (snap.data != StaffRole.admin) return const SizedBox.shrink();
        return TextButton.icon(
          icon: Icon(
              verified
                  ? Icons.remove_moderator_outlined
                  : Icons.verified_rounded,
              size: 18),
          label: Text(
              verified ? tr('Remove verified badge') : tr('Verify this page')),
          onPressed: () async {
            final messenger = ScaffoldMessenger.of(context);
            try {
              await AdminService.instance.setVerified(businessId, !verified);
              messenger.showSnackBar(SnackBar(
                  content: Text(verified
                      ? tr('Badge removed.')
                      : tr('Page verified ✓'))));
            } catch (e) {
              messenger.showSnackBar(SnackBar(content: Text('$e')));
            }
          },
        );
      },
    );
  }
}
