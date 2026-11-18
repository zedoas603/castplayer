import 'dart:async';
import 'dart:convert';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// AdGuard DNS filter: downloaded once, cached 3 days, used to block requests.
// ---------------------------------------------------------------------------
class AdGuard {
  static const _url =
      'https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt';
  static final Set<String> _block = {..._seed};
  static final Set<String> _allow = {};
  static int get total => _block.length;

  static File get _cache => File('${Directory.systemTemp.path}/adguard_filter.txt');

  static Future<void> init() async {
    try {
      final f = _cache;
      String? text;
      if (await f.exists() &&
          DateTime.now().difference(await f.lastModified()).inDays < 3) {
        text = await f.readAsString();
      } else {
        try {
          final r = await http.get(Uri.parse(_url)).timeout(const Duration(seconds: 25));
          if (r.statusCode == 200) {
            text = r.body;
            await f.writeAsString(text);
          }
        } catch (_) {}
        if (text == null && await f.exists()) text = await f.readAsString();
      }
      if (text != null) _parse(text);
    } catch (_) {}
  }

  static void _parse(String text) {
    for (final raw in text.split('\n')) {
      var l = raw.trim();
      if (l.isEmpty || l.startsWith('!') || l.startsWith('#')) continue;
      var allow = false;
      if (l.startsWith('@@')) {
        allow = true;
        l = l.substring(2);
      }
      if (!l.startsWith('||')) continue;
      l = l.substring(2);
      final e = l.indexOf('^');
      if (e <= 0) continue;
      final d = l.substring(0, e).toLowerCase();
      if (d.contains('/') || d.contains('*') || !d.contains('.')) continue;
      (allow ? _allow : _block).add(d);
    }
  }

  static bool isBlocked(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    if (host.isEmpty) return false;
    var d = host;
    while (true) {
      if (_allow.contains(d)) return false;
      final i = d.indexOf('.');
      if (i < 0) break;
      d = d.substring(i + 1);
    }
    d = host;
    while (true) {
      if (_block.contains(d)) return true;
      final i = d.indexOf('.');
      if (i < 0) return false;
      d = d.substring(i + 1);
    }
  }

  static const _seed = [
    'doubleclick.net', 'googlesyndication.com', 'googleadservices.com',
    'adservice.google.com', 'amazon-adsystem.com', 'adnxs.com', 'taboola.com',
    'outbrain.com', 'criteo.com', 'criteo.net', 'pubmatic.com',
    'rubiconproject.com', 'openx.net', 'adsrvr.org', 'casalemedia.com',
    'moatads.com', 'scorecardresearch.com', 'popads.net', 'popcash.net',
    'propellerads.com', 'propellerclick.com', 'exoclick.com', 'exosrv.com',
    'juicyads.com', 'trafficjunky.net', 'adsterra.com',
    'highperformanceformat.com', 'hilltopads.net', 'clickadu.com',
    'adcash.com', 'mgid.com', 'revcontent.com', 'onclickads.net', 'a-ads.com',
    'tsyndicate.com', 'ad-maven.com', 'admaven.com', 'yllix.com',
    'bidvertiser.com', 'adform.net', 'smartadserver.com', '33across.com',
    'realsrv.com', 'adskeeper.com', 'advertising.com', 'zedo.com',
  ];
}

// ---------------------------------------------------------------------------
// Scripts injected into every frame (including iframes)
// ---------------------------------------------------------------------------
const _sniffJs = r'''
(function(){
  if (window.__sn) return; window.__sn = 1;
  var MEDIA = /\.(m3u8|mpd|mp4|webm|mkv)(\?|#|$)|\.m3u8/i;
  function post(u){ try { window.flutter_inappwebview.callHandler('sniff', u); } catch(e) {} }
  function abs(u){ try { return new URL(u, location.href).href; } catch(e) { return ''; } }
  function send(u){ u = abs(String(u || '')); if (u && u.indexOf('blob:') !== 0 && MEDIA.test(u)) post(u); }
  function sendCT(u, ct){
    if (/mpegurl|video\//i.test(ct || '') || /dash\+xml/i.test(ct || '')) { u = abs(u); if (u) post(u); }
  }
  var xo = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function(m, u){
    var self = this, url = String(u);
    send(url);
    this.addEventListener('readystatechange', function(){
      if (self.readyState === 2) { try { sendCT(url, self.getResponseHeader('content-type')); } catch(e) {} }
    });
    return xo.apply(this, arguments);
  };
  var f = window.fetch;
  if (f) window.fetch = function(a){
    var url = typeof a === 'string' ? a : (a && a.url) || '';
    send(url);
    return f.apply(this, arguments).then(function(r){
      try { sendCT(url, r.headers.get('content-type')); } catch(e) {}
      return r;
    });
  };
  setInterval(function(){
    document.querySelectorAll('video,source').forEach(function(v){
      if (v.src) send(v.src);
      if (v.currentSrc) send(v.currentSrc);
    });
  }, 1500);
})();
''';

