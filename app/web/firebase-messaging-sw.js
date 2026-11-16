// FamChat web push. Firebase Messaging registers this worker (/firebase-messaging-sw.js) when the
// app asks for a token. Pushes carry a notification payload, which the Firebase SDK shows; a click
// opens webpush.fcm_options.link (https://famchat.dev/chats/<id>). The config lives in
// firebase-config.js, written by scripts/setup-firebase.sh; while it is null this worker does nothing.
importScripts('firebase-config.js');

if (self.famchatFirebaseConfig) {
  // Keep in step with the JS SDK version firebase_core_web loads (supportedFirebaseJsSdkVersion).
  importScripts(
    'https://www.gstatic.com/firebasejs/13.3.0/firebase-app-compat.js',
    'https://www.gstatic.com/firebasejs/13.3.0/firebase-messaging-compat.js',
  );
  firebase.initializeApp(self.famchatFirebaseConfig);
  firebase.messaging();
}
