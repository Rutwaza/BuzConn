import 'package:flutter/material.dart';
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
import '../../../core/services/supabase_storage_service.dart';

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
  final PageController _previewController = PageController();
  int _previewIndex = 0;
  bool _isLoading = false;
  bool _isBusinessUser = false;
  bool _isCheckingUserType = true;
  bool _showSuccess = false;
  bool _isLoadingBusinesses = false;
  List<Map<String, dynamic>> _businesses = [];
  String? _selectedBusinessId;

  @override
  void dispose() {
    _contentController.dispose();
    _previewController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadUserType();
    _loadBusinesses();
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
      final userDoc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
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
                'name': (doc.data())['name'] ?? 'Unnamed Business',
              })
          .toList();
      if (_businesses.isNotEmpty) {
        _selectedBusinessId = _businesses.first['id'] as String;
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
      final picked = result.files
          .where((file) => file.path != null)
          .map((file) => _LocalMedia(
                file: File(file.path!),
                type: PostMediaType.video,
              ))
          .toList();
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

  Future<String?> _uploadImage(File imageFile) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      final bytes = await imageFile.readAsBytes();
      final path = '${user?.uid ?? 'anon'}/${DateTime.now().millisecondsSinceEpoch}.jpg';
      return await SupabaseStorageService.instance.uploadImage(
        bucket: 'post-images',
        path: path,
        bytes: bytes,
      );
    } catch (e) {
      debugPrint('Error uploading image: $e');
      return null;
    }
  }

  Future<String?> _uploadVideo(File videoFile) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      final bytes = await videoFile.readAsBytes();
      final path = '${user?.uid ?? 'anon'}/${DateTime.now().millisecondsSinceEpoch}.mp4';
      return await SupabaseStorageService.instance.uploadVideo(
        bucket: 'post-videos',
        path: path,
        bytes: bytes,
      );
    } catch (e) {
      debugPrint('Error uploading video: $e');
      return null;
    }
  }

  Future<void> _createPost() async {
    if (!_isBusinessUser) return;
    if (_selectedBusinessId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a business.')),
      );
      return;
    }
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
    });

    try {
      final uploadedMedia = <PostMedia>[];
      for (final item in _selectedMedia) {
        final url = item.type == PostMediaType.video
            ? await _uploadVideo(item.file)
            : await _uploadImage(item.file);
        if (url == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                item.type == PostMediaType.video
                    ? 'Video upload failed.'
                    : 'Image upload failed.',
              ),
            ),
          );
          return;
        }
        uploadedMedia.add(PostMedia(type: item.type, url: url));
      }

      await _postsRepository.createPost(
        content: _contentController.text.trim(),
        businessId: _selectedBusinessId!,
        media: uploadedMedia,
      );

      if (mounted) {
        _triggerSuccessAnimation();
      }

      // Clear form and go back
      _contentController.clear();
      setState(() {
        _selectedMedia.clear();
        _previewIndex = 0;
      });

      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to create post: ${e.toString()}')),
      );
    } finally {
      setState(() {
        _isLoading = false;
      });
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

  @override
  Widget build(BuildContext context) {
    if (_isCheckingUserType) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (!_isBusinessUser) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Create Post'),
        ),
        body: const Center(
          child: Text('Only business accounts can create posts.'),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Create Post'),
        actions: [
          TextButton(
            onPressed: _isLoading ? null : _createPost,
            child: Text(
              'Post',
              style: TextStyle(
                color: _isLoading ? AppColors.grey : AppColors.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_isLoadingBusinesses)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: LinearProgressIndicator(),
                    ),
                  if (_businesses.isEmpty && !_isLoadingBusinesses)
                    const Card(
                      color: AppColors.lightGrey,
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: Text('You have no active businesses to post from.'),
                      ),
                    ),
                  if (_businesses.isNotEmpty) ...[
                    const Text(
                      'Posting as',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: _selectedBusinessId,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                      items: _businesses
                          .map(
                            (b) => DropdownMenuItem<String>(
                              value: b['id'] as String,
                              child: Text(b['name'] as String),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        setState(() {
                          _selectedBusinessId = value;
                        });
                      },
                    ),
                    const SizedBox(height: 16),
                  ],
                  // Content field
                  AppTextField(
                    controller: _contentController,
                    label: 'What\'s happening?',
                    hintText: 'Share something with your customers...',
                    maxLines: 3,
                    maxLength: 300,
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Please write something';
                      }
                      return null;
                    },
                  ),

                  const SizedBox(height: 24),

                  // Media actions
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _pickImages,
                          icon: const Icon(Icons.image),
                          label: const Text('Photos'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _pickVideos,
                          icon: const Icon(Icons.videocam),
                          label: const Text('Videos'),
                        ),
                      ),
                    ],
                  ),
                  if (_selectedMedia.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 220,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: PageView.builder(
                          controller: _previewController,
                          itemCount: _selectedMedia.length,
                          onPageChanged: (value) {
                            setState(() => _previewIndex = value);
                          },
                          itemBuilder: (context, index) {
                            final item = _selectedMedia[index];
                            if (item.type == PostMediaType.image) {
                              return Image.file(
                                item.file,
                                fit: BoxFit.cover,
                                width: double.infinity,
                              );
                            }
                            return Container(
                              color: AppColors.lightGrey,
                              child: const Center(
                                child: Icon(Icons.play_circle_fill, size: 48),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text(
                          'Media ${_previewIndex + 1}/${_selectedMedia.length}',
                          style: const TextStyle(color: AppColors.grey),
                        ),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: () {
                            if (_selectedMedia.isEmpty) return;
                            setState(() {
                              _selectedMedia.removeAt(_previewIndex);
                              if (_previewIndex >= _selectedMedia.length) {
                                _previewIndex =
                                    _selectedMedia.isEmpty ? 0 : _selectedMedia.length - 1;
                              }
                            });
                            if (_selectedMedia.isNotEmpty) {
                              _previewController.jumpToPage(_previewIndex);
                            }
                          },
                          icon: const Icon(Icons.close),
                          label: const Text('Remove'),
                        ),
                      ],
                    ),
                  ],

                  const SizedBox(height: 24),

                  const Text(
                    'Location will be shared from your business profile.',
                    style: TextStyle(color: AppColors.grey),
                  ),

                  const SizedBox(height: 24),

                  // Preview
                  if (_contentController.text.isNotEmpty ||
                      _selectedMedia.isNotEmpty)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Preview',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 18,
                              ),
                            ),
                            const Divider(),
                            Text(_contentController.text),
                            if (_selectedMedia.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: AppColors.lightGrey,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.collections),
                                    const SizedBox(width: 8),
                                    Text(
                                      '${_selectedMedia.length} media item${_selectedMedia.length == 1 ? '' : 's'} selected',
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),

                  const SizedBox(height: 32),

                  // Create post button
                  AppButton(
                    text: 'Create Post',
                    onPressed: _createPost,
                    isLoading: _isLoading,
                  ),
                ],
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
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
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
                          Icon(Icons.check_circle, color: Colors.green, size: 48),
                          SizedBox(height: 8),
                          Text(
                            'Posted!',
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
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
      ),
    );
  }
}
