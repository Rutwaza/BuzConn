import 'package:flutter/material.dart';
import 'package:businessfinder/core/services/video_compressor.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:io';

import '../../../core/theme/colors.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../data/models/post_model.dart';
import '../../../data/repositories/posts_repository.dart';
import '../../../core/services/r2_storage_service.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

class CreatePostPage extends ConsumerStatefulWidget {
  const CreatePostPage({super.key});

  @override
  ConsumerState<CreatePostPage> createState() => _CreatePostPageState();
}

class _LocalMedia {
  final File file;
  final PostMediaType type;

  const _LocalMedia({required this.file, required this.type});
}

class _CreatePostPageState extends ConsumerState<CreatePostPage> {
  final _formKey = GlobalKey<FormState>();
  final _contentController = TextEditingController();
  final PostsRepository _postsRepository = PostsRepository();

  final List<_LocalMedia> _selectedMedia = [];
  final Map<String, List<Uint8List>> _videoCoverOptions = {};
  final Map<String, Uint8List> _selectedVideoCover = {};
  final PageController _previewController = PageController();
  int _previewIndex = 0;
  bool _isLoading = false;
  bool _isBusinessUser = false;
  bool _isCheckingUserType = true;
  bool _showSuccess = false;
  bool _isLoadingBusinesses = false;
  List<Map<String, dynamic>> _businesses = [];
  String? _selectedBusinessId;
  bool _postAsProfile = true;

  // Phase 3: videos are compressed on the phone (VideoCompressor), so people
  // can pick bigger originals. The upload itself must still be <= 20 MB.
  static const int _maxPickedVideoBytes = 300 * 1024 * 1024;
  static const int _maxVideoSizeBytes = 20 * 1024 * 1024;

  @override
  void dispose() {
    _contentController.removeListener(_handleDraftChanged);
    _contentController.dispose();
    _previewController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _contentController.addListener(_handleDraftChanged);
    _loadUserType();
    _loadBusinesses();
  }