const _adJs = r'''
(function(){
  if (window.__ab) return; window.__ab = 1;
  function cnt(){ try { window.flutter_inappwebview.callHandler('adcount'); } catch(e) {} }
  window.open = function(){ cnt(); return null; };
  window.canRunAds = true;
  window.adsbygoogle = window.adsbygoogle || [];
  window.google_ad_status = 1;
  var st = document.createElement('style');
  st.textContent = 'ins.adsbygoogle,[id^="google_ads"],[id^="div-gpt-ad"],iframe[src*="doubleclick"]{display:none!important}';
  (document.head || document.documentElement).appendChild(st);
  var re = /ad ?block|ads? blocker|disable (your )?ad|مانع الإعلانات|مانع إعلانات|حاجب الإعلانات/i;
  setInterval(function(){
    if (!document.body) return;
    var removed = false;
    Array.prototype.forEach.call(document.body.children, function(e){
      var s = getComputedStyle(e);
      if ((s.position === 'fixed' || s.position === 'absolute') &&
          e.offsetWidth > innerWidth * 0.5 && e.offsetHeight > innerHeight * 0.3 &&
          re.test(e.innerText || '')) { e.remove(); removed = true; cnt(); }
    });
    if (removed) {
      document.body.style.setProperty('overflow', 'auto', 'important');
      document.documentElement.style.setProperty('overflow', 'auto', 'important');
    }
  }, 1000);
})();
''';

final _media = RegExp(r'\.(m3u8|mpd|mp4|webm|mkv)(\?|#|$)|\.m3u8', caseSensitive: false);
const _ua =
    'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

class _Meta {
  final String label;
  final int prio; // 0 master, 1 live, 2 vod, 3 unverified
  _Meta(this.label, this.prio);
}

final _adLike = RegExp(
    r'(^|[/._=?&-])(ads?|adv|adserver|advert\w*|vast|vpaid|preroll|midroll|postroll|banner|sponsor|imasdk|doubleclick|promo|tracking|pixel)([/._=?&-]|$)',
    caseSensitive: false);

class _Tab {
  final int id;
  final bool incognito;
  InAppWebViewController? c;
  String url;
  String title = '';
  final found = <String>[];
  final seen = <String>{};
  final meta = <String, _Meta>{};
  bool loaded = false;
  _Tab(this.id, this.incognito, this.url);
}

const _home = 'https://www.google.com';

class Browser extends StatefulWidget {
  final Map<String, String> t;
  final void Function(String url, String title) onCast;
  const Browser({super.key, required this.t, required this.onCast});
  @override
  State<Browser> createState() => _BrowserState();
}

class _BrowserState extends State<Browser> with WidgetsBindingObserver {
  final tabs = <_Tab>[];
  int cur = 0, _nid = 0, _lastIdx = 0;
  final tc = TextEditingController();
  bool adblock = true, ready = false, dirty = false;
  int blocked = 0;
  Timer? timer;

  bool get en => widget.t['title'] == 'CastPlayer';
  String _s(String ar, String e) => en ? e : ar;
  _Tab get tab => tabs[cur];
  bool get inc => tabs.isNotEmpty && tab.incognito;

