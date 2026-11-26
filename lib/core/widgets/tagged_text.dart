import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../presentation/pages/search/hashtag_page.dart';
import '../constants/app_constants.dart';
import '../theme/colors.dart';

/// Text where #hashtags, @usernames and links are tappable.
///   #kigali    -> all posts with that tag (HashtagPage)
///   @nelson    -> that person's profile
///   https://.. -> opens the browser
/// Same rules as the server (functions/tags.js).
class TaggedText extends StatefulWidget {
  const TaggedText(
    this.text, {
    super.key,
    this.style,
    this.maxLines,
    this.overflow,
    this.linkColor,
  });

  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final Color? linkColor;

  static final pattern = RegExp(
    r'(#[\p{L}\p{N}_]{2,40})|(@[A-Za-z0-9._]{3,20})|(https?://[^\s]+)',
    unicode: true,
  );

  /// True when the text has anything tappable (saves work for plain text).
  static bool hasTags(String text) => pattern.hasMatch(text);

  @override
  State<TaggedText> createState() => _TaggedTextState();
}

class _TaggedTextState extends State<TaggedText> {
  final _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  void _clear() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  TapGestureRecognizer _tap(VoidCallback onTap) {
    final r = TapGestureRecognizer()..onTap = onTap;
    _recognizers.add(r);
    return r;
  }

  Future<void> _openUser(String username) async {
    final router = GoRouter.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final snap = await FirebaseFirestore.instance
        .collection('usernames')
        .doc(username.toLowerCase().replaceAll(RegExp(r'\.+$'), ''))
        .get();
    final uid = snap.data()?['uid']?.toString();
    if (uid == null || uid.isEmpty) {
      messenger.showSnackBar(SnackBar(content: Text('@$username ?')));
      return;
    }
    router.push(AppRoutes.clientProfilePath(uid));
  }

  @override
  Widget build(BuildContext context) {
    _clear();
    final base = widget.style ?? DefaultTextStyle.of(context).style;
    final link = base.copyWith(
      color: widget.linkColor ?? AppColors.primary,
      fontWeight: FontWeight.w600,
    );
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in TaggedText.pattern.allMatches(widget.text)) {
      // "#" right after a letter is not a tag (e.g. "C#", "a&#39;").
      if (m.start > 0 && m.group(1) != null) {
        final before = widget.text[m.start - 1];
        if (RegExp(r'[\p{L}\p{N}_&]', unicode: true).hasMatch(before)) continue;
      }
      if (m.start > 0 && m.group(2) != null) {
        final before = widget.text[m.start - 1];
        if (RegExp(r'[\p{L}\p{N}_.@]', unicode: true).hasMatch(before)) continue; // emails
      }
      if (m.start > last) spans.add(TextSpan(text: widget.text.substring(last, m.start)));
      final word = m.group(0)!;
      if (m.group(1) != null) {
        final tag = word.substring(1).toLowerCase();
        spans.add(TextSpan(
          text: word,
          style: link,
          recognizer: _tap(() => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => HashtagPage(tag: tag),
              ))),
        ));
      } else if (m.group(2) != null) {
        spans.add(TextSpan(
          text: word,
          style: link,
          recognizer: _tap(() => _openUser(word.substring(1))),
        ));
      } else {
        final url = word.replaceAll(RegExp(r'[).,!?]+$'), '');
        spans.add(TextSpan(
          text: url,
          style: link.copyWith(decoration: TextDecoration.underline),
          recognizer: _tap(() {
            final uri = Uri.tryParse(url);
            if (uri != null) launchUrl(uri, mode: LaunchMode.externalApplication);
          }),
        ));
        if (url.length < word.length) spans.add(TextSpan(text: word.substring(url.length)));
      }
      last = m.end;
    }
    if (last < widget.text.length) spans.add(TextSpan(text: widget.text.substring(last)));

    return Text.rich(
      TextSpan(style: base, children: spans),
      maxLines: widget.maxLines,
      overflow: widget.overflow,
    );
  }
}
