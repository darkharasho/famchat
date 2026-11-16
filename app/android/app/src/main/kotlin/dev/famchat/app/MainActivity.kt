package dev.famchat.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The channel FCM pushes name (android.notification.channel_id = "messages", see
        // server/src/push/fcm.ts). Creating an existing channel again is a no-op.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel("messages", "Messages", NotificationManager.IMPORTANCE_HIGH)
            channel.description = "New messages from your family"
            getSystemService(NotificationManager::class.java)?.createNotificationChannel(channel)
        }
    }
}
