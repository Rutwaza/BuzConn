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
  final List<PostMedia> media;
  final String? googleMapsLink;
  final int viewCount;
  final int playCount;

  /// Legacy lists (before Phase 2). New posts keep them empty; use
  /// [likeCount], [commentCount] and LikeStore instead.
  final List<String> likes;
  final List<Comment> comments;

  /// Kept up to date by Cloud Functions (functions/social.js).
  final int likeCount;
  final int commentCount;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// A product from the page's shop tagged in this post ("Buy · 5,000 RWF").
  /// A copy of name/price/photo is kept so the feed needs no extra read.
  final ProductTag? product;

  Post({
    required this.id,
    required this.ownerId,
    required this.businessId,
    required this.businessName,
    this.businessImageUrl,
    required this.content,
    this.imageUrl,
    this.videoUrl,
    required this.media,
    this.googleMapsLink,
    this.viewCount = 0,
    this.playCount = 0,
    this.likes = const [],
    this.comments = const [],
    int? likeCount,
    int? commentCount,
    required this.createdAt,
    required this.updatedAt,
    this.product,
  })  : likeCount = likeCount ?? likes.length,
        commentCount = commentCount ?? comments.length;

  Post copyWith({
    int? likeCount,
    int? commentCount,
    int? viewCount,
    int? playCount,
    DateTime? updatedAt,
  }) {
    return Post(
      id: id,
      ownerId: ownerId,
      businessId: businessId,
      businessName: businessName,
      businessImageUrl: businessImageUrl,
      content: content,
      imageUrl: imageUrl,
      videoUrl: videoUrl,
      media: media,
      googleMapsLink: googleMapsLink,
      viewCount: viewCount ?? this.viewCount,
      playCount: playCount ?? this.playCount,
      likes: likes,
      comments: comments,
      likeCount: likeCount ?? this.likeCount,
      commentCount: commentCount ?? this.commentCount,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      product: product,
    );
  }

  factory Post.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final imageUrl = _nullableStringFromDynamic(data['imageUrl']);
    final videoUrl = _nullableStringFromDynamic(data['videoUrl']);
    final media = _mediaListFromDynamic(data['media']);
    if (media.isEmpty) {
      if (imageUrl != null) {
        media.add(PostMedia(type: PostMediaType.image, url: imageUrl));
      }
      if (videoUrl != null) {
        media.add(PostMedia(type: PostMediaType.video, url: videoUrl));
      }
    }
    return Post(
      id: doc.id,
      ownerId: _stringFromDynamic(data['ownerId']),
      businessId: _stringFromDynamic(data['businessId']),
      businessName: _stringFromDynamic(data['businessName']).isNotEmpty
          ? _stringFromDynamic(data['businessName'])
          : 'Unknown Business',
      businessImageUrl: _nullableStringFromDynamic(data['businessImageUrl']),
      content: _stringFromDynamic(data['content']),
      imageUrl: imageUrl,
      videoUrl: videoUrl,
      media: media,
      googleMapsLink: _nullableStringFromDynamic(data['googleMapsLink']),
      viewCount: _intFromDynamic(data['viewCount']),
      playCount: _intFromDynamic(data['playCount']),
      likes: _stringListFromDynamic(data['likes']),
      comments: (data['comments'] is List)
          ? (data['comments'] as List<dynamic>)
              .map((comment) => Comment.fromMap(comment))
              .toList()
          : [],
      likeCount:
          data['likeCount'] == null ? null : _intFromDynamic(data['likeCount']),
      commentCount: data['commentCount'] == null
          ? null
          : _intFromDynamic(data['commentCount']),
      createdAt: _parseTimestamp(data['createdAt']),
      updatedAt: _parseTimestamp(data['updatedAt']),
      product: ProductTag.fromMap(data['product']),
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
      'media': media.map((m) => m.toMap()).toList(),
      'googleMapsLink': googleMapsLink,
      'viewCount': viewCount,
      'playCount': playCount,
      'likeCount': 0,
      'commentCount': 0,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
      if (product != null) 'product': product!.toMap(),
    };
  }
}

class Comment {
  final String id;
  final String userId;
  final String userName;
  final String content;
  final DateTime createdAt;
  final List<String> likes;
  final String? replyToUserId;
  final String? replyToUserName;
  final String? replyToCommentId;

  Comment({
    required this.id,
    required this.userId,
    required this.userName,
    required this.content,
    required this.createdAt,
    this.likes = const [],
    this.replyToUserId,
    this.replyToUserName,
    this.replyToCommentId,
  });

  factory Comment.fromMap(Map<String, dynamic> map) {
    return Comment(
      id: _stringFromDynamic(map['id']),
      userId: _stringFromDynamic(map['userId']),
      userName: _stringFromDynamic(map['userName']),
      content: _stringFromDynamic(map['content']),
      createdAt: _parseTimestamp(map['createdAt']),
      likes: _stringListFromDynamic(map['likes']),
      replyToUserId: _nullableStringFromDynamic(map['replyToUserId']),
      replyToUserName: _nullableStringFromDynamic(map['replyToUserName']),
      replyToCommentId: _nullableStringFromDynamic(map['replyToCommentId']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'userId': userId,
      'userName': userName,
      'content': content,
      'createdAt': Timestamp.fromDate(createdAt),
      'likes': likes,
      'replyToUserId': replyToUserId,
      'replyToUserName': replyToUserName,
      'replyToCommentId': replyToCommentId,
    };
  }
}

enum PostMediaType { image, video }

class PostMedia {
  final PostMediaType type;
  final String url;
  final String? thumbnailUrl;

  const PostMedia({
    required this.type,
    required this.url,
    this.thumbnailUrl,
  });

  bool get isVideo => type == PostMediaType.video;

  factory PostMedia.fromMap(Map<String, dynamic> map) {
    final typeValue = _stringFromDynamic(map['type']).toLowerCase();
    return PostMedia(
      type: typeValue == 'video' ? PostMediaType.video : PostMediaType.image,
      url: _stringFromDynamic(map['url']),
      thumbnailUrl: _nullableStringFromDynamic(map['thumbnailUrl']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'type': type == PostMediaType.video ? 'video' : 'image',
      'url': url,
      'thumbnailUrl': thumbnailUrl,
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

int _intFromDynamic(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

List<PostMedia> _mediaListFromDynamic(dynamic value) {
  if (value is Iterable) {
    final items = <PostMedia>[];
    for (final raw in value) {
      if (raw is Map<String, dynamic>) {
        final media = PostMedia.fromMap(raw);
        if (media.url.isNotEmpty) {
          items.add(media);
        }
      } else if (raw is Map) {
        final media = PostMedia.fromMap(
          raw.map((key, value) => MapEntry('$key', value)),
        );
        if (media.url.isNotEmpty) {
          items.add(media);
        }
      }
    }
    return items;
  }
  return [];
}

/// The shop product shown on a post.
class ProductTag {
  const ProductTag({
    required this.productId,
    required this.name,
    required this.price,
    this.imageUrl,
  });

  final String productId;
  final String name;
  final int price;
  final String? imageUrl;

  static ProductTag? fromMap(dynamic raw) {
    if (raw is! Map) return null;
    final id = (raw['productId'] ?? '').toString();
    if (id.isEmpty) return null;
    return ProductTag(
      productId: id,
      name: (raw['name'] ?? '').toString(),
      price: (raw['price'] as num?)?.round() ?? 0,
      imageUrl: raw['imageUrl'] as String?,
    );
  }

  Map<String, dynamic> toMap() => {
        'productId': productId,
        'name': name,
        'price': price,
        'imageUrl': imageUrl,
      };
}
