import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/rendering.dart';

import '../../../core/i18n/tr.dart';
import '../../../core/services/image_shrinker.dart';
import '../../../core/widgets/emoji_picker.dart';

/// Photo editing for a status: colour filters, text you can drag, and
/// emoji stickers. Drag to move, pinch / mouse wheel to resize, long-press
/// (or right-click) to remove. [export] "prints" everything into one JPEG.
class StoryPhotoEditor extends StatefulWidget {
  const StoryPhotoEditor({super.key, required this.image});
  final Uint8List image;

  @override
  State<StoryPhotoEditor> createState() => StoryPhotoEditorState();
}

class _Layer {
  _Layer({
    required this.text,
    required this.emoji,
    this.pos = const Offset(0.5, 0.45),
    this.scale = 1,
  });
  String text;
  final bool emoji;
  Offset pos; // 0..1 of the photo
  double scale;
  Color color = Colors.white;
  bool boxed = false; // text on a coloured box
}

class StoryPhotoEditorState extends State<StoryPhotoEditor> {
  final _boundary = GlobalKey();
  final List<_Layer> _layers = [];
  String _filter = 'Original';
  double? _aspect;
  int _imageWidth = 1080;

  static const _textColors = [
    Colors.white,
    Colors.black,
    Color(0xFFFFD60A),
    Color(0xFFFF4D6D),
    Color(0xFF3A86FF),
    Color(0xFF2EC4B6),
  ];

  static final Map<String, List<double>?> filters = {
    'Original': null,
    'Vivid': [
      1.3, -0.1, -0.1, 0, 0, //
      -0.1, 1.3, -0.1, 0, 0, //
      -0.1, -0.1, 1.3, 0, 0, //
      0, 0, 0, 1, 0,
    ],
    'Warm': [
      1.15, 0, 0, 0, 12, //
      0, 1.02, 0, 0, 4, //
      0, 0, 0.85, 0, -8, //
      0, 0, 0, 1, 0,
    ],
    'Cool': [
      0.9, 0, 0, 0, -6, //
      0, 1.0, 0, 0, 2, //
      0, 0, 1.18, 0, 14, //
      0, 0, 0, 1, 0,
    ],
    'B&W': [
      0.33, 0.59, 0.11, 0, 0, //
      0.33, 0.59, 0.11, 0, 0, //
      0.33, 0.59, 0.11, 0, 0, //
      0, 0, 0, 1, 0,
    ],
    'Vintage': [
      0.62, 0.32, 0.17, 0, 18, //
      0.22, 0.68, 0.10, 0, 10, //
      0.17, 0.27, 0.48, 0, 6, //
      0, 0, 0, 1, 0,
    ],
    'Fade': [
      0.85, 0.05, 0.05, 0, 28, //
      0.05, 0.85, 0.05, 0, 28, //
      0.05, 0.05, 0.85, 0, 28, //
      0, 0, 0, 1, 0,
    ],
  };

  bool get edited => _filter != 'Original' || _layers.isNotEmpty;

  @override
  void initState() {
    super.initState();
    ui.decodeImageFromList(widget.image, (img) {
      if (!mounted) return;
      setState(() {
        _aspect = img.width / img.height;
        _imageWidth = img.width;
      });
    });
  }

