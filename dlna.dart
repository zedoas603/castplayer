import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

const _av = 'urn:schemas-upnp-org:service:AVTransport:1';
const _rc = 'urn:schemas-upnp-org:service:RenderingControl:1';

class DlnaError implements Exception {
  final int? code;
  final String desc;
  final int http;
  DlnaError(this.code, this.desc, this.http);

  String get hint {
    switch (code) {
      case 714:
        return 'صيغة الفيديو غير مدعومة في التلفزيون';
      case 716:
        return 'التلفزيون لم يستطع فتح الرابط (غالبًا محمي بـ headers أو مرتبط بجهازك أو https)';
      case 701:
      case 715:
        return 'التلفزيون مشغول، جرّب مرة أخرى';
      case 402:
        return 'الرابط غير مقبول للتلفزيون';
      default:
        return 'التلفزيون رفض الأمر';
    }
  }

  @override
  String toString() =>
      '$hint [HTTP $http${code != null ? ' / UPnP $code' : ''}${desc.isNotEmpty ? ' $desc' : ''}]';
}

class Renderer {
  final String name;
  final String? avUrl;
  final String? rcUrl;
  Renderer(this.name, this.avUrl, this.rcUrl);
}

String esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

int _secs(String t) {
  final p = t.split(':');
  if (p.length != 3) return 0;
  return ((int.tryParse(p[0]) ?? 0) * 3600) +
      ((int.tryParse(p[1]) ?? 0) * 60) +
      (double.tryParse(p[2]) ?? 0).floor();
}

String _fmt(int s) {
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, x = s % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return '$h:${two(m)}:${two(x)}';
}

