import glob
import re

M = 'android/app/src/main/AndroidManifest.xml'

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

KOTLIN = r'''package PKG

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "castplayer/intent")
        channel?.setMethodCallHandler { call, result ->
            if (call.method == "getInitial") {
                result.success(extract(intent))
                setIntent(Intent(Intent.ACTION_MAIN))
            } else {
                result.notImplemented()
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

s = open(M, encoding='utf-8').read()
if 'castplayer-intent' not in s:
    assert '</activity>' in s, 'no </activity> in manifest'
    s = s.replace('</activity>', FILTERS + '</activity>', 1)
    open(M, 'w', encoding='utf-8').write(s)

files = glob.glob('android/app/src/main/kotlin/**/MainActivity.kt', recursive=True)
assert files, 'MainActivity.kt not found'
kt = files[0]
old = open(kt, encoding='utf-8').read()
pkg = re.search(r'^package\s+(\S+)', old, re.M).group(1)
open(kt, 'w', encoding='utf-8').write(KOTLIN.replace('PKG', pkg))
print('patched', kt, pkg)
