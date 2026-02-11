import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
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
    required String businessId,
    String? imageUrl,
    String? videoUrl,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('User not authenticated');

    final userDoc = await _firestore.collection('users').doc(user.uid).get();
    final userType = userDoc.data()?['userType'];
    if (userType != 'business') {
      throw Exception('Only business accounts can create posts');
    }

    // Get business info
    final businessSnap =
        await _firestore.collection('businesses').doc(businessId).get();
    if (!businessSnap.exists) {
      throw Exception('Business not found');
    }
    final business = businessSnap.data() as Map<String, dynamic>;
    if (business['ownerId'] != user.uid) {
      throw Exception('Not authorized for this business');
    }
    final businessName = business['name'] ?? 'Unknown Business';
    final businessImageUrl = business['imageUrl'];
    final googleMapsLink = business['googleMapsLink'];

    final postRef = _firestore.collection('posts').doc();
    final post = Post(
      id: postRef.id,
      ownerId: user.uid,
      businessId: businessId,
      businessName: businessName,
      businessImageUrl: businessImageUrl,
      content: content,
      imageUrl: imageUrl,
      videoUrl: videoUrl,
      googleMapsLink: googleMapsLink,
      likes: [],
      comments: [],
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    await postRef.set(post.toFirestore());
    return postRef.id;
  }

  // Like/Unlike a post
  Future<void> toggleLike(String postId) async {
    final user = _auth.currentUser;
    if (user == null) return;

    final postRef = _firestore.collection('posts').doc(postId);
    final postDoc = await postRef.get();

    if (!postDoc.exists) return;

    final post = Post.fromFirestore(postDoc);
    final likes = List<String>.from(post.likes);

    bool addedLike = false;
    if (likes.contains(user.uid)) {
      likes.remove(user.uid);
    } else {
      likes.add(user.uid);
      addedLike = true;
    }

    await postRef.update({
      'likes': likes,
      'updatedAt': Timestamp.now(),
    });

    if (addedLike && post.ownerId != user.uid) {
      final profile = await _currentUserProfile();
      await _firestore.collection('notifications').add({
        'toUserId': post.ownerId,
        'fromUserId': user.uid,
        'fromUserName': profile['name'] ?? 'User',
        'fromUserImageUrl': profile['imageUrl'],
        'postId': post.id,
        'type': 'like',
        'createdAt': FieldValue.serverTimestamp(),
        'readAt': null,
        'hidden': false,
      });
    }
  }

  // Add comment to post
  Future<void> addComment(String postId, String content) async {
    final user = _auth.currentUser;
    if (user == null) return;

    // Get user name
    final userDoc = await _firestore.collection('users').doc(user.uid).get();
    final userName = userDoc.data()?['name'] ?? 'Anonymous';

    final comment = Comment(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      userId: user.uid,
      userName: userName,
      content: content,
      createdAt: DateTime.now(),
    );

    final postRef = _firestore.collection('posts').doc(postId);
    final postDoc = await postRef.get();

    if (!postDoc.exists) return;

    final post = Post.fromFirestore(postDoc);
    final comments = List<Comment>.from(post.comments);
    comments.add(comment);

    await postRef.update({
      'comments': comments.map((c) => c.toMap()).toList(),
      'updatedAt': Timestamp.now(),
    });

    if (post.ownerId != user.uid) {
      final profile = await _currentUserProfile();
      await _firestore.collection('notifications').add({
        'toUserId': post.ownerId,
        'fromUserId': user.uid,
        'fromUserName': profile['name'] ?? 'User',
        'fromUserImageUrl': profile['imageUrl'],
        'postId': post.id,
        'type': 'comment',
        'createdAt': FieldValue.serverTimestamp(),
        'readAt': null,
        'hidden': false,
      });
    }
  }

  // Delete post (only by business owner)
  Future<void> deletePost(String postId) async {
    final user = _auth.currentUser;
    if (user == null) return;

    final postDoc = await _firestore.collection('posts').doc(postId).get();
    if (!postDoc.exists) return;

    final post = Post.fromFirestore(postDoc);

    // Check if user owns the business
    final businessDoc = await _firestore.collection('businesses').doc(post.businessId).get();
    if (businessDoc.data()?['ownerId'] != user.uid) return;

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
