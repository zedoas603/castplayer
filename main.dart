import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dlna.dart';
import 'browser.dart';

void main() => runApp(const CastApp());

const ar = {
  'title': 'كاست بلاير',
  'go': 'ابحث في جوجل أو اكتب رابط',
  'found': 'فيديوهات مكتشفة في الصفحة',
  'nofound': 'لم يتم اكتشاف فيديو بعد. شغّل الفيديو داخل الصفحة وانتظر لحظات.',
  'add': 'إضافة رابط',
  'name': 'الاسم',
  'url': 'رابط الفيديو',
  'save': 'حفظ',
  'cancel': 'إلغاء',
  'empty': 'لا توجد روابط. اضغط + لإضافة رابط.',
  'pick': 'اختر التلفزيون',
  'search': 'جاري البحث عن الأجهزة...',
  'none': 'لم يتم العثور على أجهزة. تأكد أن الهاتف والتلفزيون على نفس الشبكة.',
  'refresh': 'تحديث',
  'remote': 'ريموت',
  'err': 'حدث خطأ',
  'vol': 'الصوت',
  'hint': 'يمكنك الآن الخروج من التطبيق، البث مستمر على التلفزيون.',
};
const en = {
  'title': 'CastPlayer',
  'go': 'Search Google or enter URL',
  'found': 'Videos found on this page',
  'nofound': 'No video detected yet. Play the video in the page and wait a moment.',
  'add': 'Add link',
  'name': 'Name',
  'url': 'Video URL',
  'save': 'Save',
  'cancel': 'Cancel',
  'empty': 'No links yet. Tap + to add one.',
  'pick': 'Choose a TV',
  'search': 'Searching for devices...',
  'none': 'No devices found. Make sure phone and TV are on the same Wi-Fi.',
  'refresh': 'Refresh',
  'remote': 'Remote',
  'err': 'Error',
  'vol': 'Volume',
  'hint': 'You can leave the app now, playback continues on the TV.',
};

class CastApp extends StatefulWidget {
  const CastApp({super.key});
  @override
  State<CastApp> createState() => _CastAppState();
}

class _CastAppState extends State<CastApp> {
  bool isAr = true;
  Map<String, String> get t => isAr ? ar : en;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      setState(() => isAr = p.getBool('ar') ?? true);
    });
  }

  void toggle() async {
    setState(() => isAr = !isAr);
    (await SharedPreferences.getInstance()).setBool('ar', isAr);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true)
          .copyWith(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal, brightness: Brightness.dark)),
      builder: (c, child) => Directionality(
          textDirection: isAr ? TextDirection.rtl : TextDirection.ltr, child: child!),
      home: Home(t: t, onToggle: toggle),
    );
  }
}

class Home extends StatefulWidget {
  final Map<String, String> t;
  final VoidCallback onToggle;
  const Home({super.key, required this.t, required this.onToggle});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  List<Map<String, dynamic>> links = [];

