import 'package:flutter/material.dart';
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

  @override
  void initState() {
    super.initState();
    c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('Sniff', onMessageReceived: (m) {
        if (mounted && !found.contains(m.message)) {
          setState(() => found.add(m.message));
        }
      })
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (u) {
          if (!mounted) return;
          setState(() => found.clear());
          if (RegExp(r'\.(m3u8|mp4|mpd)(\?|#|$)', caseSensitive: false).hasMatch(u)) {
            found.add(u);
          }
          c.runJavaScript(_js);
        },
        onPageFinished: (u) {
          c.runJavaScript(_js);
          if (mounted) tc.text = u;
        },
      ))
      ..loadRequest(Uri.parse('https://www.google.com'));
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