  @override
  void initState() {
    super.initState();
    AdGuard.init();
    WidgetsBinding.instance.addObserver(this);
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      if (p.getBool('inc_active') == true) _wipeIncognito();
      setState(() {
        adblock = p.getBool('adblock') ?? true;
        final saved = p.getString('tabs');
        if (saved != null) {
          try {
            final m = jsonDecode(saved);
            for (final e in (m['tabs'] as List)) {
              final t = _Tab(_nid++, false, e['u'].toString());
              t.title = (e['t'] ?? '').toString();
              tabs.add(t);
            }
            if (tabs.isNotEmpty) {
              cur = ((m['cur'] ?? 0) as int).clamp(0, tabs.length - 1).toInt();
              _lastIdx = cur;
            }
          } catch (_) {
            tabs.clear();
          }
        }
        if (tabs.isEmpty) tabs.add(_Tab(_nid++, false, _home));
        tc.text = tab.url;
        ready = true;
      });
      p.setBool('in_browser', true);
    });
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (dirty && mounted) {
        dirty = false;
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
    _saveTabs();
    if (tabs.any((t) => t.incognito)) _wipeIncognito();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) _saveTabs();
  }

  /// Saves only normal (non-incognito) tabs, so the last page is restored next time.
  Future<void> _saveTabs() async {
    final normals = tabs.where((t) => !t.incognito).toList();
    if (normals.isEmpty) return;
    var idx = (tabs.isNotEmpty && cur < tabs.length && !tabs[cur].incognito)
        ? normals.indexOf(tabs[cur])
        : _lastIdx;
    if (idx < 0) idx = 0;
    _lastIdx = idx;
    final p = await SharedPreferences.getInstance();
    await p.setString(
        'tabs',
        jsonEncode({
          'cur': idx,
          'tabs': [
            for (final t in normals) {'u': t.url, 't': t.title}
          ],
        }));
  }

  /// Wipes cookies, site storage and cache left behind by incognito browsing.
  Future<void> _wipeIncognito() async {
    try {
      await CookieManager.instance().deleteAllCookies();
      await WebStorageManager.instance().deleteAllData();
      await InAppWebViewController.clearAllCache();
    } catch (_) {}
    try {
      (await SharedPreferences.getInstance()).setBool('inc_active', false);
    } catch (_) {}
  }

  List<UserScript> _scripts() => [
        UserScript(
            source: _sniffJs,
            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
            forMainFrameOnly: false),
        if (adblock)
          UserScript(
              source: _adJs,
              injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
              forMainFrameOnly: false),
      ];

  String _dur(double sec) {
    final m = sec ~/ 60, x = sec.toInt() % 60;
    final h = m ~/ 60;
    String two(int n) => n.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m % 60)}:${two(x)}' : '${two(m)}:${two(x)}';
  }

  /// Returns null when the link looks like an ad (short clip / tiny file / error page).
  Future<_Meta?> _probe(String u) async {
    final lu = u.toLowerCase();
    try {
      if (lu.contains('.m3u8')) {
        final r = await http
            .get(Uri.parse(u), headers: {'User-Agent': _ua})
            .timeout(const Duration(seconds: 6));
        if (r.statusCode != 200) return _Meta('', 3);
        final b = r.body;
        if (!b.contains('#EXTM3U')) return null;
        if (b.contains('#EXT-X-STREAM-INF')) {
          return _Meta(_s('جودات متعددة (الأفضل)', 'Multi-quality (best)'), 0);
        }
        var total = 0.0;
        for (final m in RegExp(r'#EXTINF:([\d.]+)').allMatches(b)) {
          total += double.tryParse(m.group(1)!) ?? 0;
        }
        if (!b.contains('#EXT-X-ENDLIST')) return _Meta(_s('بث مباشر', 'Live'), 1);
        if (total < 90) return null;
        return _Meta('${_s('فيديو', 'Video')} ${_dur(total)}', 2);
      }
      if (RegExp(r'\.(mp4|webm|mkv)').hasMatch(lu)) {
        final r = await http
            .head(Uri.parse(u), headers: {'User-Agent': _ua})
            .timeout(const Duration(seconds: 6));
        final len = int.tryParse(r.headers['content-length'] ?? '');
        if (r.statusCode < 400 && len != null && len < 3 * 1024 * 1024) return null;
        if (len != null) {
          return _Meta('${_s('فيديو', 'Video')} ${(len / 1048576).toStringAsFixed(0)} MB', 2);
        }
      }
    } catch (_) {}
    return _Meta('', 3);
  }

  void _addFound(_Tab tb, String u) async {
    if (!mounted || tb.seen.contains(u)) return;
    tb.seen.add(u);
    if (_adLike.hasMatch(u)) return;
    final m = await _probe(u);
    if (m == null || !mounted) return;
    setState(() {
      if (tb.found.length >= 40) tb.found.removeAt(0);
      tb.found.add(u);
      tb.meta[u] = m;
    });
  }

  Future<void> _addHistory(String title, String url) async {
    if (!url.startsWith('http')) return;
    final p = await SharedPreferences.getInstance();
    final s = p.getString('history');
    final list = s == null ? <dynamic>[] : (jsonDecode(s) as List);
    if (list.isNotEmpty && list.first['u'] == url) {
      if (title.isNotEmpty) list.first['t'] = title;
    } else {
      list.insert(0, {'t': title, 'u': url, 'd': DateTime.now().toIso8601String()});
    }
    if (list.length > 300) list.removeRange(300, list.length);
    await p.setString('history', jsonEncode(list));
  }

  void _openTab(String url, {bool incognito = false}) {
    setState(() {
      tabs.add(_Tab(_nid++, incognito, url));
      cur = tabs.length - 1;
    });
    tc.text = url;
    if (incognito) {
      SharedPreferences.getInstance().then((p) => p.setBool('inc_active', true));
    } else {
      _saveTabs();
    }
  }

  void _closeTab(int i) {
    final t = tabs[i];
    if (t.incognito) t.c?.clearHistory();
    setState(() {
      tabs.removeAt(i);
      if (tabs.isEmpty) {
        tabs.add(_Tab(_nid++, false, _home));
        cur = 0;
      } else if (cur >= tabs.length) {
        cur = tabs.length - 1;
      } else if (i < cur) {
        cur--;
      }
    });
    tc.text = tab.url;
    _saveTabs();
    if (t.incognito && !tabs.any((x) => x.incognito)) _wipeIncognito();
  }

  void _toggleAdblock() async {
    setState(() {
      adblock = !adblock;
      blocked = 0;
    });
    (await SharedPreferences.getInstance()).setBool('adblock', adblock);
    for (final tb in tabs) {
      await tb.c?.removeAllUserScripts();
      for (final s in _scripts()) {
        await tb.c?.addUserScript(userScript: s);
      }
    }
    tab.c?.reload();
  }

  void _go(String q) {
    q = q.trim();
    if (q.isEmpty || tabs.isEmpty) return;
    final isUrl = q.startsWith('http') || (q.contains('.') && !q.contains(' '));
    final url = isUrl
        ? (q.startsWith('http') ? q : 'https://$q')
        : 'https://www.google.com/search?q=${Uri.encodeQueryComponent(q)}';
    tab.c?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  void _showFound() {
    final t = widget.t;
    final tb = tab;
    showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (_) => SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
                child: ListView(shrinkWrap: true, children: [
                  ListTile(
                      title: Text(t['found']!,
                          style: const TextStyle(fontWeight: FontWeight.bold))),
                  if (tb.found.isEmpty)
                    Padding(padding: const EdgeInsets.all(24), child: Text(t['nofound']!)),
                  for (final u in ([...tb.found]
                    ..sort((a, b) => (tb.meta[a]?.prio ?? 3).compareTo(tb.meta[b]?.prio ?? 3))))
                    ListTile(
                      title: Text(u, maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: (tb.meta[u]?.label ?? '').isEmpty ? null : Text(tb.meta[u]!.label),
                      trailing: const Icon(Icons.cast),
                      onLongPress: () => Clipboard.setData(ClipboardData(text: u)),
                      onTap: () async {
                        final title = await tb.c?.getTitle() ?? u;
                        if (!mounted) return;
                        Navigator.pop(context);
                        widget.onCast(u, title);
                      },
                    ),
                ]),
              ),
            ));
  }

  void _showTabs() {
    showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (ctx) => StatefulBuilder(
              builder: (ctx, setS) => SafeArea(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.75),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    ListTile(
                      title: Text('${_s('الصفحات', 'Tabs')} (${tabs.length})',
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                            tooltip: _s('صفحة جديدة', 'New tab'),
                            icon: const Icon(Icons.add),
                            onPressed: () {
                              Navigator.pop(ctx);
                              _openTab(_home);
                            }),
                        IconButton(
                            tooltip: _s('تصفح مخفي', 'Incognito'),
                            icon: const Icon(Icons.visibility_off),
                            onPressed: () {
                              Navigator.pop(ctx);
                              _openTab(_home, incognito: true);
                            }),
                      ]),
                    ),
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: tabs.length,
                        itemBuilder: (_, i) {
                          final tb = tabs[i];
                          return ListTile(
                            selected: i == cur,
                            leading: Icon(tb.incognito ? Icons.visibility_off : Icons.language),
                            title: Text(tb.title.isEmpty ? tb.url : tb.title,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(tb.url, maxLines: 1, overflow: TextOverflow.ellipsis),
                            onTap: () {
                              Navigator.pop(ctx);
                              setState(() => cur = i);
                              tc.text = tb.url;
                              _saveTabs();
                            },
                            trailing: IconButton(
                                icon: const Icon(Icons.close),
                                onPressed: () {
                                  _closeTab(i);
                                  setS(() {});
                                }),
                          );
                        },
                      ),
                    ),
                  ]),
                ),
              ),
            ));
  }

  Widget _webview(_Tab tb) {
    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(tb.url)),
      initialUserScripts: UnmodifiableListView(_scripts()),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        useShouldInterceptRequest: true,
        useShouldOverrideUrlLoading: true,
        supportMultipleWindows: true,
        javaScriptCanOpenWindowsAutomatically: false,
        mediaPlaybackRequiresUserGesture: false,
        allowsInlineMediaPlayback: true,
        cacheEnabled: !tb.incognito,
        incognito: tb.incognito,
        mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
        userAgent: _ua,
      ),
      onWebViewCreated: (ctl) {
        tb.c = ctl;
        ctl.addJavaScriptHandler(
            handlerName: 'sniff',
            callback: (args) {
              if (args.isNotEmpty) _addFound(tb, args[0].toString());
              return null;
            });
        ctl.addJavaScriptHandler(
            handlerName: 'adcount',
            callback: (args) {
              blocked++;
              dirty = true;
              return null;
            });
      },
      onCreateWindow: (ctl, action) async {
        if (adblock) {
          blocked++;
          dirty = true;
        } else {
          final u = action.request.url;
          if (u != null) _openTab(u.toString(), incognito: tb.incognito);
        }
        return false;
      },
      shouldOverrideUrlLoading: (ctl, action) async {
        if (!adblock) return NavigationActionPolicy.ALLOW;
        final u = action.request.url?.toString() ?? '';
        final ok = u.startsWith('http') ||
            u.startsWith('about:') ||
            u.startsWith('data:') ||
            u.startsWith('blob:') ||
            u.startsWith('javascript:');
        if (!ok || AdGuard.isBlocked(u)) {
          blocked++;
          dirty = true;
          return NavigationActionPolicy.CANCEL;
        }
        return NavigationActionPolicy.ALLOW;
      },
      shouldInterceptRequest: (ctl, req) async {
        final u = req.url.toString();
        if (adblock && AdGuard.isBlocked(u)) {
          blocked++;
          dirty = true;
          return WebResourceResponse(
              contentType: u.contains('.js') ? 'application/javascript' : 'text/plain',
              data: Uint8List(0));
        }
        if (_media.hasMatch(u)) _addFound(tb, u);
        return null;
      },
      onLoadStart: (ctl, url) {
        tb.found.clear();
        tb.seen.clear();
        tb.meta.clear();
        if (url != null && _media.hasMatch(url.toString())) _addFound(tb, url.toString());
        if (mounted) setState(() {});
      },
      onLoadStop: (ctl, url) async {
        if (url == null) return;
        tb.url = url.toString();
        tb.title = await ctl.getTitle() ?? '';
        if (!tb.incognito) {
          _addHistory(tb.title, tb.url);
          _saveTabs();
        }
        if (!mounted) return;
        if (identical(tb, tab)) tc.text = tb.url;
        setState(() {});
      },
      onUpdateVisitedHistory: (ctl, url, _) {
        if (url == null) return;
        tb.url = url.toString();
        if (mounted && identical(tb, tab)) tc.text = tb.url;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    if (ready) tab.loaded = true;
    final foundCount = ready ? tab.found.length : 0;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (ready && tab.c != null && await tab.c!.canGoBack()) {
          tab.c!.goBack();
        } else if (mounted) {
          await _saveTabs();
          (await SharedPreferences.getInstance()).setBool('in_browser', false);
          if (mounted) Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: inc ? Colors.deepPurple.shade900 : null,
          title: Text(
            !ready
                ? ''
                : inc
                    ? _s('تصفح مخفي', 'Incognito')
                    : (tab.title.isEmpty ? t['title']! : tab.title),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 15),
          ),
          actions: [
            InkWell(
              onTap: _toggleAdblock,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(adblock ? Icons.shield : Icons.shield_outlined,
                      color: adblock ? Colors.tealAccent : Colors.white54),
                  Text(adblock ? '$blocked' : 'OFF', style: const TextStyle(fontSize: 10)),
                ]),
              ),
            ),
            IconButton(
                tooltip: _s('صفحة جديدة', 'New tab'),
                icon: const Icon(Icons.add),
                onPressed: ready ? () => _openTab(_home, incognito: inc) : null),
            Center(
              child: InkWell(
                onTap: ready ? _showTabs : null,
                child: Container(
                  width: 28,
                  height: 28,
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                      border: Border.all(color: Colors.white70, width: 2),
                      borderRadius: BorderRadius.circular(6)),
                  child: Text('${tabs.length}',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                ),
              ),
            ),
            PopupMenuButton<String>(
              onSelected: (v) async {
                if (!ready) return;
                if (v == 'new') {
                  _openTab(_home);
                } else if (v == 'inc') {
                  _openTab(_home, incognito: true);
                } else if (v == 'reload') {
                  tab.c?.reload();
                } else if (v == 'hist') {
                  final u = await Navigator.push<String>(
                      context, MaterialPageRoute(builder: (_) => HistoryPage(en: en)));
                  if (u != null && mounted) {
                    tab.c?.loadUrl(urlRequest: URLRequest(url: WebUri(u)));
                  }
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'new', child: Text(_s('صفحة جديدة', 'New tab'))),
                PopupMenuItem(value: 'inc', child: Text(_s('صفحة تصفح مخفي', 'New incognito tab'))),
                PopupMenuItem(value: 'hist', child: Text(_s('السجل', 'History'))),
                PopupMenuItem(value: 'reload', child: Text(_s('تحديث', 'Reload'))),
              ],
            ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(52),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: SizedBox(
                height: 40,
                child: TextField(
                  controller: tc,
                  textInputAction: TextInputAction.go,
                  keyboardType: TextInputType.url,
                  onSubmitted: _go,
                  decoration: InputDecoration(
                    hintText: t['go'],
                    filled: true,
                    isDense: true,
                    prefixIcon: inc ? const Icon(Icons.visibility_off, size: 18) : null,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
                  ),
                ),
              ),
            ),
          ),
        ),
        body: !ready
            ? const Center(child: CircularProgressIndicator())
            : Stack(children: [
                IndexedStack(index: cur, children: [
                  for (final tb in tabs)
                    tb.loaded
                        ? KeyedSubtree(key: ValueKey(tb.id), child: _webview(tb))
                        : const SizedBox.shrink(),
                ]),
                Positioned(
                  bottom: 16,
                  right: 16,
                  child: FloatingActionButton.extended(
                    onPressed: _showFound,
                    icon: const Icon(Icons.cast),
                    label: Text('$foundCount'),
                    backgroundColor: foundCount == 0 ? Colors.grey[800] : Colors.teal,
                  ),
                ),
              ]),
      ),
    );
  }
}