  void _handleDraftChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _loadUserType() async {
    setState(() {
      _isCheckingUserType = true;
    });
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        _isBusinessUser = false;
        return;
      }
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      final userType = userDoc.data()?['userType'];
      _isBusinessUser = userType == 'business';
    } catch (_) {
      _isBusinessUser = false;
    } finally {
      if (mounted) {
        setState(() {
          _isCheckingUserType = false;
        });
      }
    }
  }

  Future<void> _loadBusinesses() async {
    setState(() {
      _isLoadingBusinesses = true;
    });
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        _businesses = [];
        return;
      }
      final snapshot = await FirebaseFirestore.instance
          .collection('businesses')
          .where('ownerId', isEqualTo: user.uid)
          .where('isActive', isEqualTo: true)
          .get();
      _businesses = snapshot.docs
          .map((doc) => {
                'id': doc.id,
                'name': (doc.data())['name'] ?? 'Unnamed Page',
              })
          .toList();
      _postAsProfile = !_isBusinessUser;
      if (_businesses.isNotEmpty && _isBusinessUser) {
        _selectedBusinessId = _businesses.first['id'] as String;
      } else {
        _selectedBusinessId = null;
      }
    } catch (_) {
      _businesses = [];
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingBusinesses = false;
        });
      }
    }
  }

  Future<void> _pickImages() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: true,
      );
      if (result == null) return;
      final picked = result.files
          .where((file) => file.path != null)
          .map((file) => _LocalMedia(
                file: File(file.path!),
                type: PostMediaType.image,
              ))
          .toList();
      if (picked.isEmpty) return;
      setState(() {
        _selectedMedia.addAll(picked);
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Image picker failed: $e')),
        );
      }
    }
  }

  Future<void> _pickVideos() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.video,
        allowMultiple: true,
      );
      if (result == null) return;

      final oversizedVideos = <String>[];
      final picked = result.files
          .where((file) => file.path != null)
          .where((file) {
            final isAllowed = file.size <= _maxPickedVideoBytes;
            if (!isAllowed) {
              oversizedVideos
                  .add('${file.name} (${_formatFileSize(file.size)})');
            }
            return isAllowed;
          })
          .map((file) => _LocalMedia(
                file: File(file.path!),
                type: PostMediaType.video,
              ))
          .toList();

      if (oversizedVideos.isNotEmpty) {
        await _showVideoSizeAlert(oversizedVideos);
      }
      if (picked.isEmpty) return;

      setState(() {
        _selectedMedia.addAll(picked);
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Video picker failed: $e')),
        );
      }
    }
  }

  String _formatFileSize(int bytes) {
    final sizeInMb = bytes / (1024 * 1024);
    return '${sizeInMb.toStringAsFixed(1)} MB';
  }

  Future<void> _showVideoSizeAlert(List<String> fileNames) async {
    if (!mounted) return;
    final preview = fileNames.take(3).join(', ');
    final hasMore = fileNames.length > 3;

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Video too large'),
        content: Text(
          hasMore
              ? 'Some selected videos are too large (over 300 MB).\n\nExamples: $preview'
              : 'This video is too large (over 300 MB).\n\n$preview\n\nPlease trim it and try again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<bool> _validateSelectedVideos() async {
    final oversizedVideos = <String>[];
    for (final item
        in _selectedMedia.where((m) => m.type == PostMediaType.video)) {
      final size = await item.file.length();
      if (size > _maxPickedVideoBytes) {
        final name = item.file.uri.pathSegments.isNotEmpty
            ? item.file.uri.pathSegments.last
            : 'video';
        oversizedVideos.add('$name (${_formatFileSize(size)})');
      }
    }

    if (oversizedVideos.isNotEmpty) {
      await _showVideoSizeAlert(oversizedVideos);
      return false;
    }
    return true;
  }

  Future<String?> _uploadImage(File imageFile) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      final bytes = await imageFile.readAsBytes();
      final path =
          '${user?.uid ?? 'anon'}/${DateTime.now().millisecondsSinceEpoch}.jpg';
      return await R2StorageService.instance.uploadImage(
        bucket: 'post-images',
        path: path,
        bytes: bytes,
      );
    } catch (e) {
      debugPrint('Error uploading image: $e');
      return null;
    }
  }

  Future<String?> _uploadVideo(File originalFile) async {
    try {
      // Shrink to 720p on the phone first (Android/iOS).
      final videoFile = await VideoCompressor.compress(originalFile);
      final size = await videoFile.length();
      if (size > _maxVideoSizeBytes) {
        debugPrint(
            'Video rejected for size: ${videoFile.path} (${_formatFileSize(size)})');
        return null;
      }

      final user = FirebaseAuth.instance.currentUser;
      final bytes = await videoFile.readAsBytes();
      final path =
          '${user?.uid ?? 'anon'}/${DateTime.now().millisecondsSinceEpoch}.mp4';
      final url = await R2StorageService.instance.uploadVideo(
        bucket: 'post-videos',
        path: path,
        bytes: bytes,
      );
      if (videoFile.path != originalFile.path) {
        await VideoCompressor.cleanUp();
      }
      return url;
    } catch (e) {
      debugPrint('Error uploading video: $e');
      return null;
    }
  }

  Future<String?> _uploadThumbnailBytes(Uint8List bytes) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      final path =
          '${user?.uid ?? 'anon'}/${DateTime.now().millisecondsSinceEpoch}_cover.jpg';
      return await R2StorageService.instance.uploadImage(
        bucket: 'post-images',
        path: path,
        bytes: bytes,
      );
    } catch (e) {
      debugPrint('Error uploading video thumbnail: $e');
      return null;
    }
  }

  Future<List<Uint8List>> _ensureVideoCoverOptions(File file) async {
    final key = file.path;
    if (_videoCoverOptions.containsKey(key)) {
      return _videoCoverOptions[key]!;
    }
    final frames = <Uint8List>[];
    if (Platform.isWindows) {
      // On Windows, video_thumbnail is not supported. Load a local placeholder icon to keep the picker functional.
      try {
        final bytes = (await rootBundle.load('assets/icons/alien.png'))
            .buffer
            .asUint8List();
        frames.add(bytes);
      } catch (_) {
        // Fallback to an empty buffer; UI shows a simple video icon placeholder.
        frames.add(Uint8List(0));
      }
    } else {
      for (final timeMs in <int>[0, 1200, 2600, 4200]) {
        final bytes = await VideoThumbnail.thumbnailData(
          video: file.path,
          imageFormat: ImageFormat.JPEG,
          maxWidth: 420,
          quality: 75,
          timeMs: timeMs,
        );
        if (bytes != null) {
          frames.add(bytes);
        }
      }
      if (frames.isEmpty) {
        final fallback = await VideoThumbnail.thumbnailData(
          video: file.path,
          imageFormat: ImageFormat.JPEG,
          maxWidth: 420,
          quality: 75,
        );
        if (fallback != null) {
          frames.add(fallback);
        }
      }
    }
    _videoCoverOptions[key] = frames;
    if (frames.isNotEmpty && frames.first.isNotEmpty) {
      _selectedVideoCover.putIfAbsent(key, () => frames.first);
    }
    return frames;
  }

  Future<void> _pickVideoCover(_LocalMedia media) async {
    final options = await _ensureVideoCoverOptions(media.file);
    if (!mounted || options.isEmpty) return;
    final currentCover = _selectedVideoCover[media.file.path];
    final coverOptions = List<Uint8List>.from(options);
    if (currentCover != null && !coverOptions.contains(currentCover)) {
      coverOptions.insert(0, currentCover);
    }
    final selected = await showModalBottomSheet<Uint8List>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Choose video cover',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Pick the frame people will notice first.',
                  style: TextStyle(color: AppColors.grey),
                ),
                const SizedBox(height: 14),
                OutlinedButton.icon(
                  onPressed: () async {
                    final result = await FilePicker.platform.pickFiles(
                      type: FileType.image,
                    );
                    if (result == null || result.files.isEmpty) return;
                    final path = result.files.single.path;
                    if (path == null || !context.mounted) return;
                    final bytes = await File(path).readAsBytes();
                    if (context.mounted) Navigator.pop(context, bytes);
                  },
                  icon: const Icon(Icons.folder_open_rounded),
                  label: const Text('Browse a cover image'),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 92,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: coverOptions.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 10),
                    itemBuilder: (context, index) {
                      final bytes = coverOptions[index];
                      final isSelected =
                          _selectedVideoCover[media.file.path] == bytes;
                      return GestureDetector(
                        onTap: () => Navigator.pop(context, bytes),
                        child: Container(
                          width: 110,
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: isSelected
                                  ? AppColors.primary
                                  : Colors.transparent,
                              width: 2,
                            ),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: bytes.isNotEmpty
                                ? Image.memory(bytes, fit: BoxFit.cover)
                                : Container(
                                    color: AppColors.lightGrey,
                                    child:
                                        const Icon(Icons.video_file, size: 32),
                                  ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.pop(
                      context,
                      _selectedVideoCover[media.file.path] ?? options.first,
                    ),
                    child: const Text('Use selected frame'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (selected == null) return;
    setState(() {
      _selectedVideoCover[media.file.path] = selected;
    });
  }

  void _moveMedia(int from, int to) {
    if (from < 0 || from >= _selectedMedia.length) return;
    if (to < 0 || to >= _selectedMedia.length) return;
    setState(() {
      final item = _selectedMedia.removeAt(from);
      _selectedMedia.insert(to, item);
      _previewIndex = to;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_previewController.hasClients && _selectedMedia.isNotEmpty) {
        _previewController.jumpToPage(_previewIndex);
      }
    });
  }

  void _removeMediaAt(int index) {
    if (index < 0 || index >= _selectedMedia.length) return;
    setState(() {
      final removed = _selectedMedia.removeAt(index);
      _videoCoverOptions.remove(removed.file.path);
      _selectedVideoCover.remove(removed.file.path);
      if (_previewIndex >= _selectedMedia.length) {
        _previewIndex = _selectedMedia.isEmpty ? 0 : _selectedMedia.length - 1;
      }
    });
    if (_selectedMedia.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_previewController.hasClients) {
          _previewController.jumpToPage(_previewIndex);
        }
      });
    }
  }

  Future<void> _jumpToPreview(int index) async {
    if (index < 0 || index >= _selectedMedia.length) return;
    setState(() => _previewIndex = index);
    if (_previewController.hasClients) {
      await _previewController.animateToPage(
        index,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
  }

  String get _postingIdentityLabel {
    if (_postAsProfile || _selectedBusinessId == null) {
      return 'Posting as your profile';
    }
    for (final business in _businesses) {
      if (business['id'] == _selectedBusinessId) {
        return 'Posting as ${business['name']}';
      }
    }
    return 'Posting as your page';
  }

  int get _captionLength => _contentController.text.trim().length;

  String get _draftEnergyLabel {
    if (_selectedMedia.isNotEmpty && _captionLength > 100) {
      return 'Ready to spotlight';
    }
    if (_selectedMedia.isNotEmpty) {
      return 'Visual draft';
    }
    if (_captionLength > 0) {
      return 'Caption-first post';
    }
    return 'Start your next moment';
  }

  Future<void> _createPost() async {
    if (!_postAsProfile && _selectedBusinessId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a page.')),
      );
      return;
    }
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
    });

    try {
      final videosAreValid = await _validateSelectedVideos();
      if (!videosAreValid) {
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }
        return;
      }

      final uploadedMedia = <PostMedia>[];
      for (final item in _selectedMedia) {
        final url = item.type == PostMediaType.video
            ? await _uploadVideo(item.file)
            : await _uploadImage(item.file);
        if (url == null) {
          if (!mounted) return;
          setState(() {
            _isLoading = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                item.type == PostMediaType.video
                    ? 'Video upload failed. Please use a video under 10 MB and try again.'
                    : 'Image upload failed. Please try another image and try again.',
              ),
            ),
          );
          return;
        }
        String? thumbnailUrl;
        if (item.type == PostMediaType.video) {
          final selectedCover = _selectedVideoCover[item.file.path];
          if (selectedCover != null) {
            thumbnailUrl = await _uploadThumbnailBytes(selectedCover);
          }
        }
        uploadedMedia.add(
          PostMedia(
            type: item.type,
            url: url,
            thumbnailUrl: thumbnailUrl,
          ),
        );
      }

      final postId = await _postsRepository.createPost(
        content: _contentController.text.trim(),
        businessId: _postAsProfile ? null : _selectedBusinessId,
        media: uploadedMedia,
      );

      if (mounted) {
        _triggerSuccessAnimation();
      }

      _contentController.clear();
      setState(() {
        _selectedMedia.clear();
        _previewIndex = 0;
      });

      if (!mounted) return;
      Navigator.of(context).pop(postId);
    } catch (e) {
      if (!mounted) return;
      final message = e.toString().replaceFirst('Exception: ', '');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            message.isNotEmpty
                ? 'Could not create post. $message'
                : 'Could not create post. Please try again.',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _triggerSuccessAnimation() {
    setState(() {
      _showSuccess = true;
    });
    Future.delayed(const Duration(milliseconds: 1400), () {
      if (!mounted) return;
      setState(() {
        _showSuccess = false;
      });
    });
  }

  Widget _previewAction({
    required IconData icon,
    required VoidCallback? onTap,
  }) {
    return Material(
      color: Colors.black.withValues(alpha: 0.42),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(
            icon,
            color: onTap == null ? Colors.white38 : Colors.white,
            size: 18,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isCheckingUserType) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('New Post'),
        actions: [
          TextButton(
            onPressed: _isLoading ? null : _createPost,
            child: Text(
              'Share',
              style: TextStyle(
                color: _isLoading ? AppColors.grey : AppColors.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isDesktopWide = constraints.maxWidth >= 1100;
          return Stack(
            children: [
              Scrollbar(
                thumbVisibility: isDesktopWide,
                child: SingleChildScrollView(
                  padding: EdgeInsets.symmetric(
                    horizontal: isDesktopWide ? 28 : 16,
                    vertical: 16,
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: isDesktopWide ? 1080 : 720,
                      ),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(18),
                              decoration: BoxDecoration(
                                color: Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? const Color(0xFF151A24)
                                    : Colors.white,
                                borderRadius: BorderRadius.circular(22),
                                border: Border.all(
                                  color: Theme.of(context).brightness ==
                                          Brightness.dark
                                      ? Colors.white10
                                      : Colors.black12,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        width: 44,
                                        height: 44,
                                        decoration: BoxDecoration(
                                          color: AppColors.primary
                                              .withValues(alpha: 0.14),
                                          borderRadius:
                                              BorderRadius.circular(14),
                                        ),
                                        child: const Icon(
                                          Icons.auto_awesome_rounded,
                                          color: AppColors.primary,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              'Create your next spotlight',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleMedium
                                                  ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.w800),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              'Share something visual, personal, and scroll-stopping.',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall
                                                  ?.copyWith(
                                                      color: AppColors.grey),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 8,
                                        ),
                                        decoration: BoxDecoration(
                                          color: AppColors.primary
                                              .withValues(alpha: 0.10),
                                          borderRadius:
                                              BorderRadius.circular(14),
                                        ),
                                        child: Column(
                                          children: [
                                            Text(
                                              '$_captionLength',
                                              style: const TextStyle(
                                                color: AppColors.primary,
                                                fontWeight: FontWeight.w800,
                                              ),
                                            ),
                                            const Text(
                                              'chars',
                                              style: TextStyle(
                                                color: AppColors.primary,
                                                fontSize: 11,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 14),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 10,
                                    ),
                                    decoration: BoxDecoration(
                                      color: AppColors.primary
                                          .withValues(alpha: 0.08),
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    child: Row(
                                      children: [
                                        const Icon(
                                          Icons.person_pin_circle_outlined,
                                          size: 18,
                                          color: AppColors.primary,
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            _postingIdentityLabel,
                                            style: const TextStyle(
                                              color: AppColors.primary,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      _ComposerBadge(
                                        icon: Icons.auto_awesome_rounded,
                                        label: _draftEnergyLabel,
                                      ),
                                      _ComposerBadge(
                                        icon: Icons.collections_rounded,
                                        label: _selectedMedia.isEmpty
                                            ? 'No media yet'
                                            : '${_selectedMedia.length} media attached',
                                      ),
                                      _ComposerBadge(
                                        icon: _postAsProfile
                                            ? Icons.person_rounded
                                            : Icons.campaign_rounded,
                                        label: _postAsProfile
                                            ? 'Profile post'
                                            : 'Page post',
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 18),
                            if (_isLoadingBusinesses)
                              const Padding(
                                padding: EdgeInsets.only(bottom: 12),
                                child: LinearProgressIndicator(),
                              ),
                            if (_isBusinessUser &&
                                _businesses.isEmpty &&
                                !_isLoadingBusinesses)
                              const Card(
                                color: AppColors.lightGrey,
                                child: Padding(
                                  padding: EdgeInsets.all(12),
                                  child: Text(
                                      'You have no active pages yet. You can still post from your profile.'),
                                ),
                              ),
                            if (_isBusinessUser || _businesses.isNotEmpty) ...[
                              _buildPostingAsSection(),
                              const SizedBox(height: 16),
                            ],
                            Builder(
                              builder: (context) {
                                if (isDesktopWide) {
                                  return Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        flex: 5,
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            AppTextField(
                                              controller: _contentController,
                                              label: 'Caption',
                                              hintText:
                                                  'Share your spotlight...',
                                              textCapitalization:
                                                  TextCapitalization.sentences,
                                              maxLines: 5,
                                              maxLength: 300,
                                              onChanged: (_) => setState(() {}),
                                              validator: (value) {
                                                if (value == null ||
                                                    value.isEmpty) {
                                                  return 'Please write something';
                                                }
                                                return null;
                                              },
                                            ),
                                            const SizedBox(height: 20),
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: FilledButton.tonalIcon(
                                                    onPressed: _pickImages,
                                                    icon: const Icon(Icons
                                                        .photo_library_outlined),
                                                    label: const Text('Photo'),
                                                  ),
                                                ),
                                                const SizedBox(width: 12),
                                                Expanded(
                                                  child: FilledButton.tonalIcon(
                                                    onPressed: _pickVideos,
                                                    icon: const Icon(Icons
                                                        .movie_creation_outlined),
                                                    label: const Text('Video'),
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 20),
                                            _buildLocationNote(),
                                            const SizedBox(height: 20),
                                            Container(
                                              padding: const EdgeInsets.all(16),
                                              decoration: BoxDecoration(
                                                color: AppColors.primary
                                                    .withValues(alpha: 0.06),
                                                borderRadius:
                                                    BorderRadius.circular(18),
                                              ),
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    'Desktop studio tips',
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .titleSmall
                                                        ?.copyWith(
                                                            fontWeight:
                                                                FontWeight
                                                                    .w700),
                                                  ),
                                                  const SizedBox(height: 10),
                                                  const Text(
                                                    'Build the story on the left, shape the visual stack on the right, then publish once it feels scroll-stopping.',
                                                    style: TextStyle(
                                                        color: AppColors.grey,
                                                        height: 1.4),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            const SizedBox(height: 24),
                                            AppButton(
                                              text: 'Share Post',
                                              onPressed: _createPost,
                                              isLoading: _isLoading,
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 20),
                                      Expanded(
                                        flex: 6,
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            _buildMediaPreviewSection(),
                                            const SizedBox(height: 20),
                                            _buildPreviewCard(),
                                          ],
                                        ),
                                      ),
                                    ],
                                  );
                                }

                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    AppTextField(
                                      controller: _contentController,
                                      label: 'Caption',
                                      hintText: 'Share your spotlight...',
                                      textCapitalization:
                                          TextCapitalization.sentences,
                                      maxLines: 3,
                                      maxLength: 300,
                                      onChanged: (_) => setState(() {}),
                                      validator: (value) {
                                        if (value == null || value.isEmpty) {
                                          return 'Please write something';
                                        }
                                        return null;
                                      },
                                    ),
                                    const SizedBox(height: 24),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: FilledButton.tonalIcon(
                                            onPressed: _pickImages,
                                            icon: const Icon(
                                                Icons.photo_library_outlined),
                                            label: const Text('Photo'),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: FilledButton.tonalIcon(
                                            onPressed: _pickVideos,
                                            icon: const Icon(
                                                Icons.movie_creation_outlined),
                                            label: const Text('Video'),
                                          ),
                                        ),
                                      ],
                                    ),
                                    if (_selectedMedia.isNotEmpty) ...[
                                      const SizedBox(height: 12),
                                      _buildMediaPreviewSection(),
                                    ],
                                    const SizedBox(height: 24),
                                    _buildLocationNote(),
                                    const SizedBox(height: 24),
                                    _buildPreviewCard(),
                                    const SizedBox(height: 32),
                                    AppButton(
                                      text: 'Share Post',
                                      onPressed: _createPost,
                                      isLoading: _isLoading,
                                    ),
                                  ],
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _showSuccess ? 1 : 0,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOut,
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.2),
                    child: Center(
                      child: AnimatedScale(
                        scale: _showSuccess ? 1 : 0.8,
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeOutBack,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 24, vertical: 20),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.15),
                                blurRadius: 20,
                                offset: const Offset(0, 10),
                              ),
                            ],
                          ),
                          child: const Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.check_circle,
                                  color: Colors.green, size: 48),
                              SizedBox(height: 8),
                              Text(
                                'Posted!',
                                style: TextStyle(
                                    fontSize: 18, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildPostingAsSection() {
    if (!_isBusinessUser && _businesses.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Posting as',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              label: const Text('My Profile'),
              selected: _postAsProfile,
              onSelected: (_) {
                setState(() {
                  _postAsProfile = true;
                });
              },
            ),
            ..._businesses.map(
              (b) => ChoiceChip(
                label: Text(b['name'] as String),
                selected: !_postAsProfile && _selectedBusinessId == b['id'],
                onSelected: (_) {
                  setState(() {
                    _postAsProfile = false;
                    _selectedBusinessId = b['id'] as String;
                  });
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildMediaPreviewSection() {
    if (_selectedMedia.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFF151A24)
              : Colors.white,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.white10
                : Colors.black12,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.perm_media_rounded,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Studio preview',
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Drop photos or videos in here and shape the visual story before you publish.',
                        style: TextStyle(color: AppColors.grey),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Container(
              height: 300,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF101827), Color(0xFF20324B)],
                ),
              ),
              child: const Center(
                child: Text(
                  'Your media preview will appear here',
                  style: TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFF151A24)
            : Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: Theme.of(context).brightness == Brightness.dark
              ? Colors.white10
              : Colors.black12,
        ),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Media Preview',
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              Text(
                '${_previewIndex + 1}/${_selectedMedia.length}',
                style: const TextStyle(
                  color: AppColors.grey,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Drag thumbnails to reorder your story flow.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppColors.grey,
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 340,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: PageView.builder(
                controller: _previewController,
                itemCount: _selectedMedia.length,
                onPageChanged: (value) {
                  setState(() => _previewIndex = value);
                },
                itemBuilder: (context, index) {
                  final item = _selectedMedia[index];
                  final selectedCover = _selectedVideoCover[item.file.path];
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      if (item.type == PostMediaType.image)
                        Image.file(item.file,
                            fit: BoxFit.cover, width: double.infinity)
                      else if (selectedCover != null)
                        Image.memory(selectedCover,
                            fit: BoxFit.cover, width: double.infinity)
                      else
                        Container(
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              colors: [Color(0xFF0F1724), Color(0xFF23344D)],
                            ),
                          ),
                          child: const Center(
                            child: Icon(
                              Icons.play_circle_fill,
                              size: 72,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      Positioned(
                        top: 12,
                        left: 12,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.42),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            item.type == PostMediaType.video
                                ? 'Video clip'
                                : 'Photo',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      if (item.type == PostMediaType.video)
                        Positioned(
                          top: 12,
                          right: 12,
                          child: _previewAction(
                            icon: Icons.image_search_rounded,
                            onTap: () => _pickVideoCover(item),
                          ),
                        ),
                      if (_contentController.text.trim().isNotEmpty)
                        Positioned(
                          left: 12,
                          right: 12,
                          bottom: 62,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.black.withValues(alpha: 0.0),
                                  Colors.black.withValues(alpha: 0.58),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Text(
                              _contentController.text.trim(),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                height: 1.25,
                              ),
                            ),
                          ),
                        ),
                      Positioned(
                        left: 12,
                        right: 12,
                        bottom: 12,
                        child: Row(
                          children: [
                            _previewAction(
                              icon: Icons.chevron_left,
                              onTap: _previewIndex > 0
                                  ? () => _moveMedia(
                                      _previewIndex, _previewIndex - 1)
                                  : null,
                            ),
                            const SizedBox(width: 8),
                            _previewAction(
                              icon: Icons.chevron_right,
                              onTap: _previewIndex < _selectedMedia.length - 1
                                  ? () => _moveMedia(
                                      _previewIndex, _previewIndex + 1)
                                  : null,
                            ),
                            const Spacer(),
                            _previewAction(
                              icon: Icons.delete_outline_rounded,
                              onTap: () => _removeMediaAt(_previewIndex),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Swipe preview, tap a thumbnail, or use arrows to reorder.',
                  style: TextStyle(color: AppColors.grey, fontSize: 12),
                ),
              ),
              TextButton.icon(
                onPressed: _selectedMedia.isEmpty
                    ? null
                    : () {
                        setState(() {
                          _selectedMedia.clear();
                          _previewIndex = 0;
                        });
                      },
                icon: const Icon(Icons.clear_all_rounded, size: 18),
                label: const Text('Clear all'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 84,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _selectedMedia.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final item = _selectedMedia[index];
                final active = index == _previewIndex;
                return DragTarget<int>(
                  onWillAcceptWithDetails: (details) => details.data != index,
                  onAcceptWithDetails: (details) {
                    _moveMedia(details.data, index);
                  },
                  builder: (context, candidateData, rejectedData) {
                    final isTargeted = candidateData.isNotEmpty;
                    final thumb = SizedBox(
                      width: 82,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: isTargeted
                                      ? AppColors.primary
                                      : active
                                          ? AppColors.primary
                                          : Colors.transparent,
                                  width: isTargeted ? 3 : 2,
                                ),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: item.type == PostMediaType.image
                                    ? Image.file(item.file, fit: BoxFit.cover)
                                    : Container(
                                        decoration: const BoxDecoration(
                                          gradient: LinearGradient(
                                            colors: [
                                              Color(0xFF0F1724),
                                              Color(0xFF23344D)
                                            ],
                                          ),
                                        ),
                                        child: const Icon(
                                          Icons.play_circle_fill,
                                          color: Colors.white,
                                        ),
                                      ),
                              ),
                            ),
                          ),
                          Positioned(
                            top: 6,
                            right: 6,
                            child: Material(
                              color: Colors.black.withValues(alpha: 0.42),
                              borderRadius: BorderRadius.circular(999),
                              child: InkWell(
                                onTap: () => _removeMediaAt(index),
                                borderRadius: BorderRadius.circular(999),
                                child: const Padding(
                                  padding: EdgeInsets.all(4),
                                  child: Icon(Icons.close,
                                      size: 14, color: Colors.white),
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            left: 6,
                            bottom: 6,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 3),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.42),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                '${index + 1}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                    return LongPressDraggable<int>(
                      data: index,
                      feedback: Material(
                        color: Colors.transparent,
                        child: SizedBox(
                            width: 88,
                            child: Opacity(opacity: 0.9, child: thumb)),
                      ),
                      childWhenDragging: Opacity(opacity: 0.28, child: thumb),
                      child: GestureDetector(
                        onTap: () => _jumpToPreview(index),
                        child: thumb,
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLocationNote() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Row(
        children: [
          Icon(Icons.place_outlined, color: AppColors.primary),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Profile posts stay personal. If you post as a page, we attach that page location automatically.',
              style: TextStyle(color: AppColors.grey),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewCard() {
    if (_contentController.text.isEmpty && _selectedMedia.isEmpty) {
      return const SizedBox.shrink();
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFF151A24)
            : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Theme.of(context).brightness == Brightness.dark
              ? Colors.white10
              : Colors.black12,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Preview',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
          ),
          const Divider(),
          Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: AppColors.primary.withValues(alpha: 0.16),
                child: Icon(
                  _postAsProfile
                      ? Icons.person_rounded
                      : Icons.campaign_rounded,
                  color: AppColors.primary,
                  size: 18,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _postAsProfile ? 'Your profile post' : 'Page post',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      _postingIdentityLabel,
                      style:
                          const TextStyle(color: AppColors.grey, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_contentController.text.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest
                    .withValues(alpha: 0.32),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                _contentController.text,
                style: const TextStyle(height: 1.35),
              ),
            ),
          ],
          if (_selectedMedia.isNotEmpty) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: SizedBox(
                height: 220,
                width: double.infinity,
                child: _selectedMedia.first.type == PostMediaType.image
                    ? Image.file(_selectedMedia.first.file, fit: BoxFit.cover)
                    : (_selectedVideoCover[_selectedMedia.first.file.path] !=
                                null &&
                            _selectedVideoCover[_selectedMedia.first.file.path]!
                                .isNotEmpty
                        ? Stack(
                            fit: StackFit.expand,
                            children: [
                              Image.memory(
                                _selectedVideoCover[
                                    _selectedMedia.first.file.path]!,
                                fit: BoxFit.cover,
                              ),
                              const Center(
                                child: Icon(
                                  Icons.play_circle_fill_rounded,
                                  size: 66,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          )
                        : Container(
                            decoration: const BoxDecoration(
                              gradient: LinearGradient(
                                colors: [Color(0xFF0F1724), Color(0xFF23344D)],
                              ),
                            ),
                            child: const Center(
                              child: Icon(
                                Icons.play_circle_fill_rounded,
                                size: 66,
                                color: Colors.white,
                              ),
                            ),
                          )),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.collections_rounded,
                    size: 16, color: AppColors.grey),
                const SizedBox(width: 6),
                Text(
                  '${_selectedMedia.length} media item${_selectedMedia.length == 1 ? '' : 's'} selected',
                  style: const TextStyle(
                    color: AppColors.grey,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ComposerBadge extends StatelessWidget {
  const _ComposerBadge({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.26),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: AppColors.primary),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
