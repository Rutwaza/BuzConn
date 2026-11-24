import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../firebase_options.dart';

class FirebaseService {
  static FirebaseService? _instance;
  static FirebaseService get instance => _instance ??= FirebaseService._();
  
  late FirebaseApp app;
  late FirebaseAuth auth;
  late FirebaseFirestore firestore;

  FirebaseService._();

  Future<void> initialize() async {
    app = await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    auth = FirebaseAuth.instance;
    firestore = FirebaseFirestore.instance;
    
    // Phase 2: keep a local copy (offline cache). Chats and feeds open
    // instantly from the phone, messages written offline are sent later, and
    // we pay for far fewer reads. 40 MB keeps it small on cheap phones.
    // (Before, the cache was off, so every screen waited for the network.)
    try {
      firestore.settings = const Settings(
        persistenceEnabled: true,
        cacheSizeBytes: 40 * 1024 * 1024,
      );
    } catch (_) {
      // Ignore if settings were already locked by an earlier Firestore use.
    }
  }

  // Helper methods
  CollectionReference get usersCollection => firestore.collection('users');
  CollectionReference get businessesCollection => firestore.collection('businesses');
  CollectionReference get servicesCollection => firestore.collection('services');
  
  Future<String?> getCurrentUserId() async {
    return auth.currentUser?.uid;
  }

  Future<bool> isUserLoggedIn() async {
    return auth.currentUser != null;
  }
}
