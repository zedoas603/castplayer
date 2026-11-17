import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

const _js = r'''
(function(){
  if (window.__sn) return; window.__sn = 1;
  function send(u){
    try {
      if (/\.(m3u8|mp4|mpd)(\?|#|$)/i.test(u))
        Sniff.postMessage(new URL(u, location.href).href);
    } catch(e) {}
  }
  var xo = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function(m, u){ send(String(u)); return xo.apply(this, arguments); };
  var f = window.fetch;
  if (f) window.fetch = function(a){ send(typeof a === 'string' ? a : (a && a.url) || ''); return f.apply(this, arguments); };
  setInterval(function(){
    document.querySelectorAll('video,source').forEach(function(v){
      if (v.src) send(v.src);
      if (v.currentSrc) send(v.currentSrc);
    });
  }, 1500);
})();
''';

// Ad blocking script: blocks ad requests, popups, and anti-adblock walls.
const _adJs = r'''
(function(){
  if (window.__ab) return; window.__ab = 1;
  var B = __LIST__;
  function bad(u){
    try {
      var h = new URL(u, location.href).hostname;
      for (var i = 0; i < B.length; i++) {
        if (h === B[i] || h.endsWith('.' + B[i])) return true;
      }
    } catch(e) {}
    return false;
  }
  function cnt(){ try { AdBlock.postMessage('1'); } catch(e) {} }

  // popups
  window.open = function(){ cnt(); return null; };

  // network requests to ad domains
  var xo = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function(m, u){
    if (bad(String(u))) { cnt(); arguments[1] = 'about:blank'; }
    return xo.apply(this, arguments);
  };
  var fe = window.fetch;
  if (fe) window.fetch = function(a){
    var u = typeof a === 'string' ? a : (a && a.url) || '';
    if (bad(u)) { cnt(); return Promise.resolve(new Response('', {status: 200})); }
    return fe.apply(this, arguments);
  };

  // fake the globals that ad-block detectors look for
  window.canRunAds = true;
  window.adsbygoogle = window.adsbygoogle || [];
  window.google_ad_status = 1;

  // remove ad elements as they appear
  function clean(n){
    if (n.nodeType !== 1) return;
    var tag = n.tagName;
    var src = n.src || n.href || '';
    if ((tag === 'SCRIPT' || tag === 'IFRAME' || tag === 'IMG' || tag === 'LINK') && src && bad(src)) {
      n.remove(); cnt();
    }
  }
  new MutationObserver(function(ms){
    ms.forEach(function(m){ m.addedNodes.forEach(clean); });
  }).observe(document, {childList: true, subtree: true});

  var st = document.createElement('style');
  st.textContent = 'ins.adsbygoogle,[id^="google_ads"],[id^="div-gpt-ad"],iframe[src*="doubleclick"]{display:none!important}';
  (document.head || document.documentElement).appendChild(st);

  // anti-adblock walls: big fixed overlays that mention an ad blocker
  var re = /ad ?block|ads? blocker|disable (your )?ad|مانع الإعلانات|مانع إعلانات|حاجب الإعلانات/i;
  setInterval(function(){
    if (!document.body) return;
    var removed = false;
    Array.prototype.forEach.call(document.body.children, function(e){
      var s = getComputedStyle(e);
      if ((s.position === 'fixed' || s.position === 'absolute') &&
          e.offsetWidth > innerWidth * 0.5 && e.offsetHeight > innerHeight * 0.3 &&
          re.test(e.innerText || '')) {
        e.remove(); removed = true; cnt();
      }
    });
    if (removed) {
      document.body.style.setProperty('overflow', 'auto', 'important');
      document.documentElement.style.setProperty('overflow', 'auto', 'important');
    }
  }, 1000);
})();
''';

const _adDomains = [
  'doubleclick.net', 'googlesyndication.com', 'googleadservices.com',
  'adservice.google.com', 'amazon-adsystem.com', 'adnxs.com', 'taboola.com',
  'outbrain.com', 'criteo.com', 'criteo.net', 'pubmatic.com',
  'rubiconproject.com', 'openx.net', 'adsrvr.org', 'casalemedia.com',
  'moatads.com', 'scorecardresearch.com', 'popads.net', 'popcash.net',
  'propellerads.com', 'propellerclick.com', 'exoclick.com', 'exosrv.com',
  'juicyads.com', 'trafficjunky.net', 'adsterra.com', 'highperformanceformat.com',
  'hilltopads.net', 'clickadu.com', 'adcash.com', 'mgid.com', 'revcontent.com',
  'onclickads.net', 'a-ads.com', 'tsyndicate.com', 'ad-maven.com',
  'admaven.com', 'yllix.com', 'bidvertiser.com', 'adform.net',
  'smartadserver.com', '33across.com', 'realsrv.com', 'adskeeper.com',
  'ads.yahoo.com', 'advertising.com', 'zedo.com', 'adbrite.com',
];

