import glob
import re

M = 'android/app/src/main/AndroidManifest.xml'

PERMS = '''<!-- castplayer-proxy -->
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK"/>
<uses-permission android:name="android.permission.WAKE_LOCK"/>
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
'''

SERVICE = '''<service android:name=".ProxyService" android:exported="false" android:foregroundServiceType="mediaPlayback"/>
'''

FILTERS = '''
<!-- castplayer-intent -->
<intent-filter>
  <action android:name="android.intent.action.VIEW"/>
  <category android:name="android.intent.category.DEFAULT"/>
  <category android:name="android.intent.category.BROWSABLE"/>
  <data android:scheme="http"/>
  <data android:scheme="https"/>
  <data android:mimeType="video/*"/>
  <data android:mimeType="application/x-mpegURL"/>
  <data android:mimeType="application/vnd.apple.mpegurl"/>
  <data android:mimeType="application/dash+xml"/>
</intent-filter>
<intent-filter>
  <action android:name="android.intent.action.SEND"/>
  <category android:name="android.intent.category.DEFAULT"/>
  <data android:mimeType="text/plain"/>
</intent-filter>
'''

MAIN_KT = r'''package PKG

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "castplayer/intent")
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitial" -> {
                    result.success(extract(intent))
                    setIntent(Intent(Intent.ACTION_MAIN))
                }
                "startProxy" -> {
                    if (Build.VERSION.SDK_INT >= 33) {
                        requestPermissions(arrayOf("android.permission.POST_NOTIFICATIONS"), 1)
                    }
                    val i = Intent(this, ProxyService::class.java)
                    if (Build.VERSION.SDK_INT >= 26) startForegroundService(i) else startService(i)
                    result.success(true)
                }
                "stopProxy" -> {
                    stopService(Intent(this, ProxyService::class.java))
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val data = extract(intent)
        if (data != null) channel?.invokeMethod("onUrl", data)
    }

    private fun extract(i: Intent?): Map<String, String?>? {
        if (i == null) return null
        val url: String? = when (i.action) {
            Intent.ACTION_VIEW -> i.dataString
            Intent.ACTION_SEND -> {
                val t = i.getStringExtra(Intent.EXTRA_TEXT)
                if (t == null) null else Regex("https?://\\S+").find(t)?.value
            }
            else -> null
        }
        if (url == null) return null
        return mapOf("url" to url, "title" to i.getStringExtra("title"))
    }
}
'''

SERVICE_KT = r'''package PKG

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

class ProxyService : Service() {
    private var wake: PowerManager.WakeLock? = null
    private var wifi: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val chId = "castplayer_proxy"
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                NotificationChannel(chId, "CastPlayer", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, chId)
        } else {
            Notification.Builder(this)
        }
        builder.setContentTitle("CastPlayer")
            .setContentText("Streaming to TV")
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setOngoing(true)
        val notif = builder.build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(1, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(1, notif)
        }
        if (wake == null) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wake = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "castplayer:proxy")
            wake?.acquire(6 * 60 * 60 * 1000L)
        }
        if (wifi == null) {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            wifi = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "castplayer:proxy")
            wifi?.acquire()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        wake?.let { if (it.isHeld) it.release() }
        wifi?.let { if (it.isHeld) it.release() }
        wake = null
        wifi = null
        super.onDestroy()
    }
}
'''

s = open(M, encoding='utf-8').read()
if 'castplayer-intent' not in s:
    assert '</activity>' in s, 'no </activity> in manifest'
    s = s.replace('</activity>', FILTERS + '</activity>', 1)
if 'castplayer-proxy' not in s:
    assert '<application' in s and '</application>' in s, 'no application tag'
    s = s.replace('<application', PERMS + '<application', 1)
    s = s.replace('</application>', SERVICE + '</application>', 1)
open(M, 'w', encoding='utf-8').write(s)

files = glob.glob('android/app/src/main/kotlin/**/MainActivity.kt', recursive=True)
assert files, 'MainActivity.kt not found'
kt = files[0]
old = open(kt, encoding='utf-8').read()
pkg = re.search(r'^package\s+(\S+)', old, re.M).group(1)
open(kt, 'w', encoding='utf-8').write(MAIN_KT.replace('PKG', pkg))
svc = kt.replace('MainActivity.kt', 'ProxyService.kt')
open(svc, 'w', encoding='utf-8').write(SERVICE_KT.replace('PKG', pkg))
print('patched', kt, svc, pkg)