  @override
  void initState() {
    super.initState();
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'onUrl') _incoming(call.arguments);
    });
    _ch.invokeMethod('getInitial').then(_incoming).catchError((_) {});
    SharedPreferences.getInstance().then((p) {
      final s = p.getString('links');
      if (s != null) setState(() => links = List<Map<String, dynamic>>.from(jsonDecode(s)));
      if (p.getBool('in_browser') == true) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _openBrowser();
        });
      }
    });
  }

  static const _ch = MethodChannel('castplayer/intent');

  // A link sent from another app (Open with / Share) is cast straight away.
  void _incoming(dynamic m) {
    if (m is! Map) return;
    final url = m['url']?.toString();
    if (url == null || url.isEmpty) return;
    final title = (m['title'] ?? '').toString();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _castUrl(url, title.isEmpty ? url : title);
    });
  }

  void _openBrowser() => Navigator.push(context,
      MaterialPageRoute(builder: (_) => Browser(t: widget.t, onCast: _castUrl)));

  Future<void> _save() async =>
      (await SharedPreferences.getInstance()).setString('links', jsonEncode(links));

  void _add() {
    final n = TextEditingController(), u = TextEditingController();
    final t = widget.t;
    showDialog(
        context: context,
        builder: (_) => AlertDialog(
              title: Text(t['add']!),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(controller: n, decoration: InputDecoration(labelText: t['name'])),
                TextField(
                    controller: u,
                    keyboardType: TextInputType.url,
                    decoration: InputDecoration(labelText: t['url'])),
              ]),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: Text(t['cancel']!)),
                FilledButton(
                    onPressed: () {
                      if (u.text.trim().isEmpty) return;
                      setState(() => links.add({
                            'name': n.text.trim().isEmpty ? u.text.trim() : n.text.trim(),
                            'url': u.text.trim()
                          }));
                      _save();
                      Navigator.pop(context);
                    },
                    child: Text(t['save']!)),
              ],
            ));
  }

  void _cast(Map<String, dynamic> item) => _castUrl(item['url'], item['name']);

  void _castUrl(String url, String name) async {
    final r = await showModalBottomSheet<Renderer>(
        context: context, builder: (_) => DevicePicker(t: widget.t));
    if (r == null || !mounted) return;
    try {
      await Dlna.cast(r, url, name);
      if (!mounted) return;
      Navigator.push(context,
          MaterialPageRoute(builder: (_) => Remote(t: widget.t, r: r, title: name)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('${widget.t['err']}: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    return Scaffold(
      appBar: AppBar(title: Text(t['title']!), actions: [
        IconButton(
            icon: const Icon(Icons.search),
            onPressed: _openBrowser),
        IconButton(icon: const Icon(Icons.language), onPressed: widget.onToggle)
      ]),
      floatingActionButton: FloatingActionButton(onPressed: _add, child: const Icon(Icons.add)),
      body: links.isEmpty
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(t['empty']!)))
          : ListView.builder(
              itemCount: links.length,
              itemBuilder: (_, i) => Dismissible(
                key: ValueKey(links[i]['url'] + '$i'),
                onDismissed: (_) {
                  setState(() => links.removeAt(i));
                  _save();
                },
                background: Container(color: Colors.red),
                child: ListTile(
                  title: Text(links[i]['name']),
                  subtitle: Text(links[i]['url'], maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: IconButton(
                      icon: const Icon(Icons.cast), onPressed: () => _cast(links[i])),
                ),
              ),
            ),
    );
  }
}

class DevicePicker extends StatefulWidget {
  final Map<String, String> t;
  const DevicePicker({super.key, required this.t});
  @override
  State<DevicePicker> createState() => _DevicePickerState();
}

class _DevicePickerState extends State<DevicePicker> {
  List<Renderer>? devices;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  void _scan() async {
    setState(() => devices = null);
    List<Renderer> d = [];
    try {
      d = await Dlna.discover();
    } catch (_) {}
    if (mounted) setState(() => devices = d);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    return SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          title: Text(t['pick']!, style: const TextStyle(fontWeight: FontWeight.bold)),
          trailing: IconButton(icon: const Icon(Icons.refresh), onPressed: _scan),
        ),
        if (devices == null)
          Padding(
              padding: const EdgeInsets.all(24),
              child: Column(children: [const CircularProgressIndicator(), const SizedBox(height: 12), Text(t['search']!)]))
        else if (devices!.isEmpty)
          Padding(padding: const EdgeInsets.all(24), child: Text(t['none']!))
        else
          ...devices!.map((d) => ListTile(
              leading: const Icon(Icons.tv),
              title: Text(d.name),
              onTap: () => Navigator.pop(context, d))),
      ]),
    );
  }
}

class Remote extends StatefulWidget {
  final Map<String, String> t;
  final Renderer r;
  final String title;
  const Remote({super.key, required this.t, required this.r, required this.title});
  @override
  State<Remote> createState() => _RemoteState();
}

class _RemoteState extends State<Remote> {
  int pos = 0, dur = 0;
  double vol = 30;
  bool playing = true, dragging = false;
  Timer? timer;

  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (dragging) return;
      try {
        final p = await Dlna.position(widget.r);
        if (mounted) setState(() { pos = p[0]; dur = p[1]; });
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  String f(int s) =>
      '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

  Future<void> _do(Future<void> Function() fn) async {
    try {
      await fn();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('${widget.t['err']}: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    return Scaffold(
      appBar: AppBar(title: Text('${t['remote']} - ${widget.r.name}')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(children: [
          Text(widget.title, style: const TextStyle(fontSize: 18), textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(t['hint']!, style: const TextStyle(color: Colors.white54), textAlign: TextAlign.center),
          const Spacer(),
          Slider(
            value: dur == 0 ? 0 : pos.clamp(0, dur).toDouble(),
            max: dur == 0 ? 1 : dur.toDouble(),
            onChangeStart: (_) => dragging = true,
            onChanged: (v) => setState(() => pos = v.toInt()),
            onChangeEnd: (v) async {
              await _do(() => Dlna.seek(widget.r, v.toInt()));
              dragging = false;
            },
          ),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [Text(f(pos)), Text(f(dur))]),
          const SizedBox(height: 16),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(
                iconSize: 56,
                icon: Icon(playing ? Icons.pause_circle : Icons.play_circle),
                onPressed: () async {
                  await _do(() => playing ? Dlna.pause(widget.r) : Dlna.play(widget.r));
                  setState(() => playing = !playing);
                }),
            IconButton(
                iconSize: 48,
                icon: const Icon(Icons.stop_circle),
                onPressed: () async {
                  await _do(() => Dlna.stop(widget.r));
                  if (mounted) Navigator.pop(context);
                }),
          ]),
          const SizedBox(height: 16),
          Row(children: [
            const Icon(Icons.volume_up),
            Expanded(
                child: Slider(
                    value: vol,
                    max: 100,
                    label: '${vol.toInt()}',
                    onChanged: (v) => setState(() => vol = v),
                    onChangeEnd: (v) => _do(() => Dlna.setVolume(widget.r, v.toInt())))),
          ]),
          const Spacer(),
        ]),
      ),
    );
  }
}
