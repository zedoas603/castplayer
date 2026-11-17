import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

const _av = 'urn:schemas-upnp-org:service:AVTransport:1';
const _rc = 'urn:schemas-upnp-org:service:RenderingControl:1';

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
    if (r.statusCode >= 300) throw Exception('HTTP ${r.statusCode}');
    return utf8.decode(r.bodyBytes, allowMalformed: true);
  }

  static Future<void> cast(Renderer r, String url, String title) async {
    final mime = url.contains('.m3u8')
        ? 'application/vnd.apple.mpegurl'
        : 'video/mp4';
    final didl = '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
        '<item id="0" parentID="-1" restricted="1"><dc:title>${esc(title)}</dc:title>'
        '<upnp:class>object.item.videoItem</upnp:class>'
        '<res protocolInfo="http-get:*:$mime:*">${esc(url)}</res></item></DIDL-Lite>';
    try {
      await _soap(r.avUrl!, _av, 'Stop', '<InstanceID>0</InstanceID>');
    } catch (_) {}
    await _soap(r.avUrl!, _av, 'SetAVTransportURI',
        '<InstanceID>0</InstanceID><CurrentURI>${esc(url)}</CurrentURI>'
        '<CurrentURIMetaData>${esc(didl)}</CurrentURIMetaData>');
    await play(r);
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
