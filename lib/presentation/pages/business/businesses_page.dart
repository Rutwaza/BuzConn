import 'dart:io';

import 'package:businessfinder/core/i18n/tr.dart';
import 'package:businessfinder/core/services/media_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/r2_storage_service.dart';
import '../../../core/theme/colors.dart';
import '../../../core/widgets/verified_badge.dart';
import '../../../features/billing/billing_service.dart';
import '../../../features/billing/upgrade_sheets.dart';
import '../../../features/verification/verification_sheet.dart';
import 'page_team_page.dart';

/// "My pages": the pages you own (first one free, more are paid once),
/// the pages you help run (page team), and hidden pages.
class BusinessesPage extends StatefulWidget {
  const BusinessesPage({super.key});

  @override
  State<BusinessesPage> createState() => _BusinessesPageState();
}

class _BusinessesPageState extends State<BusinessesPage> {
  final _db = FirebaseFirestore.instance;
  Future<BillingInfo>? _info;
  bool _showHidden = false;

  @override
  void initState() {
    super.initState();
    _refreshInfo();
  }

  void _refreshInfo() {
    setState(() => _info = BillingService.instance.info());
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _newPage() async {
    BillingInfo? info;
    try {
      info = await (_info ?? BillingService.instance.info());
    } catch (_) {}
    if (!mounted) return;
    if (info != null && !info.pages.canCreate) {
      final bought = await showPageSlotsSheet(context);
      _refreshInfo();
      if (!bought || !mounted) return;
    }
    await context.push(AppRoutes.businessSetup);
    if (mounted) _refreshInfo();
  }

  Future<void> _changeLogo(String businessId) async {
    try {
      final picked = await MediaPicker.pickImage(source: ImageSource.gallery);
      if (picked == null) return;
      _snack(tr('Uploading logo...'));
      final bytes = await File(picked.path).readAsBytes();
      final url = await R2StorageService.instance.uploadImage(
        bucket: 'profile-images',
        path: '$businessId/logo_${DateTime.now().millisecondsSinceEpoch}.jpg',
        bytes: bytes,
      );
      if (url == null) return;
      await _db.collection('businesses').doc(businessId).update({
        'imageUrl': url,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      // Show the new logo on the page's posts too.
      final posts = await _db
          .collection('posts')
          .where('businessId', isEqualTo: businessId)
          .limit(400)
          .get();
      final batch = _db.batch();
      for (final d in posts.docs) {
        batch.update(d.reference, {'businessImageUrl': url});
      }
      await batch.commit();
      _snack(tr('Logo updated'));
    } catch (e) {
      _snack('${tr('Logo upload failed')}: $e');
    }
  }

  Future<void> _hide(String businessId, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('${tr('Hide')} $name?'),
        content: Text(tr(
            'People will not see this page or its posts. Its place becomes free for another page. You can show it again later if you have a free place.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('Hide page'))),
        ],
      ),
    );
    if (ok != true) return;
    await _db.collection('businesses').doc(businessId).update({
      'isActive': false,
      'updatedAt': FieldValue.serverTimestamp(),
    });
    _refreshInfo();
  }

  Future<void> _restore(String businessId) async {
    try {
      final r = await BillingService.instance.restorePage(businessId);
      if (!mounted) return;
      if (r['needSlot'] == true) {
        final bought = await showPageSlotsSheet(context);
        if (bought) await _restore(businessId);
        return;
      }
      _snack(tr('Page is visible again'));
      _refreshInfo();
    } catch (e) {
      _snack(e.toString().replaceFirst('HttpException: ', ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return Scaffold(body: Center(child: Text(tr('Please sign in to manage pages.'))));
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('My pages')),
        actions: [
          IconButton(
            tooltip: _showHidden ? tr('Hide hidden pages') : tr('Show hidden pages'),
            icon: Icon(_showHidden
                ? Icons.visibility_off_rounded
                : Icons.visibility_rounded),
            onPressed: () => setState(() => _showHidden = !_showHidden),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newPage,
        icon: const Icon(Icons.add_business_rounded),
        label: Text(tr('New page')),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _db
            .collection('businesses')
            .where('ownerId', isEqualTo: user.uid)
            .snapshots(),
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('${snap.error}'));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final all = snap.data!.docs;
          final active = all.where((d) => d.data()['isActive'] != false).toList();
          final hidden = all.where((d) => d.data()['isActive'] == false).toList();
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
                children: [
                  _SlotsCard(info: _info, onGetMore: () async {
                    await showPageSlotsSheet(context);
                    _refreshInfo();
                  }),
                  const SizedBox(height: 16),
                  if (active.isEmpty)
                    _Empty(onCreate: _newPage)
                  else
                    for (final d in active)
                      _PageCard(
                        id: d.id,
                        data: d.data(),
                        role: 'owner',
                        onMenu: (action) => _onAction(action, d.id, d.data()),
                      ),
                  _TeamPages(uid: user.uid, onMenu: _onAction),
                  if (_showHidden) ...[
                    const SizedBox(height: 18),
                    _Header(tr('Hidden pages'), Icons.visibility_off_rounded),
                    if (hidden.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(tr('No hidden pages.'),
                            style: const TextStyle(color: AppColors.grey)),
                      ),
                    for (final d in hidden)
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.storefront_outlined),
                          title: Text((d.data()['name'] ?? tr('Page')).toString()),
                          subtitle: Text(d.data()['suspended'] == true
                              ? tr('Suspended by the Duhuze team')
                              : tr('Hidden')),
                          trailing: d.data()['suspended'] == true
                              ? null
                              : TextButton(
                                  onPressed: () => _restore(d.id),
                                  child: Text(tr('Show again')),
                                ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _onAction(String action, String id, Map<String, dynamic> data) {
    switch (action) {
      case 'open':
        context.push(AppRoutes.businessProfilePath(id));
      case 'edit':
        context.push('${AppRoutes.businessSetup}?businessId=$id');
      case 'logo':
        _changeLogo(id);
      case 'team':
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => PageTeamPage(pageId: id),
        ));
      case 'verify':
        showVerificationSheet(context, kind: 'page', targetId: id);
      case 'hide':
        _hide(id, (data['name'] ?? '').toString());
    }
  }
}

/// "Pages: 1 of 1 · Get another page".
class _SlotsCard extends StatelessWidget {
  const _SlotsCard({required this.info, required this.onGetMore});
  final Future<BillingInfo>? info;
  final VoidCallback onGetMore;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return FutureBuilder<BillingInfo>(
      future: info,
      builder: (context, snap) {
        final s = snap.data?.pages;
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: LinearGradient(
              colors: [
                AppColors.primary.withValues(alpha: isDark ? 0.35 : 0.16),
                AppColors.secondary.withValues(alpha: isDark ? 0.22 : 0.10),
              ],
            ),
          ),
          child: Row(children: [
            const CircleAvatar(
              radius: 22,
              backgroundColor: AppColors.primary,
              child: Icon(Icons.storefront_rounded, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  s == null ? tr('Your pages') : '${s.used} ${tr('of')} ${s.total} ${tr('pages used')}',
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                ),
                const SizedBox(height: 2),
                Text(
                  s == null
                      ? tr('First page free · extra pages paid once')
                      : s.bought > 0
                          ? '${tr('1 free')} + ${s.bought} ${tr('bought')}'
                          : tr('First page free · extra pages paid once'),
                  style: const TextStyle(fontSize: 12.5, color: AppColors.grey),
                ),
              ]),
            ),
            TextButton.icon(
              onPressed: onGetMore,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: Text(tr('Get more')),
            ),
          ]),
        );
      },
    );
  }
}

/// Pages where you're on the team (admin or editor).
class _TeamPages extends StatelessWidget {
  const _TeamPages({required this.uid, required this.onMenu});
  final String uid;
  final void Function(String action, String id, Map<String, dynamic> data) onMenu;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('businesses')
          .where('teamIds', arrayContains: uid)
          .snapshots(),
      builder: (context, snap) {
        final docs = (snap.data?.docs ?? [])
            .where((d) => d.data()['isActive'] != false)
            .toList();
        if (docs.isEmpty) return const SizedBox.shrink();
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SizedBox(height: 18),
          _Header(tr('Pages you help run'), Icons.groups_rounded),
          for (final d in docs)
            _PageCard(
              id: d.id,
              data: d.data(),
              role: ((d.data()['team'] as Map?)?[uid] ?? 'editor').toString(),
              onMenu: (a) => onMenu(a, d.id, d.data()),
            ),
        ]);
      },
    );
  }
}