class Dlna {
  static Future<List<Renderer>> discover() async {
    final found = <String>{};
    final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    sock.broadcastEnabled = true;
    final msg = utf8.encode('M-SEARCH * HTTP/1.1\r\n'
        'HOST: 239.255.255.250:1900\r\n'
        'MAN: "ssdp:discover"\r\nMX: 2\r\n'
        'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n');
    sock.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = sock.receive();
      if (d == null) return;
      final t = utf8.decode(d.data, allowMalformed: true);
      final m = RegExp(r'location:\s*(\S+)', caseSensitive: false).firstMatch(t);
      if (m != null) found.add(m.group(1)!);
    });
    final addr = InternetAddress('239.255.255.250');
    for (var i = 0; i < 3; i++) {
      sock.send(msg, addr, 1900);
      await Future.delayed(const Duration(milliseconds: 300));
    }
    await Future.delayed(const Duration(seconds: 4));
    sock.close();
    final out = <Renderer>[];
    for (final loc in found) {
      try {
        final r = await _describe(loc);
        if (r != null) out.add(r);
      } catch (_) {}
    }
    return out;
  }

  static Future<Renderer?> _describe(String loc) async {
    final r = await http.get(Uri.parse(loc)).timeout(const Duration(seconds: 5));
    final xml = utf8.decode(r.bodyBytes, allowMalformed: true);
    final name = RegExp(r'<friendlyName>(.*?)</friendlyName>', dotAll: true)
            .firstMatch(xml)
            ?.group(1) ??
        'TV';
    String? av, rc;
    for (final s in RegExp(r'<service>(.*?)</service>', dotAll: true).allMatches(xml)) {
      final b = s.group(1)!;
      final type = RegExp(r'<serviceType>(.*?)</serviceType>').firstMatch(b)?.group(1) ?? '';
      final ctl = RegExp(r'<controlURL>(.*?)</controlURL>').firstMatch(b)?.group(1);
      if (ctl == null) continue;
      final full = Uri.parse(loc).resolve(ctl).toString();
      if (type.contains('AVTransport')) av = full;
      if (type.contains('RenderingControl')) rc = full;
    }
    if (av == null) return null;
    return Renderer(name, av, rc);
  }

  static Future<String> _soap(String url, String svc, String action, String args) async {
    final body = '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body><u:$action xmlns:u="$svc">$args</u:$action></s:Body></s:Envelope>';
    final r = await http
        .post(Uri.parse(url),
            headers: {
              'Content-Type': 'text/xml; charset="utf-8"',
              'SOAPACTION': '"$svc#$action"',
            },
            body: body)
        .timeout(const Duration(seconds: 10));
    final text = utf8.decode(r.bodyBytes, allowMalformed: true);
    if (r.statusCode >= 300) {
      final code = int.tryParse(
          RegExp(r'<errorCode>(\d+)</errorCode>').firstMatch(text)?.group(1) ?? '');
      final desc =
          RegExp(r'<errorDescription>(.*?)</errorDescription>').firstMatch(text)?.group(1) ?? '';
      throw DlnaError(code, desc, r.statusCode);
    }
    return text;
  }

  static String _mimeFor(String url) {
    final u = url.toLowerCase();
    if (u.contains('.m3u8')) return 'application/vnd.apple.mpegurl';
    if (u.contains('.mpd')) return 'application/dash+xml';
    if (u.contains('.webm')) return 'video/webm';
    if (u.contains('.mkv')) return 'video/x-matroska';
    return 'video/mp4';
  }

  static String _didl(String url, String title, String protocolInfo) =>
      '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
      'xmlns:dc="http://purl.org/dc/elements/1.1/" '
      'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
      '<item id="0" parentID="-1" restricted="1"><dc:title>${esc(title)}</dc:title>'
      '<upnp:class>object.item.videoItem</upnp:class>'
      '<res protocolInfo="$protocolInfo">${esc(url)}</res></item></DIDL-Lite>';

  /// Tries several combinations (metadata variants, https->http) until the TV accepts.
  static Future<void> cast(Renderer r, String url, String title,
      {bool viaProxy = false}) async {
    try {
      await _soap(r.avUrl!, _av, 'Stop', '<InstanceID>0</InstanceID>');
    } catch (_) {}
    final urls = <String>[];
    final mime = _mimeFor(url);
    if (viaProxy) {
      urls.add(await Proxy.urlFor(url, Uri.parse(r.avUrl!).host));
    } else {
      urls.add(url);
      if (url.startsWith('https://')) urls.add('http://${url.substring(8)}');
    }
    DlnaError? first;
    Object? last;
    for (final u in urls) {
      final metas = [
        _didl(u, title, 'http-get:*:$mime:*'),
        _didl(u, title, 'http-get:*:*:*'),
        '',
      ];
      for (final m in metas) {
        try {
          await _soap(
              r.avUrl!,
              _av,
              'SetAVTransportURI',
              '<InstanceID>0</InstanceID><CurrentURI>${esc(u)}</CurrentURI>'
              '<CurrentURIMetaData>${esc(m)}</CurrentURIMetaData>');
          await Future.delayed(const Duration(milliseconds: 400));
          for (var i = 0; i < 3; i++) {
            try {
              await play(r);
              return;
            } on DlnaError catch (e) {
              if (i == 2 || (e.code != 701 && e.code != 715)) rethrow;
              await Future.delayed(const Duration(milliseconds: 800));
            }
          }
        } catch (e) {
          last = e;
          if (e is DlnaError) first ??= e;
        }
      }
    }
    throw first ?? last ?? Exception('cast failed');
  }

  static Future<void> play(Renderer r) => _soap(r.avUrl!, _av, 'Play',
      '<InstanceID>0</InstanceID><Speed>1</Speed>');
  static Future<void> pause(Renderer r) =>
      _soap(r.avUrl!, _av, 'Pause', '<InstanceID>0</InstanceID>');
  static Future<void> stop(Renderer r) =>
      _soap(r.avUrl!, _av, 'Stop', '<InstanceID>0</InstanceID>');
  static Future<void> seek(Renderer r, int sec) => _soap(
      r.avUrl!, _av, 'Seek',
      '<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>${_fmt(sec)}</Target>');

  static Future<void> setVolume(Renderer r, int v) async {
    if (r.rcUrl == null) return;
    await _soap(r.rcUrl!, _rc, 'SetVolume',
        '<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>$v</DesiredVolume>');
  }

  /// returns [position, duration] in seconds
  static Future<List<int>> position(Renderer r) async {
    final x = await _soap(r.avUrl!, _av, 'GetPositionInfo', '<InstanceID>0</InstanceID>');
    final pos = RegExp(r'<RelTime>(.*?)</RelTime>').firstMatch(x)?.group(1) ?? '0:00:00';
    final dur = RegExp(r'<TrackDuration>(.*?)</TrackDuration>').firstMatch(x)?.group(1) ?? '0:00:00';
    return [_secs(pos), _secs(dur)];
  }
}


class _Target {
  final String url;
  final Map<String, String> headers;
  _Target(this.url, this.headers);
}

/// Local HTTP proxy on the phone: the TV fetches the video from the phone,
/// and the phone fetches it from the source with the headers the site needs.
class Proxy {
  static HttpServer? _server;
  static bool active = false;
  static String _origin = '';
  static int _n = 0;
  static const _ch = MethodChannel('castplayer/intent');
  static const _defaultUa =
      'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';
  static final Map<String, Map<String, String>> _remembered = {};
  static final Map<String, _Target> _targets = {};
  static final Map<String, String> _idOf = {};
  static final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..autoUncompress = false
    ..badCertificateCallback = (c, h, p) => true;

  static void remember(String url, Map<String, String> headers) {
    if (_remembered.length > 300) _remembered.remove(_remembered.keys.first);
    _remembered[url] = headers;
  }

  static Map<String, String>? headersFor(String url) => _remembered[url];

  static void addCookie(String url, String cookie) {
    final h = _remembered[url];
    if (h != null && cookie.isNotEmpty) h['Cookie'] = cookie;
  }

