import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../features/posts/data/engagement_repository.dart';
import '../../data/models/post_model.dart';

class PostsRepository {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  Map<String, dynamic>? _currentUserCache;

  Future<Map<String, dynamic>> _currentUserProfile() async {
    if (_currentUserCache != null) return _currentUserCache!;
    final user = _auth.currentUser;
    if (user == null) return {};
    final doc = await _firestore.collection('users').doc(user.uid).get();
    _currentUserCache = doc.data() ?? {};
    return _currentUserCache!;
  }

  // Get all posts ordered by creation date
  Stream<List<Post>> getPosts() {
    return _firestore
        .collection('posts')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) =>
            snapshot.docs.map((doc) => Post.fromFirestore(doc)).toList());
  }

  // Get posts by business
  Stream<List<Post>> getPostsByBusiness(String businessId) {
    return _firestore
        .collection('posts')
        .where('businessId', isEqualTo: businessId)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) =>
            snapshot.docs.map((doc) => Post.fromFirestore(doc)).toList());
  }

  // Create a new post
  Future<String> createPost({
    required String content,
    String? businessId,
    List<PostMedia> media = const [],
    String? imageUrl,
    String? videoUrl,
    ProductTag? product,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('User not authenticated');

    final userProfile = await _currentUserProfile();
    String resolvedBusinessId = '';
    String displayName =
        (userProfile['name'] ?? user.displayName ?? 'User').toString();
    String? displayImageUrl =
        (userProfile['imageUrl'] ?? '').toString().trim().isEmpty
            ? null
            : (userProfile['imageUrl'] ?? '').toString().trim();
    String? googleMapsLink;

    if (businessId != null && businessId.trim().isNotEmpty) {
      final businessSnap = await _firestore
          .collection('businesses')
          .doc(businessId.trim())
          .get();
      if (!businessSnap.exists) {
        throw Exception('Business not found');
      }
      final business = businessSnap.data() as Map<String, dynamic>;
      if (business['ownerId'] != user.uid) {
        throw Exception('Not authorized for this business');
      }
      resolvedBusinessId = businessId.trim();
      displayName = (business['name'] ?? displayName).toString();
      final businessImage = (business['imageUrl'] ?? '').toString().trim();
      displayImageUrl = businessImage.isEmpty ? displayImageUrl : businessImage;
      googleMapsLink = (business['googleMapsLink'] ?? '').toString().trim();
      if (googleMapsLink.isEmpty) {
        googleMapsLink = null;
      }
    }

    final postRef = _firestore.collection('posts').doc();
    String? primaryImageUrl = imageUrl;
    String? primaryVideoUrl = videoUrl;
    if (primaryImageUrl == null || primaryVideoUrl == null) {
      for (final item in media) {
        if (primaryImageUrl == null && item.type == PostMediaType.image) {
          primaryImageUrl = item.url;
        }
        if (primaryVideoUrl == null && item.type == PostMediaType.video) {
          primaryVideoUrl = item.url;
        }
        if (primaryImageUrl != null && primaryVideoUrl != null) {
          break;
        }
      }
    }
    final post = Post(
      id: postRef.id,
      ownerId: user.uid,
      businessId: resolvedBusinessId,
      businessName: displayName,
      businessImageUrl: displayImageUrl,
      content: content,
      imageUrl: primaryImageUrl,
      videoUrl: primaryVideoUrl,
      media: media,
      googleMapsLink: googleMapsLink,
      viewCount: 0,
      playCount: 0,
      likes: [],
      comments: [],
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      // Only a page's own products can be tagged.
      product: resolvedBusinessId.isEmpty ? null : product,
    );

    await postRef.set(post.toFirestore());
    return postRef.id;
  }

  // Phase 2: likes and comments are their own documents. These methods keep
  // their old names so the screens did not need to change much.
  // See lib/features/posts/data/engagement_repository.dart.
  final CommentsRepository _comments = CommentsRepository();

  Future<void> toggleLike(String postId) async {
    if (_auth.currentUser == null) return;
    await LikeStore.instance.toggle(postId);
  }

  Stream<List<Comment>> watchComments(String postId) => _comments.watch(postId);

  Future<void> addComment(
    String postId,
    String content, {
    Comment? replyTo,
  }) =>
      _comments.add(postId, content, replyTo: replyTo);

  Future<void> updateComment({
    required String postId,
    required String commentId,
    required String newContent,
  }) =>
      _comments.edit(postId, commentId, newContent);

  Future<void> toggleCommentLike({
    required String postId,
    required String commentId,
  }) async {
    final ref = _firestore
        .collection('posts')
        .doc(postId)
        .collection('comments')
        .doc(commentId);
    final snap = await ref.get();
    if (!snap.exists) return;
    await _comments.toggleLike(
      postId,
      Comment.fromMap({...?snap.data(), 'id': snap.id}),
    );
  }

  Future<void> deleteComment({
    required String postId,
    required String commentId,
  }) =>
      _comments.delete(postId, commentId);

  // Delete post (only by business owner)
  Future<void> deletePost(String postId) async {
    final user = _auth.currentUser;
    if (user == null) return;

    final postDoc = await _firestore.collection('posts').doc(postId).get();
    if (!postDoc.exists) return;

    final post = Post.fromFirestore(postDoc);

    if (post.ownerId != user.uid) return;
    if (post.businessId.isNotEmpty) {
      final businessDoc =
          await _firestore.collection('businesses').doc(post.businessId).get();
      if (businessDoc.data()?['ownerId'] != user.uid) return;
    }

    await _firestore.collection('posts').doc(postId).delete();
  }

  // Update post content (only by business owner via rules)
  Future<void> updatePostContent({
    required String postId,
    required String content,
  }) async {
    await _firestore.collection('posts').doc(postId).update({
      'content': content,
      'updatedAt': Timestamp.now(),
    });
  }
}