  Future<void> addText() async {
    final c = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Add text')),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLength: 80,
          decoration: InputDecoration(
            hintText: tr('Say something…'),
            suffixIcon: EmojiButton(controller: c),
          ),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr('Cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, c.text),
              child: Text(tr('Add'))),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty) return;
    setState(() => _layers.add(_Layer(text: text.trim(), emoji: false)));
  }

  Future<void> addSticker() async {
    final c = TextEditingController();
    await showEmojiPicker(context, controller: c);
    final picked = c.text.characters.toList();
    if (picked.isEmpty) return;
    setState(() {
      for (var i = 0; i < picked.length && i < 6; i++) {
        _layers.add(_Layer(
          text: picked[i],
          emoji: true,
          scale: 1.6,
          pos: Offset(0.3 + 0.08 * i, 0.3 + 0.06 * i),
        ));
      }
    });
  }

  /// One JPEG with the filter, texts and stickers drawn in.
  Future<Uint8List> export() async {
    if (!edited) return widget.image;
    final box =
        _boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final ratio =
        (_imageWidth.clamp(480, 1440) / box.size.width).clamp(1.0, 4.0);
    final image = await box.toImage(pixelRatio: ratio);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final bytes = png!.buffer.asUint8List();
    // PNG -> smaller JPEG in the background.
    return ImageShrinker.shrink(bytes, maxSide: 1440);
  }

  @override
  Widget build(BuildContext context) {
    final matrix = filters[_filter];
    Widget photo = Image.memory(widget.image,
        fit: BoxFit.cover, gaplessPlayback: true);
    if (matrix != null) {
      photo = ColorFiltered(colorFilter: ColorFilter.matrix(matrix), child: photo);
    }
    return Column(
      children: [
        Expanded(
          child: Center(
            child: _aspect == null
                ? const CircularProgressIndicator(color: Colors.white)
                : AspectRatio(
                    aspectRatio: _aspect!,
                    child: LayoutBuilder(builder: (context, c) {
                      final size = c.biggest;
                      return RepaintBoundary(
                        key: _boundary,
                        child: ClipRect(
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              photo,
                              for (final l in _layers) _layerWidget(l, size),
                            ],
                          ),
                        ),
                      );
                    }),
                  ),
          ),
        ),
        SizedBox(
          height: 74,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            children: [
              for (final f in filters.entries)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    onTap: () => setState(() => _filter = f.key),
                    child: Column(
                      children: [
                        Container(
                          width: 44,
                          height: 40,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: _filter == f.key
                                  ? Colors.white
                                  : Colors.white24,
                              width: _filter == f.key ? 2 : 1,
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: f.value == null
                              ? Image.memory(widget.image,
                                  fit: BoxFit.cover, cacheWidth: 96)
                              : ColorFiltered(
                                  colorFilter: ColorFilter.matrix(f.value!),
                                  child: Image.memory(widget.image,
                                      fit: BoxFit.cover, cacheWidth: 96)),
                        ),
                        const SizedBox(height: 3),
                        Text(tr(f.key),
                            style: TextStyle(
                                color: _filter == f.key
                                    ? Colors.white
                                    : Colors.white60,
                                fontSize: 10.5)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _layerWidget(_Layer l, Size size) {
    final base = l.emoji ? 48.0 : 26.0;
    Widget child = l.emoji
        ? Text(l.text, style: TextStyle(fontSize: base * l.scale))
        : Container(
            padding: l.boxed
                ? const EdgeInsets.symmetric(horizontal: 10, vertical: 4)
                : EdgeInsets.zero,
            decoration: l.boxed
                ? BoxDecoration(
                    color: l.color == Colors.white ? Colors.black87 : l.color,
                    borderRadius: BorderRadius.circular(8))
                : null,
            child: Text(
              l.text,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: l.boxed && l.color != Colors.white
                    ? Colors.white
                    : l.color,
                fontSize: base * l.scale,
                fontWeight: FontWeight.w800,
                shadows: l.boxed
                    ? null
                    : const [Shadow(blurRadius: 6, color: Colors.black54)],
              ),
            ),
          );
    double startScale = l.scale;
    return Positioned(
      left: l.pos.dx * size.width,
      top: l.pos.dy * size.height,
      child: FractionalTranslation(
        translation: const Offset(-0.5, -0.5),
        child: Listener(
          // Mouse wheel on desktop = resize.
          onPointerSignal: (e) {
            if (e is PointerScrollEvent) {
              setState(() => l.scale =
                  (l.scale - e.scrollDelta.dy / 400).clamp(0.4, 5.0));
            }
          },
          child: GestureDetector(
            onScaleStart: (_) => startScale = l.scale,
            onScaleUpdate: (d) => setState(() {
              l.pos = Offset(
                (l.pos.dx + d.focalPointDelta.dx / size.width).clamp(0.0, 1.0),
                (l.pos.dy + d.focalPointDelta.dy / size.height).clamp(0.0, 1.0),
              );
              if (d.pointerCount > 1) {
                l.scale = (startScale * d.scale).clamp(0.4, 5.0);
              }
            }),
            // Tap text: next colour / boxed style.
            onTap: l.emoji
                ? null
                : () => setState(() {
                      final i = _textColors.indexOf(l.color);
                      if (i == _textColors.length - 1) {
                        l.boxed = !l.boxed;
                        l.color = _textColors.first;
                      } else {
                        l.color = _textColors[i + 1];
                      }
                    }),
            onLongPress: () => setState(() => _layers.remove(l)),
            onSecondaryTap: () => setState(() => _layers.remove(l)),
            child: child,
          ),
        ),
      ),
    );
  }
}
