import 'package:flutter/material.dart';
import 'dart:io';
import 'package:video_player/video_player.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class VideoPlayerPage extends StatefulWidget {
  final String url;

  const VideoPlayerPage({super.key, required this.url});

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  late final VideoPlayerController? _controller;
  Player? _mediaKitPlayer;
  VideoController? _mediaKitController;
  bool _isReady = false;
  bool _isMuted = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      _initMediaKit();
    } else {
      _initVideoPlayer();
    }
  }

  void _initVideoPlayer() {
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..initialize().then((_) {
        if (mounted) {
          setState(() => _isReady = true);
          _controller!.setVolume(1.0);
          _controller!.play();
        }
      });
    _controller!.addListener(() {
      if (mounted) {
        setState(() {});
      }
    });
  }

  void _initMediaKit() async {
    _mediaKitPlayer = Player();
    _mediaKitController = VideoController(_mediaKitPlayer!);
    try {
      await _mediaKitPlayer!.open(Media(widget.url));
      if (mounted) {
        setState(() => _isReady = true);
        _mediaKitPlayer!.play();
      }
    } catch (e) {
      // Handle error silently or log if needed
    }
  }

  @override
  void dispose() {
    if (Platform.isWindows) {
      _mediaKitPlayer?.dispose();
    } else {
      _controller?.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Video')),
      body: _isReady
          ? Column(
              children: [
                Expanded(
                  child: Center(
                    child: Platform.isWindows
                        ? Video(controller: _mediaKitController!)
                        : AspectRatio(
                            aspectRatio: _controller!.value.aspectRatio,
                            child: VideoPlayer(_controller!),
                          ),
                  ),
                ),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Column(
                    children: [
                      if (!Platform.isWindows)
                        VideoProgressIndicator(
                          _controller!,
                          allowScrubbing: true,
                          colors: VideoProgressColors(
                            playedColor: Theme.of(context).colorScheme.primary,
                            bufferedColor: Colors.white24,
                            backgroundColor: Colors.white10,
                          ),
                        ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          IconButton(
                            icon: Icon(
                              Platform.isWindows
                                  ? (_mediaKitPlayer!.state.playing
                                      ? Icons.pause
                                      : Icons.play_arrow)
                                  : (_controller!.value.isPlaying
                                      ? Icons.pause
                                      : Icons.play_arrow),
                            ),
                            onPressed: () {
                              setState(() {
                                if (Platform.isWindows) {
                                  _mediaKitPlayer!.state.playing
                                      ? _mediaKitPlayer!.pause()
                                      : _mediaKitPlayer!.play();
                                } else {
                                  _controller!.value.isPlaying
                                      ? _controller!.pause()
                                      : _controller!.play();
                                }
                              });
                            },
                          ),
                          Text(
                            Platform.isWindows
                                ? '${_format(_mediaKitPlayer!.state.position)} / ${_format(_mediaKitPlayer!.state.duration)}'
                                : '${_format(_controller!.value.position)} / ${_format(_controller!.value.duration)}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          const Spacer(),
                          IconButton(
                            icon: Icon(
                              _isMuted ? Icons.volume_off : Icons.volume_up,
                            ),
                            onPressed: () {
                              setState(() {
                                _isMuted = !_isMuted;
                                if (Platform.isWindows) {
                                  _mediaKitPlayer!.setVolume(_isMuted ? 0 : 100);
                                } else {
                                  _controller!.setVolume(_isMuted ? 0 : 1);
                                }
                              });
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            )
          : const Center(child: CircularProgressIndicator()),
    );
  }

  String _format(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}
