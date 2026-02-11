import 'package:cloud_firestore/cloud_firestore.dart';

class Post {
  final String id;
  final String ownerId;
  final String businessId;
  final String businessName;
  final String? businessImageUrl;
  final String content;
  final String? imageUrl;
  final String? videoUrl;
  final String? googleMapsLink;
  final List<String> likes;
  final List<Comment> comments;
  final DateTime createdAt;
  final DateTime updatedAt;

  Post({
    required this.id,
    required this.ownerId,
    required this.businessId,
    required this.businessName,
    this.businessImageUrl,
    required this.content,
    this.imageUrl,
    this.videoUrl,
    this.googleMapsLink,
    required this.likes,
    required this.comments,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Post.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return Post(
      id: doc.id,
      ownerId: _stringFromDynamic(data['ownerId']),
      businessId: _stringFromDynamic(data['businessId']),
      businessName: _stringFromDynamic(data['businessName']).isNotEmpty
          ? _stringFromDynamic(data['businessName'])
          : 'Unknown Business',
      businessImageUrl: _nullableStringFromDynamic(data['businessImageUrl']),
      content: _stringFromDynamic(data['content']),
      imageUrl: _nullableStringFromDynamic(data['imageUrl']),
      videoUrl: _nullableStringFromDynamic(data['videoUrl']),
      googleMapsLink: _nullableStringFromDynamic(data['googleMapsLink']),
      likes: _stringListFromDynamic(data['likes']),
      comments: (data['comments'] is List)
          ? (data['comments'] as List<dynamic>).map((comment) => Comment.fromMap(comment)).toList()
          : [],
      createdAt: _parseTimestamp(data['createdAt']),
      updatedAt: _parseTimestamp(data['updatedAt']),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'ownerId': ownerId,
      'businessId': businessId,
      'businessName': businessName,
      'businessImageUrl': businessImageUrl,
      'content': content,
      'imageUrl': imageUrl,
      'videoUrl': videoUrl,
      'googleMapsLink': googleMapsLink,
      'likes': likes,
      'comments': comments.map((comment) => comment.toMap()).toList(),
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
    };
  }
}

class Comment {
  final String id;
  final String userId;
  final String userName;
  final String content;
  final DateTime createdAt;

  Comment({
    required this.id,
    required this.userId,
    required this.userName,
    required this.content,
    required this.createdAt,
  });

  factory Comment.fromMap(Map<String, dynamic> map) {
    return Comment(
      id: _stringFromDynamic(map['id']),
      userId: _stringFromDynamic(map['userId']),
      userName: _stringFromDynamic(map['userName']),
      content: _stringFromDynamic(map['content']),
      createdAt: _parseTimestamp(map['createdAt']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'userId': userId,
      'userName': userName,
      'content': content,
      'createdAt': Timestamp.fromDate(createdAt),
    };
  }
}

// Helper method to safely parse timestamps from various formats
DateTime _parseTimestamp(dynamic timestamp) {
  if (timestamp is Timestamp) {
    return timestamp.toDate();
  } else if (timestamp is String) {
    // Try to parse as ISO 8601 string
    try {
      return DateTime.parse(timestamp);
    } catch (e) {
      // If parsing fails, return current time
      return DateTime.now();
    }
  } else if (timestamp is int) {
    // Handle milliseconds since epoch
    return DateTime.fromMillisecondsSinceEpoch(timestamp);
  } else {
    // Default fallback
    return DateTime.now();
  }
}

String _stringFromDynamic(dynamic value) {
  if (value is String) return value;
  if (value is DocumentReference) return value.id;
  return value?.toString() ?? '';
}

String? _nullableStringFromDynamic(dynamic value) {
  if (value == null) return null;
  final parsed = _stringFromDynamic(value);
  return parsed.isEmpty ? null : parsed;
}

List<String> _stringListFromDynamic(dynamic value) {
  if (value is Iterable) {
    return value.map(_stringFromDynamic).where((s) => s.isNotEmpty).toList();
  }
  return [];
}
