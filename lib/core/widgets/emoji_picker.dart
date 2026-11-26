import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../i18n/tr.dart';

/// A 😊 button for any text box. Tap it to pick emojis; they go in where
/// the cursor is. Built in (no extra package), works on phones and Windows.
///
/// Use it as a TextField's `suffixIcon` / `prefixIcon`, or anywhere:
///   EmojiButton(controller: _text)
class EmojiButton extends StatelessWidget {
  const EmojiButton({
    super.key,
    required this.controller,
    this.focusNode,
    this.color,
    this.size = 22,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tr('Emoji'),
      visualDensity: VisualDensity.compact,
      icon: Icon(Icons.emoji_emotions_outlined, color: color, size: size),
      onPressed: () => showEmojiPicker(context,
          controller: controller, focusNode: focusNode),
    );
  }
}

/// Opens the picker (a bottom sheet on phones, a small window on desktop).
Future<void> showEmojiPicker(
  BuildContext context, {
  required TextEditingController controller,
  FocusNode? focusNode,
}) async {
  void insert(String emoji) {
    final value = controller.value;
    final sel = value.selection;
    final start = sel.isValid ? sel.start : value.text.length;
    final end = sel.isValid ? sel.end : value.text.length;
    final text = value.text.replaceRange(start, end, emoji);
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: start + emoji.length),
    );
    _EmojiRecent.add(emoji);
  }

  final desktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  if (desktop) {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black12,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: SizedBox(
            width: 380, height: 420, child: _EmojiPanel(onPick: insert)),
      ),
    );
  } else {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) =>
          SizedBox(height: 340, child: _EmojiPanel(onPick: insert)),
    );
  }
  focusNode?.requestFocus();
}

class _EmojiRecent {
  static final List<String> items = [];
  static void add(String e) {
    items.remove(e);
    items.insert(0, e);
    if (items.length > 24) items.removeLast();
  }
}

class _EmojiPanel extends StatefulWidget {
  const _EmojiPanel({required this.onPick});
  final ValueChanged<String> onPick;

  @override
  State<_EmojiPanel> createState() => _EmojiPanelState();
}

class _EmojiPanelState extends State<_EmojiPanel>
    with SingleTickerProviderStateMixin {
  late final List<MapEntry<String, List<String>>> _cats = [
    if (_EmojiRecent.items.isNotEmpty)
      MapEntry('🕘', List.of(_EmojiRecent.items)),
    ..._emojiCategories.entries,
  ];
  late final TabController _tabs =
      TabController(length: _cats.length, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            for (final c in _cats)
              Tab(child: Text(c.key, style: const TextStyle(fontSize: 20))),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [
              for (final c in _cats)
                GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 44,
                  ),
                  itemCount: c.value.length,
                  itemBuilder: (context, i) => InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => widget.onPick(c.value[i]),
                    child: Center(
                      child: Text(c.value[i],
                          style: const TextStyle(fontSize: 24)),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

List<String> _split(String s) =>
    s.split(' ').where((e) => e.isNotEmpty).toList();

final Map<String, List<String>> _emojiCategories = {
  '😀': _split(
      '😀 😃 😄 😁 😆 😅 🤣 😂 🙂 🙃 😉 😊 😇 🥰 😍 🤩 😘 😗 😚 😙 😋 😛 😜 🤪 😝 🤑 🤗 🤭 🤫 🤔 🤐 🤨 😐 😑 😶 😏 😒 🙄 😬 😌 😔 😪 🤤 😴 😷 🤒 🤕 🤢 🤮 🥵 🥶 🥴 😵 🤯 🤠 🥳 😎 🤓 🧐 😕 😟 🙁 😮 😯 😲 😳 🥺 😦 😧 😨 😰 😥 😢 😭 😱 😖 😣 😞 😓 😩 😫 🥱 😤 😡 😠 🤬 😈 👿 💀 💩 🤡 👻 👽 🤖'),
  '👋': _split(
      '👋 🤚 🖐 ✋ 🖖 👌 🤌 🤏 ✌️ 🤞 🤟 🤘 🤙 👈 👉 👆 👇 ☝️ 👍 👎 ✊ 👊 🤛 🤜 👏 🙌 👐 🤲 🤝 🙏 ✍️ 💅 🤳 💪 🦾 👀 👁 👅 👄 🧠 🫶 🙋 🙆 🙅 🤷 🤦 🙇 💁 🧑‍💻 👨‍🌾 👩‍🍳 🧕 👶 👧 👦 👩 👨 👵 👴'),
  '❤️': _split(
      '❤️ 🧡 💛 💚 💙 💜 🖤 🤍 🤎 💔 ❣️ 💕 💞 💓 💗 💖 💘 💝 💟 ♥️ 💯 💢 💥 💫 💦 💨 🔥 ✨ ⭐ 🌟 ⚡ ☀️ 🌈 ☁️ ❄️ 🎉 🎊 🎈 🎁 🏆 🥇 🎯 ✅ ❌ ⚠️ ❓ ❗ 💤'),
  '🍔': _split(
      '🍏 🍎 🍐 🍊 🍋 🍌 🍉 🍇 🍓 🫐 🍈 🍒 🍑 🥭 🍍 🥥 🥝 🍅 🥑 🥦 🌽 🥕 🧄 🧅 🥔 🍠 🥐 🍞 🥖 🧀 🥚 🍳 🥞 🥓 🍗 🍖 🌭 🍔 🍟 🍕 🥪 🌮 🌯 🥗 🍝 🍜 🍲 🍛 🍣 🍱 🍚 🍙 🍰 🎂 🧁 🍩 🍪 🍫 🍬 🍭 🍯 🥛 ☕ 🍵 🧃 🥤 🍺 🍻 🥂 🍷'),
  '⚽': _split(
      '⚽ 🏀 🏈 ⚾ 🎾 🏐 🏉 🎱 🏓 🏸 🥊 🥋 ⛳ 🚴 🏃 🧘 🏋️ 🤸 🏊 🎮 🕹 🎲 🎯 🎳 🎸 🥁 🎹 🎤 🎧 🎬 🎨 📸 📱 💻 ⌚ 📺 📷 💡 🔋 📚 ✏️ 📝 📌 📎 🔑 🛒 💰 💵 💳 🧾 📦 🚗 🚌 🏍 🚲 ✈️ 🚀 🏠 🏢 🏥 🏫 ⛪ 🕌 🛍'),
  '🌍': _split(
      '🌍 🌎 🌏 🗺 🏔 ⛰ 🌋 🏕 🏖 🏜 🏝 🌳 🌴 🌵 🌾 🌻 🌺 🌸 🌼 🌷 🌹 🍀 🍁 🍂 🐶 🐱 🐭 🐹 🐰 🦊 🐻 🐼 🐨 🐯 🦁 🐮 🐷 🐸 🐵 🐔 🐧 🐦 🦅 🦋 🐝 🐞 🐢 🐍 🦎 🐊 🦒 🦓 🐘 🦏 🦛 🐪 🐄 🐐'),
  '🇷🇼': _split(
      '🇷🇼 🇺🇬 🇰🇪 🇹🇿 🇧🇮 🇨🇩 🇳🇬 🇬🇭 🇿🇦 🇪🇹 🇫🇷 🇬🇧 🇺🇸 🇨🇦 🇧🇪 🇩🇪 🇨🇳 🇮🇳 🇯🇵 🇧🇷 🏳️ 🏴 🏁 🚩'),
};
