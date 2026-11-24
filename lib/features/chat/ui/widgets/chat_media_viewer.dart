part of '../chat_page.dart';

// Full-screen viewer for chat photos and videos.
class _ChatMediaItem {
  final String url;
  final String type; // image | video

  const _ChatMediaItem({
    required this.url,
    required this.type,
  });
}

class _ChatMediaViewerPage extends StatefulWidget {
  const _ChatMediaViewerPage({
    required this.items,
    required this.initialIndex,
  });

  final List<_ChatMediaItem> items;
  final int initialIndex;

  @override
  State<_ChatMediaViewerPage> createState() => _ChatMediaViewerPageState();
}

class _ChatMediaViewerPageState extends State<_ChatMediaViewerPage> {
  late final PageController _controller;
  int _index = 0;
  VideoPlayerController? _videoController;
  Player? _mediaKitPlayer;
  VideoController? _mediaKitController;
  String? _currentVideoUrl;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.items.length - 1);
    _controller = PageController(initialPage: _index);
    _initForIndex(_index);
  }

  @override
  void dispose() {
    _controller.dispose();
    if (Platform.isWindows) {
      _mediaKitPlayer?.dispose();
    } else {
      _videoController?.dispose();
    }
    super.dispose();
  }

  void _initForIndex(int index) async {
    final item = widget.items[index];
    if (item.type != 'video') {
      if (Platform.isWindows) {
        _mediaKitPlayer?.pause();
        _mediaKitPlayer?.dispose();
        _mediaKitPlayer = null;
        _mediaKitController = null;
      } else {
        _videoController?.pause();
        _videoController?.dispose();
        _videoController = null;
      }
      _currentVideoUrl = null;
      return;
    }
    if (_currentVideoUrl == item.url) return;
    if (Platform.isWindows) {
      _mediaKitPlayer?.dispose();
      _mediaKitPlayer = Player();
      _mediaKitController = VideoController(_mediaKitPlayer!);
      try {
        await _mediaKitPlayer!.open(Media(item.url));
        _currentVideoUrl = item.url;
        if (mounted) {
          setState(() {});
          _mediaKitPlayer!.play();
        }
      } catch (e) {
        // Handle error silently
      }
    } else {
      _videoController?.dispose();
      final controller = VideoPlayerController.networkUrl(Uri.parse(item.url));
      _videoController = controller;
      _currentVideoUrl = item.url;
      controller.initialize().then((_) {
        if (mounted) {
          setState(() {});
          controller.play();
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView.builder(
              controller: _controller,
              itemCount: items.length,
              onPageChanged: (value) {
                setState(() => _index = value);
                _initForIndex(value);
              },
              itemBuilder: (context, index) {
                final item = items[index];
                if (item.type == 'image') {
                  return InteractiveViewer(
                    child: Center(
                      child: Image.network(item.url, fit: BoxFit.contain),
                    ),
                  );
                }
                final isInitialized = Platform.isWindows
                    ? _mediaKitPlayer != null
                    : _videoController != null &&
                        _videoController!.value.isInitialized;
                if (!isInitialized) {
                  return const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  );
                }
                return Column(
                  children: [
                    Expanded(
                      child: Center(
                        child: Platform.isWindows
                            ? Video(controller: _mediaKitController!)
                            : AspectRatio(
                                aspectRatio:
                                    _videoController!.value.aspectRatio,
                                child: VideoPlayer(_videoController!),
                              ),
                      ),
                    ),
                    if (!Platform.isWindows)
                      VideoProgressIndicator(
                        _videoController!,
                        allowScrubbing: true,
                        colors: const VideoProgressColors(
                          playedColor: Colors.white,
                          bufferedColor: Colors.white24,
                          backgroundColor: Colors.white10,
                        ),
                      ),
                    if (!Platform.isWindows)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        child: Row(
                          children: [
                            IconButton(
                              icon: Icon(
                                _videoController!.value.isPlaying
                                    ? Icons.pause
                                    : Icons.play_arrow,
                                color: Colors.white,
                              ),
                              onPressed: () {
                                _videoController!.value.isPlaying
                                    ? _videoController!.pause()
                                    : _videoController!.play();
                                setState(() {});
                              },
                            ),
                            const Spacer(),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
          SizedBox(
            height: 90,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final item = items[i];
                final isActive = i == _index;
                return GestureDetector(
                  onTap: () {
                    _controller.animateToPage(
                      i,
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOut,
                    );
                    setState(() => _index = i);
                    _initForIndex(i);
                  },
                  child: Container(
                    width: 70,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: isActive ? Colors.white : Colors.white24,
                        width: isActive ? 2 : 1,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          item.type == 'image'
                              ? Image.network(item.url, fit: BoxFit.cover)
                              : FutureBuilder<Uint8List?>(
                                  future: VideoThumbnail.thumbnailData(
                                    video: item.url,
                                    imageFormat: ImageFormat.JPEG,
                                    maxWidth: 140,
                                    quality: 60,
                                  ),
                                  builder: (context, snap) {
                                    if (snap.data == null) {
                                      return const ColoredBox(
                                        color: Colors.black12,
                                        child: Center(
                                          child: Icon(
                                            Icons.play_arrow,
                                            color: Colors.white70,
                                          ),
                                        ),
                                      );
                                    }
                                    return Image.memory(
                                      snap.data!,
                                      fit: BoxFit.cover,
                                    );
                                  },
                                ),
                          if (item.type == 'video')
                            const Center(
                              child: Icon(
                                Icons.play_circle_fill,
                                color: Colors.white70,
                                size: 18,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
