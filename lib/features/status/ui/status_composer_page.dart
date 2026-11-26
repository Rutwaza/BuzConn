import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/i18n/tr.dart';
import '../../../core/services/image_shrinker.dart';
import '../../../core/theme/colors.dart';
import '../data/status_repository.dart';

/// Make a status: a photo, a short video, or coloured text.
/// Returns true when it was posted.
class StatusComposerPage extends StatefulWidget {
  const StatusComposerPage({super.key});

  @override
  State<StatusComposerPage> createState() => _StatusComposerPageState();
}

class _StatusComposerPageState extends State<StatusComposerPage> {
  static const _colors = [
    0xFF3A6EA5,
    0xFF0E1A2B,
    0xFF14B8A6,
    0xFFE5484D,
    0xFF7B61FF,
    0xFFE8B931
  ];
  final _text = TextEditingController();
  Uint8List? _image;
  File? _video;
  int _color = _colors.first;
  bool _posting = false;
  double _progress = 0;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  /// Biggest video a status may have when it can't be compressed first
  /// (Windows). Phones compress to 720p before upload.
  static const _maxDesktopVideoBytes = 60 * 1024 * 1024;
  bool _preparing = false;

  Future<void> _pick(ImageSource source, {required bool video}) async {
    if (_preparing) return;
    final picker = ImagePicker();
    final messenger = ScaffoldMessenger.of(context);
    if (video) {
      final f = await picker.pickVideo(
          source: source, maxDuration: const Duration(seconds: 60));
      if (f == null || !mounted) return;
      final file = File(f.path);
      if (Platform.isWindows && await file.length() > _maxDesktopVideoBytes) {
        messenger.showSnackBar(SnackBar(
            content: Text(tr('This video is too big. Pick one under 60 MB.'))));
        return;
      }
      setState(() {
        _video = file;
        _image = null;
      });
    } else {
      final f = await picker.pickImage(
          source: source, maxWidth: 1440, imageQuality: 80);
      if (f == null || !mounted) return;
      setState(() => _preparing = true);
      try {
        // Windows ignores maxWidth/imageQuality above, so the photo can be
        // huge: shrink it in the background (the window stays responsive).
        final raw = await f.readAsBytes();
        final bytes = await ImageShrinker.shrink(raw, maxSide: 1440);
        if (!mounted) return;
        setState(() {
          _image = bytes;
          _video = null;
        });
      } finally {
        if (mounted) setState(() => _preparing = false);
      }
    }
  }

  Future<void> _post() async {
    if (_image == null && _video == null && _text.text.trim().isEmpty) return;
    setState(() => _posting = true);
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await StatusRepository.instance.post(
        image: _image,
        video: _video,
        text: _text.text,
        bgColor: _color,
        onProgress: (p) => mounted ? setState(() => _progress = p) : null,
      );
      nav.pop(true);
    } catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text('${tr('Upload failed. Try again.')} $e')));
      if (mounted) setState(() => _posting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isText = _image == null && _video == null;
    return Scaffold(
      backgroundColor: isText ? Color(_color) : Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: Text(tr('New status')),
        actions: [
          if (isText)
            IconButton(
              tooltip: tr('Colour'),
              icon: const Icon(Icons.palette_rounded),
              onPressed: () => setState(() {
                _color =
                    _colors[(_colors.indexOf(_color) + 1) % _colors.length];
              }),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: _preparing
                  ? Column(mainAxisSize: MainAxisSize.min, children: [
                      const CircularProgressIndicator(color: Colors.white),
                      const SizedBox(height: 12),
                      Text(tr('Preparing photo…'),
                          style: const TextStyle(color: Colors.white70)),
                    ])
                  : _image != null
                      ? Image.memory(_image!,
                          fit: BoxFit.contain,
                          cacheHeight: (MediaQuery.sizeOf(context).height *
                                  MediaQuery.devicePixelRatioOf(context))
                              .round())
                      : _video != null
                          ? Column(mainAxisSize: MainAxisSize.min, children: [
                              const Icon(Icons.movie_rounded,
                                  color: Colors.white, size: 64),
                              const SizedBox(height: 8),
                              Text(tr('Video ready'),
                                  style: const TextStyle(color: Colors.white)),
                            ])
                          : Padding(
                              padding: const EdgeInsets.all(28),
                              child: TextField(
                                controller: _text,
                                autofocus: true,
                                maxLines: null,
                                maxLength: 300,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 28,
                                    fontWeight: FontWeight.w700),
                                decoration: InputDecoration(
                                  border: InputBorder.none,
                                  counterStyle:
                                      const TextStyle(color: Colors.white70),
                                  hintText: tr('Type a status'),
                                  hintStyle:
                                      const TextStyle(color: Colors.white60),
                                ),
                              ),
                            ),
            ),
          ),
          if (!isText)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _text,
                maxLength: 300,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: tr('Add a caption…'),
                  hintStyle: const TextStyle(color: Colors.white60),
                  counterStyle: const TextStyle(color: Colors.white54),
                ),
              ),
            ),
          if (_posting)
            LinearProgressIndicator(value: _progress > 0 ? _progress : null),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 12, 10),
              child: Row(
                children: [
                  // Windows has no camera in image_picker: gallery only.
                  if (!Platform.isWindows)
                    IconButton(
                      tooltip: tr('Take photo'),
                      onPressed: _posting
                          ? null
                          : () => _pick(ImageSource.camera, video: false),
                      icon: const Icon(Icons.photo_camera_rounded,
                          color: Colors.white),
                    ),
                  IconButton(
                    tooltip: tr('Photo'),
                    onPressed: _posting
                        ? null
                        : () => _pick(ImageSource.gallery, video: false),
                    icon: const Icon(Icons.photo_library_rounded,
                        color: Colors.white),
                  ),
                  IconButton(
                    tooltip: tr('Video'),
                    onPressed: _posting
                        ? null
                        : () => _pick(ImageSource.gallery, video: true),
                    icon:
                        const Icon(Icons.videocam_rounded, color: Colors.white),
                  ),
                  if (!isText)
                    IconButton(
                      tooltip: tr('Text'),
                      onPressed: _posting
                          ? null
                          : () => setState(() {
                                _image = null;
                                _video = null;
                              }),
                      icon: const Icon(Icons.text_fields_rounded,
                          color: Colors.white),
                    ),
                  const Spacer(),
                  FloatingActionButton(
                    backgroundColor: AppColors.secondary,
                    onPressed: _posting || _preparing ? null : _post,
                    child: const Icon(Icons.send_rounded, color: Colors.white),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
