import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../../core/i18n/tr.dart';
import '../../../core/theme/colors.dart';
import '../../../core/widgets/verified_badge.dart';

class PickedPerson {
  const PickedPerson({required this.uid, required this.name, this.imageUrl,
      this.verified = false});
  final String uid;
  final String name;
  final String? imageUrl;
  final bool verified;
}

/// Full-screen "choose people" list: people you follow and who follow you
/// first, and a search box for everyone else. Used for new groups, adding
/// members and sending a post.
Future<List<PickedPerson>?> pickPeople(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  Set<String> exclude = const {},
  int max = 255,
}) {
  return Navigator.of(context).push<List<PickedPerson>>(MaterialPageRoute(
    builder: (_) => _PeoplePickerPage(
        title: title, confirmLabel: confirmLabel, exclude: exclude, max: max),
  ));
}

class _PeoplePickerPage extends StatefulWidget {
  const _PeoplePickerPage({
    required this.title,
    required this.confirmLabel,
    required this.exclude,
    required this.max,
  });
  final String title;
  final String confirmLabel;
  final Set<String> exclude;
  final int max;

  @override
  State<_PeoplePickerPage> createState() => _PeoplePickerPageState();
}

class _PeoplePickerPageState extends State<_PeoplePickerPage> {
  final _search = TextEditingController();
  final Map<String, PickedPerson> _picked = {};
  List<PickedPerson> _known = [];
  List<PickedPerson> _found = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadKnown();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  static Future<List<PickedPerson>> loadPeople(Iterable<String> ids) async {
    final out = <PickedPerson>[];
    final list = ids.toList();
    for (var i = 0; i < list.length; i += 30) {
      final chunk = list.sublist(i, i + 30 > list.length ? list.length : i + 30);
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .where(FieldPath.documentId, whereIn: chunk)
          .get();
      for (final d in snap.docs) {
        if (d.data()['suspended'] == true) continue;
        out.add(PickedPerson(
          uid: d.id,
          name: (d.data()['name'] ?? 'User').toString(),
          imageUrl: d.data()['imageUrl'] as String?,
          verified: d.data()['verified'] == true,
        ));
      }
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  Future<void> _loadKnown() async {
    final me = FirebaseAuth.instance.currentUser?.uid;
    if (me == null) return;
    final follows = FirebaseFirestore.instance.collection('user_follows');
    final results = await Future.wait([
      follows.where('followerId', isEqualTo: me).limit(300).get(),
      follows.where('followingId', isEqualTo: me).limit(300).get(),
    ]);
    final ids = <String>{
      ...results[0].docs.map((d) => (d.data()['followingId'] ?? '').toString()),
      ...results[1].docs.map((d) => (d.data()['followerId'] ?? '').toString()),
    }..removeWhere((id) => id.isEmpty || id == me || widget.exclude.contains(id));
    final people = await loadPeople(ids);
    if (mounted) {
      setState(() {
        _known = people;
        _loading = false;
      });
    }
  }

  Future<void> _runSearch(String q) async {
    final t = q.trim().toLowerCase();
    if (t.length < 2) {
      setState(() => _found = []);
      return;
    }
    final me = FirebaseAuth.instance.currentUser?.uid;
    final snap = await FirebaseFirestore.instance
        .collection('users')
        .where('searchKeywords', arrayContains: t)
        .limit(20)
        .get();
    if (!mounted || _search.text.trim().toLowerCase() != t) return;
    setState(() {
      _found = snap.docs
          .where((d) =>
              d.id != me &&
              !widget.exclude.contains(d.id) &&
              d.data()['suspended'] != true)
          .map((d) => PickedPerson(
                uid: d.id,
                name: (d.data()['name'] ?? 'User').toString(),
                imageUrl: d.data()['imageUrl'] as String?,
                verified: d.data()['verified'] == true,
              ))
          .toList();
    });
  }

  void _toggle(PickedPerson p) {
    setState(() {
      if (_picked.containsKey(p.uid)) {
        _picked.remove(p.uid);
      } else if (_picked.length < widget.max) {
        _picked[p.uid] = p;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final q = _search.text.trim().toLowerCase();
    final knownShown = q.isEmpty
        ? _known
        : _known.where((p) => p.name.toLowerCase().contains(q)).toList();
    final knownIds = knownShown.map((p) => p.uid).toSet();
    final others = _found.where((p) => !knownIds.contains(p.uid)).toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: FilledButton(
              onPressed: _picked.isEmpty
                  ? null
                  : () => Navigator.pop(context, _picked.values.toList()),
              child: Text(_picked.isEmpty
                  ? widget.confirmLabel
                  : '${widget.confirmLabel} (${_picked.length})'),
            ),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                child: TextField(
                  controller: _search,
                  autofocus: false,
                  onChanged: (v) {
                    setState(() {});
                    _runSearch(v);
                  },
                  decoration: InputDecoration(
                    hintText: tr('Search people'),
                    prefixIcon: const Icon(Icons.search_rounded),
                    filled: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              if (_picked.isNotEmpty)
                SizedBox(
                  height: 84,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      for (final p in _picked.values)
                        Padding(
                          padding: const EdgeInsets.all(6),
                          child: GestureDetector(
                            onTap: () => _toggle(p),
                            child: Column(children: [
                              Stack(children: [
                                _Avatar(person: p, radius: 24),
                                const Positioned(
                                  right: 0,
                                  bottom: 0,
                                  child: CircleAvatar(
                                    radius: 9,
                                    backgroundColor: Colors.black54,
                                    child: Icon(Icons.close,
                                        size: 12, color: Colors.white),
                                  ),
                                ),
                              ]),
                              const SizedBox(height: 4),
                              SizedBox(
                                width: 60,
                                child: Text(p.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(fontSize: 11)),
                              ),
                            ]),
                          ),
                        ),
                    ],
                  ),
                ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : ListView(
                        children: [
                          if (knownShown.isNotEmpty)
                            _header(tr('People you know')),
                          for (final p in knownShown) _row(p),
                          if (others.isNotEmpty) _header(tr('More people')),
                          for (final p in others) _row(p),
                          if (knownShown.isEmpty && others.isEmpty)
                            Padding(
                              padding: const EdgeInsets.all(32),
                              child: Text(
                                q.length < 2
                                    ? tr('Follow people or search by name to add them.')
                                    : tr('No one found.'),
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: AppColors.grey),
                              ),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(t,
            style: const TextStyle(
                fontWeight: FontWeight.w800, color: AppColors.grey)),
      );

  Widget _row(PickedPerson p) {
    final on = _picked.containsKey(p.uid);
    return ListTile(
      leading: _Avatar(person: p),
      title: Row(children: [
        Flexible(child: Text(p.name, overflow: TextOverflow.ellipsis)),
        if (p.verified) ...[
          const SizedBox(width: 4),
          const VerifiedBadge(size: 14),
        ],
      ]),
      trailing: AnimatedSwitcher(
        duration: const Duration(milliseconds: 150),
        child: Icon(
          on ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
          key: ValueKey(on),
          color: on ? AppColors.primary : AppColors.grey,
        ),
      ),
      onTap: () => _toggle(p),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.person, this.radius = 20});
  final PickedPerson person;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final url = person.imageUrl;
    return CircleAvatar(
      radius: radius,
      backgroundColor: AppColors.primary,
      backgroundImage: url == null || url.isEmpty
          ? null
          : CachedNetworkImageProvider(url),
      child: url == null || url.isEmpty
          ? Text(person.name.isEmpty ? '?' : person.name[0].toUpperCase(),
              style: const TextStyle(color: Colors.white))
          : null,
    );
  }
}

/// Public helper (group info uses it to show members).
Future<List<PickedPerson>> loadPeopleByIds(Iterable<String> ids) =>
    _PeoplePickerPageState.loadPeople(ids);
