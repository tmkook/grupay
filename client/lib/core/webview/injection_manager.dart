import 'dart:convert';
import 'dart:io';

class InjectionManager {
  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  Uri? _sourceUrl;
  String? _source;

  Future<String> load(String? address) async {
    final url = Uri.tryParse(address ?? '');
    if (url == null ||
        url.scheme != 'https' ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty) {
      throw const FormatException('服务端尚未配置有效的 HTTPS 脚本地址');
    }
    if (_sourceUrl == url && _source != null) return _source!;
    final request = await _client.getUrl(url);
    request.followRedirects = false;
    final response = await request.close();
    if (response.statusCode != 200) {
      await response.drain();
      throw const FormatException('产品脚本下载失败');
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      if (bytes.length + chunk.length > 1048576) {
        throw const FormatException('产品脚本过大');
      }
      bytes.addAll(chunk);
    }
    final source = utf8.decode(bytes);
    if (source.trim().isEmpty) throw const FormatException('产品脚本为空');
    _sourceUrl = url;
    return _source = source;
  }

  void dispose() => _client.close(force: true);
}
