import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';

import '../../firebase_options.dart';

class FirebaseService {
  static FirebaseService? _instance;
  static FirebaseService get instance => _instance ??= FirebaseService._();
  
  late FirebaseApp app;
  late FirebaseAuth auth;
  late FirebaseFirestore firestore;
  late FirebaseStorage storage;

  FirebaseService._();

  Future<void> initialize() async {
    app = await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    auth = FirebaseAuth.instance;
    firestore = FirebaseFirestore.instance;
    storage = FirebaseStorage.instance;
    
    // Privacy-first default: keep Firestore in memory so sensitive chat docs
    // are not intentionally persisted in the local offline cache.
    try {
      firestore.settings = const Settings(persistenceEnabled: false);
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