  static String _ext(String u) {
    final segs = Uri.tryParse(u)?.pathSegments ?? const <String>[];
    if (segs.isEmpty) return '';
    return RegExp(r'\.[A-Za-z0-9]{2,5}$').firstMatch(segs.last)?.group(0) ?? '';
  }

  static String _idFor(String url, Map<String, String> h) {
    final ex = _idOf[url];
    if (ex != null) {
      _targets[ex] = _Target(url, h);
      return ex;
    }
    final id = (_n++).toRadixString(36);
    _idOf[url] = id;
    _targets[id] = _Target(url, h);
    if (_targets.length > 4000) {
      final k = _targets.keys.first;
      _idOf.remove(_targets[k]!.url);
      _targets.remove(k);
    }
    return id;
  }

  static String _wrap(String abs, Map<String, String> h) =>
      '$_origin/s/${_idFor(abs, h)}${_ext(abs)}';

  static Future<String> _lanIp(String tvHost) async {
    final ifs = await NetworkInterface.list(
        type: InternetAddressType.IPv4, includeLoopback: false);
    final pre = tvHost.split('.').take(3).join('.');
    String? fallback;
    for (final i in ifs) {
      for (final a in i.addresses) {
        if (a.address.startsWith('$pre.')) return a.address;
        fallback ??= a.address;
      }
    }
    if (fallback != null) return fallback;
    throw Exception('No Wi-Fi address found');
  }

  static Future<String> urlFor(String url, String tvHost) async {
    var s = _server;
    if (s == null) {
      s = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      s.listen(_handle, onError: (_) {});
      _server = s;
    }
    try {
      await _ch.invokeMethod('startProxy');
    } catch (_) {}
    final ip = await _lanIp(tvHost);
    _origin = 'http://$ip:${s.port}';
    active = true;
    final h = Map<String, String>.from(_remembered[url] ?? {'User-Agent': _defaultUa});
    return _wrap(url, h);
  }

  static Future<void> stop() async {
    active = false;
    try {
      await _ch.invokeMethod('stopProxy');
    } catch (_) {}
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
    _targets.clear();
    _idOf.clear();
  }

  static String _rewrite(String body, Uri base, Map<String, String> h) {
    final out = <String>[];
    for (final raw in body.split('\n')) {
      final l = raw.trimRight();
      if (l.isEmpty) {
        out.add(l);
      } else if (l.startsWith('#')) {
        out.add(l.replaceAllMapped(RegExp(r'URI="([^"]+)"'),
            (m) => 'URI="${_wrap(base.resolve(m.group(1)!).toString(), h)}"'));
      } else {
        out.add(_wrap(base.resolve(l).toString(), h));
      }
    }
    return out.join('\n');
  }

  static Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final segs = req.uri.pathSegments;
      if (segs.length < 2 || segs[0] != 's') {
        res.statusCode = 404;
        await res.close();
        return;
      }
      final raw = segs[1];
      final dot = raw.indexOf('.');
      final t = _targets[dot < 0 ? raw : raw.substring(0, dot)];
      if (t == null) {
        res.statusCode = 404;
        await res.close();
        return;
      }
      final method = req.method == 'HEAD' ? 'HEAD' : 'GET';
      final up = await _client.openUrl(method, Uri.parse(t.url));
      t.headers.forEach((k, v) {
        try {
          up.headers.set(k, v);
        } catch (_) {}
      });
      up.headers.set('Accept-Encoding', 'identity');
      final range = req.headers.value('range');
      if (range != null) up.headers.set('Range', range);
      final resp = await up.close();
      final ct = resp.headers.contentType?.mimeType ?? '';
      final isM3u8 = t.url.toLowerCase().contains('.m3u8') || ct.contains('mpegurl');
      res.headers.set('Access-Control-Allow-Origin', '*');
      res.headers.set('transferMode.dlna.org', 'Streaming');
      if (isM3u8 && resp.statusCode == 200 && method == 'GET') {
        final body = await utf8.decoder.bind(resp).join();
        final bytes = utf8.encode(_rewrite(body, Uri.parse(t.url), t.headers));
        res.statusCode = 200;
        res.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
        res.contentLength = bytes.length;
        res.add(bytes);
        await res.close();
        return;
      }
      res.statusCode = resp.statusCode;
      for (final h in ['content-type', 'content-range', 'accept-ranges', 'last-modified', 'etag']) {
        final v = resp.headers.value(h);
        if (v != null) res.headers.set(h, v);
      }
      if (resp.headers.value('accept-ranges') == null) {
        res.headers.set('accept-ranges', 'bytes');
      }
      if (resp.contentLength >= 0) res.contentLength = resp.contentLength;
      if (method == 'GET') {
        await res.addStream(resp);
      } else {
        await resp.drain();
      }
      await res.close();
    } catch (_) {
      try {
        res.statusCode = 502;
        await res.close();
      } catch (_) {}
    }
  }
}
