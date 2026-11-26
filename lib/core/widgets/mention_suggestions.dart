import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../theme/colors.dart';

/// Put this right under a text field. While the person types "@na…" it
/// shows matching people (by username); a tap puts "@nadia " in the text.
/// Shows nothing the rest of the time.
class MentionSuggestions extends StatefulWidget {
  const MentionSuggestions({super.key, required this.controller});
  final TextEditingController controller;

  @override
  State<MentionSuggestions> createState() => _MentionSuggestionsState();
}

class _MentionSuggestionsState extends State<MentionSuggestions> {
  static final _token = RegExp(r'(^|[\s(])@([a-z0-9._]{1,20})$');
  Timer? _debounce;
  String? _prefix; // what's typed after "@"
  List<Map<String, dynamic>> _people = [];

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant MentionSuggestions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  /// The "@word" just before the cursor, or null.
  String? _currentToken() {
    final v = widget.controller.value;
    final end = v.selection.baseOffset;
    if (end < 0 || end > v.text.length) return null;
    final before = v.text.substring(0, end).toLowerCase();
    return _token.firstMatch(before)?.group(2);
  }

  void _changed() {
    final p = _currentToken();
    if (p == _prefix) return;
    _prefix = p;
    _debounce?.cancel();
    if (p == null) {
      if (_people.isNotEmpty) setState(() => _people = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 250), () => _search(p));
  }

  Future<void> _search(String p) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .where('usernameLower', isGreaterThanOrEqualTo: p)
          .where('usernameLower', isLessThan: '$p')
          .limit(6)
          .get();
      if (!mounted || _prefix != p) return;
      setState(() => _people = snap.docs.map((d) => d.data()).toList());
    } catch (_) {
      if (mounted) setState(() => _people = []);
    }
  }

  void _pick(String username) {
    final v = widget.controller.value;
    final end = v.selection.baseOffset;
    final before = v.text.substring(0, end);
    final at = before.lastIndexOf('@');
    if (at < 0) return;
    final insert = '@$username ';
    final text = v.text.replaceRange(at, end, insert);
    widget.controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: at + insert.length),
    );
    setState(() {
      _people = [];
      _prefix = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_people.isEmpty) return const SizedBox.shrink();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.only(top: 6),
      constraints: const BoxConstraints(maxHeight: 230),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1A202C) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: isDark ? Colors.white12 : Colors.black12),
        boxShadow: const [BoxShadow(color: Color(0x1A000000), blurRadius: 10, offset: Offset(0, 4))],
      ),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 4),
        children: [
          for (final u in _people)
            ListTile(
              dense: true,
              leading: CircleAvatar(
                radius: 16,
                backgroundColor: AppColors.primary.withValues(alpha: 0.15),
                backgroundImage: (u['imageUrl'] ?? '').toString().isNotEmpty
                    ? CachedNetworkImageProvider(u['imageUrl'].toString())
                    : null,
                child: (u['imageUrl'] ?? '').toString().isEmpty
                    ? Text(((u['name'] ?? '').toString().trim().isEmpty
                            ? '?'
                            : (u['name']).toString().trim().characters.first)
                        .toUpperCase())
                    : null,
              ),
              title: Text((u['name'] ?? '').toString(),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('@${u['username']}'),
              onTap: () => _pick(u['username'].toString()),
            ),
        ],
      ),
    );
  }
}