class HistoryPage extends StatefulWidget {
  final bool en;
  const HistoryPage({super.key, required this.en});
  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  List<Map<String, dynamic>> items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final s = p.getString('history');
    if (s != null && mounted) {
      setState(() => items = List<Map<String, dynamic>>.from(jsonDecode(s)));
    }
  }

  Future<void> _save() async =>
      (await SharedPreferences.getInstance()).setString('history', jsonEncode(items));

  @override
  Widget build(BuildContext context) {
    final en = widget.en;
    return Scaffold(
      appBar: AppBar(
        title: Text(en ? 'History' : 'السجل'),
        actions: [
          IconButton(
              tooltip: en ? 'Clear all' : 'مسح الكل',
              icon: const Icon(Icons.delete_sweep),
              onPressed: () {
                setState(() => items.clear());
                _save();
              }),
        ],
      ),
      body: items.isEmpty
          ? Center(child: Text(en ? 'No history yet' : 'لا يوجد سجل'))
          : ListView.builder(
              itemCount: items.length,
              itemBuilder: (_, i) {
                final it = items[i];
                final title = (it['t'] ?? '').toString();
                final d = (it['d'] ?? '').toString();
                final when = d.length >= 16 ? d.substring(0, 16).replaceFirst('T', ' ') : d;
                return Dismissible(
                  key: ValueKey('${it['u']}$d'),
                  background: Container(color: Colors.red),
                  onDismissed: (_) {
                    setState(() => items.removeAt(i));
                    _save();
                  },
                  child: ListTile(
                    leading: const Icon(Icons.history),
                    title: Text(title.isEmpty ? it['u'].toString() : title,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${it['u']}\n$when',
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    isThreeLine: true,
                    onTap: () => Navigator.pop(context, it['u'].toString()),
                  ),
                );
              },
            ),
    );
  }
}
