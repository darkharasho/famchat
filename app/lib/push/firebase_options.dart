// Placeholder until Firebase is set up: `scripts/setup-firebase.sh` runs `flutterfire configure`,
// which overwrites this file with the real options (they identify the Firebase project and aren't
// secret). While every platform throws here, push stays off and the app runs without Firebase.
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform =>
      throw UnsupportedError('Firebase is not configured; run scripts/setup-firebase.sh');
}
