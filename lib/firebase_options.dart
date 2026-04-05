import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

/// Default [FirebaseOptions] for use with your Firebase apps.
///
/// Example:
/// ```dart
/// import 'firebase_options.dart';
/// // ...
/// await Firebase.initializeApp(
///   options: DefaultFirebaseOptions.currentPlatform,
/// );
/// ```
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        throw UnsupportedError(
          'DefaultFirebaseOptions have not been configured for macos - '
          'you can reconfigure this by running the FlutterFire CLI again.',
        );
      case TargetPlatform.windows:
        return windows;
      case TargetPlatform.linux:
        throw UnsupportedError(
          'DefaultFirebaseOptions have not been configured for linux - '
          'you can reconfigure this by running the FlutterFire CLI again.',
        );
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyDLTVlu8D53IRz2FIMUh6RkN3XbbQN-xuE',
    appId: '1:540337503772:web:999aecc7575dc206d769d9',
    messagingSenderId: '540337503772',
    projectId: 'bussinessfinder-327f5',
    authDomain: 'bussinessfinder-327f5.firebaseapp.com',
    storageBucket: 'bussinessfinder-327f5.firebasestorage.app',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyDLTVlu8D53IRz2FIMUh6RkN3XbbQN-xuE',
    appId: '1:540337503772:android:999aecc7575dc206d769d9',
    messagingSenderId: '540337503772',
    projectId: 'bussinessfinder-327f5',
    storageBucket: 'bussinessfinder-327f5.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyDLTVlu8D53IRz2FIMUh6RkN3XbbQN-xuE',
    appId: '1:540337503772:ios:999aecc7575dc206d769d9',
    messagingSenderId: '540337503772',
    projectId: 'bussinessfinder-327f5',
    storageBucket: 'bussinessfinder-327f5.firebasestorage.app',
  );

  static const FirebaseOptions windows = FirebaseOptions(
    apiKey: 'AIzaSyBMQmHm-I0xpceru34OeC7SWi1X03KsDVk',
    appId: '1:540337503772:web:e0a91fec12c4b1d4d769d9',
    messagingSenderId: '540337503772',
    projectId: 'bussinessfinder-327f5',
    authDomain: 'bussinessfinder-327f5.firebaseapp.com',
    storageBucket: 'bussinessfinder-327f5.firebasestorage.app',
    measurementId: 'G-2XTM398N6D',
  );

}