bool _isBlocked(String url) {
  final h = Uri.tryParse(url)?.host ?? '';
  if (h.isEmpty) return false;
  for (final d in _adDomains) {
    if (h == d || h.endsWith('.$d')) return true;
  }
  return false;
}

class Browser extends StatefulWidget {
  final Map<String, String> t;
  final void Function(String url, String title) onCast;
  const Browser({super.key, required this.t, required this.onCast});
  @override
  State<Browser> createState() => _BrowserState();
}

class _BrowserState extends State<Browser> {
  late final WebViewController c;
  final tc = TextEditingController();
  final found = <String>[];
  bool adblock = true;
  int blocked = 0;

  String get _adScript => _adJs.replaceFirst('__LIST__', jsonEncode(_adDomains));

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (mounted) setState(() => adblock = p.getBool('adblock') ?? true);
    });
    c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('Sniff', onMessageReceived: (m) {
        if (mounted && !found.contains(m.message)) {
          setState(() => found.add(m.message));
        }
      })
      ..addJavaScriptChannel('AdBlock', onMessageReceived: (_) {
        if (mounted) setState(() => blocked++);
      })
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (r) {
          if (!adblock) return NavigationDecision.navigate;
          final u = r.url;
          final okScheme = u.startsWith('http') ||
              u.startsWith('about:') ||
              u.startsWith('data:') ||
              u.startsWith('blob:') ||
              u.startsWith('javascript:');
          if (!okScheme || _isBlocked(u)) {
            if (mounted) setState(() => blocked++);
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
        onPageStarted: (u) {
          if (!mounted) return;
          setState(() => found.clear());
          if (RegExp(r'\.(m3u8|mp4|mpd)(\?|#|$)', caseSensitive: false).hasMatch(u)) {
            found.add(u);
          }
          c.runJavaScript(_js);
          if (adblock) c.runJavaScript(_adScript);
        },
        onPageFinished: (u) {
          c.runJavaScript(_js);
          if (adblock) c.runJavaScript(_adScript);
          if (mounted) tc.text = u;
        },
      ))
      ..loadRequest(Uri.parse('https://www.google.com'));
  }

  void _toggleAdblock() async {
    setState(() {
      adblock = !adblock;
      blocked = 0;
    });
    (await SharedPreferences.getInstance()).setBool('adblock', adblock);
    c.reload();
  }

  void _go(String q) {
    q = q.trim();
    if (q.isEmpty) return;
    final isUrl = q.startsWith('http') || (q.contains('.') && !q.contains(' '));
    final url = isUrl
        ? (q.startsWith('http') ? q : 'https://$q')
        : 'https://www.google.com/search?q=${Uri.encodeQueryComponent(q)}';
    c.loadRequest(Uri.parse(url));
  }

  void _showFound() {
    final t = widget.t;
    showModalBottomSheet(
        context: context,
        builder: (_) => SafeArea(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                ListTile(
                    title: Text(t['found']!,
                        style: const TextStyle(fontWeight: FontWeight.bold))),
                if (found.isEmpty)
                  Padding(padding: const EdgeInsets.all(24), child: Text(t['nofound']!)),
                Flexible(
                  child: ListView(shrinkWrap: true, children: [
                    for (final u in found)
                      ListTile(
                        title: Text(u, maxLines: 2, overflow: TextOverflow.ellipsis),
                        trailing: const Icon(Icons.cast),
                        onTap: () async {
                          final title = await c.getTitle() ?? u;
                          if (!mounted) return;
                          Navigator.pop(context);
                          widget.onCast(u, title);
                        },
                      ),
                  ]),
                ),
              ]),
            ));
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await c.canGoBack()) {
          c.goBack();
        } else if (mounted) {
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: TextField(
            controller: tc,
            textInputAction: TextInputAction.go,
            keyboardType: TextInputType.url,
            onSubmitted: _go,
            decoration: InputDecoration(hintText: t['go'], border: InputBorder.none),
          ),
          actions: [
            Tooltip(
              message: t['adblock'] ?? 'حظر الإعلانات',
              child: InkWell(
                onTap: _toggleAdblock,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(adblock ? Icons.shield : Icons.shield_outlined,
                        color: adblock ? Colors.tealAccent : Colors.white54),
                    Text(adblock ? '$blocked' : 'OFF',
                        style: const TextStyle(fontSize: 10)),
                  ]),
                ),
              ),
            ),
            IconButton(icon: const Icon(Icons.refresh), onPressed: () => c.reload()),
          ],
        ),
        body: Stack(children: [
          WebViewWidget(controller: c),
          Positioned(
            bottom: 16,
            right: 16,
            child: FloatingActionButton.extended(
              onPressed: _showFound,
              icon: const Icon(Icons.cast),
              label: Text('${found.length}'),
              backgroundColor: found.isEmpty ? Colors.grey[800] : Colors.teal,
            ),
          ),
        ]),
      ),
    );
  }
}