class _PageCard extends StatelessWidget {
  const _PageCard({
    required this.id,
    required this.data,
    required this.role,
    required this.onMenu,
  });

  final String id;
  final Map<String, dynamic> data;
  final String role; // owner | admin | editor
  final void Function(String action) onMenu;

  @override
  Widget build(BuildContext context) {
    final name = (data['name'] ?? tr('Page')).toString();
    final logo = (data['imageUrl'] ?? '').toString();
    final verified = data['verified'] == true;
    final teamCount = (data['teamIds'] as List?)?.length ?? 0;
    final isOwner = role == 'owner';
    final canEdit = isOwner || role == 'admin';
    final roleLabel = {
      'owner': tr('Owner'),
      'admin': tr('Admin'),
      'editor': tr('Editor'),
    }[role]!;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        onTap: () => onMenu('open'),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            CircleAvatar(
              radius: 26,
              backgroundColor: AppColors.primary.withValues(alpha: 0.15),
              backgroundImage: logo.isNotEmpty ? CachedNetworkImageProvider(logo) : null,
              child: logo.isEmpty
                  ? Text(name.isEmpty ? '?' : name[0].toUpperCase(),
                      style: const TextStyle(
                          color: AppColors.primary, fontWeight: FontWeight.w800))
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(
                    child: Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
                  ),
                  if (verified) ...[
                    const SizedBox(width: 4),
                    const VerifiedBadge(size: 15),
                  ],
                ]),
                const SizedBox(height: 4),
                Wrap(spacing: 6, runSpacing: 4, children: [
                  _Chip(roleLabel, isOwner ? AppColors.primary : AppColors.secondary),
                  if ((data['category'] ?? '').toString().isNotEmpty)
                    _Chip(data['category'].toString(), AppColors.grey),
                  if (teamCount > 0)
                    _Chip('${teamCount + 1} ${tr('in team')}', AppColors.grey),
                ]),
              ]),
            ),
            PopupMenuButton<String>(
              onSelected: onMenu,
              itemBuilder: (_) => [
                _item('open', Icons.open_in_new_rounded, tr('Open page')),
                if (canEdit) _item('edit', Icons.edit_rounded, tr('Edit page')),
                if (canEdit) _item('logo', Icons.image_rounded, tr('Change logo')),
                _item('team', Icons.groups_rounded, isOwner ? tr('Page team') : tr('Team')),
                if (isOwner && !verified)
                  _item('verify', Icons.verified_rounded, tr('Get verified')),
                if (isOwner) _item('hide', Icons.visibility_off_rounded, tr('Hide page')),
              ],
            ),
          ]),
        ),
      ),
    );
  }

  PopupMenuItem<String> _item(String v, IconData icon, String text) => PopupMenuItem(
        value: v,
        child: Row(children: [
          Icon(icon, size: 18),
          const SizedBox(width: 10),
          Text(text),
        ]),
      );
}

class _Chip extends StatelessWidget {
  const _Chip(this.text, this.color);
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(text,
          style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: color)),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text, this.icon);
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Row(children: [
        Icon(icon, size: 18, color: AppColors.grey),
        const SizedBox(width: 6),
        Text(text, style: const TextStyle(fontWeight: FontWeight.w800)),
      ]),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onCreate});
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(children: [
        const Icon(Icons.storefront_rounded, size: 64, color: AppColors.grey),
        const SizedBox(height: 12),
        Text(tr('You have no pages yet'),
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text(tr('A page is for your business, brand or project. Your first page is free.'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.grey)),
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: onCreate,
          icon: const Icon(Icons.add_business_rounded),
          label: Text(tr('Create your page')),
        ),
      ]),
    );
  }
}
