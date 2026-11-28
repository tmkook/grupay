import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

String loginDigest(String username, String password) {
  final inner = md5.convert(utf8.encode(password));
  return md5.convert(utf8.encode('$username$inner')).toString();
}

class WsClient extends ChangeNotifier {
  // 由 pubspec.yaml 的 version 经 Flutter 构建自动注入，避免版本号出现两份。
  static const appVersion = String.fromEnvironment(
    'FLUTTER_BUILD_NAME',
    defaultValue: '0.0.0',
  );

  Future<(Uri, String)?> availableUpdate(int installedBuild) async {
    final service = _service;
    if (service == null) throw StateError('服务地址不可用');
    final http = HttpClient();
    Future<(Uri, String)?> check() async {
      final request = await http.getUrl(
        Uri.https(service.authority, '/releases/latest.json'),
      );
      request.followRedirects = false;
      final response = await request.close();
      if (response.statusCode != 200) throw StateError('版本检查失败');
      final release =
          jsonDecode(await utf8.decoder.bind(response).join()) as Map;
      final build = release['build'] as int;
      final version = release['version'] as String;
      final hash = release['sha256'] as String;
      if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version) ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
        throw const FormatException('版本信息无效');
      }
      if (build <= installedBuild) return null;
      return (
        Uri.https(service.authority, '/releases/grupay-$version+$build.apk'),
        hash,
      );
    }

    try {
      return await check().timeout(const Duration(seconds: 12));
    } finally {
      http.close(force: true);
    }
  }

  String status = '';
  String? nickname;
  bool connected = false;
  bool get connectionFailed => status == '连接失败，请检查网络';
  Map<String, dynamic> settings = {};
  String scope = '';
  Uri? _service;

  Future<void> _logWrites = Future.value();
  // 心跳和 pong 频率高且无诊断价值，避免每条消息都落盘。
  static const _ignoredLogTypes = {'heartbeat', 'pong'};
  final _logBuffer = <(String, String)>[];
  Timer? _logTimer;

  void _recordMessage(String direction, Object? type) {
    if (scope.isEmpty || type is! String || _ignoredLogTypes.contains(type)) {
      return;
    }
    final key = 'message_log/$scope';
    final line = '${DateTime.now().toIso8601String()}  $direction  $type';
    _logBuffer.add((key, line));
    _logTimer ??= Timer(const Duration(seconds: 2), _flushLog);
  }

  Future<void> _flushLog() {
    _logTimer?.cancel();
    _logTimer = null;
    if (_logBuffer.isEmpty) return _logWrites;
    final entries = List<(String, String)>.from(_logBuffer);
    _logBuffer.clear();
    _logWrites = _logWrites
        .then((_) async {
          final preferences = await SharedPreferences.getInstance();
          final grouped = <String, List<String>>{};
          for (final (key, line) in entries) {
            (grouped[key] ??= []).add(line);
          }
          for (final group in grouped.entries) {
            final stored = preferences.getStringList(group.key) ?? [];
            stored.insertAll(0, group.value.reversed);
            if (stored.length > 200) stored.removeRange(200, stored.length);
            await preferences.setStringList(group.key, stored);
          }
        })
        .catchError((Object _) {});
    return _logWrites;
  }

  void logSession(String summary) => _recordMessage('产品会话', summary);

  Future<List<String>> messageLog() async {
    final key = 'message_log/$scope';
    await _flushLog();
    await _logWrites;
    final preferences = await SharedPreferences.getInstance();
    return preferences.getStringList(key) ?? [];
  }

  Future<void> clearMessageLog() {
    final key = 'message_log/$scope';
    _logTimer?.cancel();
    _logTimer = null;
    _logBuffer.clear();
    final cleared = _logWrites.then((_) async {
      final preferences = await SharedPreferences.getInstance();
      if (!await preferences.remove(key)) throw StateError('清除失败');
    });
    _logWrites = cleared.catchError((Object _) {});
    return cleared;
  }

  Uri? cashierUrl(String orderNo) {
    final service = _service;
    if (service == null || !RegExp(r'^GR[a-f0-9]{32}$').hasMatch(orderNo)) {
      return null;
    }
    return Uri.https(service.authority, '/cashier', {'order_no': orderNo});
  }

  Map user = {}, device = {}, wallet = {}, statistics = {};
  Map? resume;
  List<Map<String, dynamic>> products = [];
  String? productCode;
  String? productUrl;
  String? productName;
  bool productSelected = false;
  bool restoringProduct = false;
  final events = StreamController<Map>.broadcast(sync: true);
  bool serving = false;
  int _sequence = 0;
  final _pending = <String, Completer<Map>>{};
  Future<Map> request(String type, Map data) async {
    final socket = _socket;
    if (socket == null || !connected) throw StateError('设备未连接');
    final id = 'device-${++_sequence}';
    final response = Completer<Map>();
    _pending[id] = response;
    try {
      socket.add(
        jsonEncode({
          'id': id,
          'type': type,
          'data': data,
          'ts': DateTime.now().millisecondsSinceEpoch,
        }),
      );
      _recordMessage('发送', type);
      return await response.future.timeout(const Duration(seconds: 10));
    } finally {
      _pending.remove(id);
    }
  }

  void _cancelPending() {
    for (final request in _pending.values) {
      request.completeError(StateError('设备连接已结束'));
    }
    _pending.clear();
  }

  WebSocket? _socket;
  Timer? _heartbeat;
  Timer? _retry;
  int _generation = 0;
  int _failures = 0;

  void login(Uri uri, Map<String, String> credentials) {
    logout();
    _service = uri;
    scope = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              uri.toString(),
              credentials["username"],
              credentials["serial"],
            ]),
          ),
        )
        .toString();
    _connect(uri, credentials, _generation);
  }

  Future<void> _connect(
    Uri uri,
    Map<String, String> data,
    int generation,
  ) async {
    if (_generation != generation) return;
    status = '正在连接';
    notifyListeners();
    WebSocket? socket;
    final transport = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    Timer? authTimeout;
    var disconnectReason = '传输中断';
    DateTime? heartbeatSent;
    DateTime? lastPong;
    try {
      socket = await WebSocket.connect(uri.toString(), customClient: transport);
      if (_generation != generation) return;
      _socket = socket;
      socket.pingInterval = const Duration(seconds: 30);
      void send(String type, Map payload) {
        _recordMessage('发送', type);
        final now = DateTime.now();
        socket!.add(
          jsonEncode({
            'id': now.microsecondsSinceEpoch.toString(),
            'ts': now.millisecondsSinceEpoch,
            'type': type,
            'data': payload,
          }),
        );
      }

      send('auth', {
        ...data,
        if (productCode != null) 'product_code': productCode,
      });
      authTimeout = Timer(const Duration(seconds: 15), () {
        disconnectReason = '认证超时';
        unawaited(socket?.close());
      });
      await for (final raw in socket) {
        if (_generation != generation) return;
        final message = jsonDecode(raw as String);
        _recordMessage('接收', message['type']);
        if (message['type'] == 'pong') lastPong = DateTime.now();
        final pending = _pending.remove(message['reply_to']);
        if (pending != null) {
          if (message['type'] == 'error') {
            pending.completeError(
              StateError(message['data']['message'] ?? '请求失败'),
            );
          } else {
            pending.complete(Map.from(message['data']));
          }
          continue;
        }
        if (message['type'] == 'auth.error') {
          status = message['data']['message'] as String;
          _generation++;
          nickname = null;
          connected = false;
          notifyListeners();
          return;
        }
        if (message['type'] == 'auth.ok') {
          authTimeout.cancel();
          serving = message['data']['device']?['status'] == 1;
          _failures = 0;
          user = message['data']['user'];
          device = message['data']['device'] ?? {};
          wallet = Map.from(user);
          nickname = user['nickname'] ?? user['username'];
          settings = Map<String, dynamic>.from(message['data']['settings']);
          products = [
            for (final item
                in (message['data']['products'] as List? ?? const []))
              Map<String, dynamic>.from(item as Map),
          ];
          final product = message['data']['product'];
          if (product is Map) {
            productCode = product['code']?.toString();
            productUrl = product['url']?.toString();
            productName = product['name']?.toString();
            productSelected = true;
            settings = {
              ...settings,
              'product_code': product['code'],
              'product_origin': product['origin'],
              'script_url': product['script_url'],
            };
          } else {
            productCode = null;
            productUrl = null;
            productName = null;
            productSelected = false;
          }
          connected = true;
          status = '设备已连接';
          notifyListeners();
          if (!productSelected) unawaited(_restoreProduct(generation));
          _heartbeat?.cancel();
          void heartbeat() {
            final now = DateTime.now();
            final lastReply = lastPong ?? heartbeatSent;
            if (lastReply != null &&
                now.difference(lastReply).inSeconds >= 60) {
              disconnectReason = '应用心跳超时';
              _heartbeat?.cancel();
              unawaited(socket?.close());
              return;
            }
            heartbeatSent ??= now;
            send('heartbeat', {'ts': now.millisecondsSinceEpoch});
          }

          heartbeat();
          _heartbeat = Timer.periodic(
            const Duration(seconds: 20),
            (_) => heartbeat(),
          );
        } else {
          final type = message['type'];
          final payload = message['data'];
          if (type == 'order.resume') resume = payload;
          if (type == 'device.state') {
            device = {...device, ...payload};
            if (payload['reason'] case final String reason) {
              _recordMessage(
                '建单失败',
                "${payload['order_no']} 第 ${payload['attempt']} 次尝试 · $reason"
                    "（连续 ${payload['consecutive_failures']} 次）",
              );
            }
            notifyListeners();
          }
          if (type == 'wallet.update') wallet = Map.from(payload);
          if (type == 'stats.data') statistics = Map.from(payload);
          events.add(Map.from(message));
        }
      }
    } on Exception {
      // A transient transport failure uses the same retry path as a lost socket.
    } finally {
      authTimeout?.cancel();
      final code = socket?.closeCode;
      transport.close(force: true);
      unawaited(socket?.close() ?? Future<void>.value());
      if (generation == _generation) {
        _heartbeat?.cancel();
        _recordMessage('连接', '$disconnectReason · 关闭码 ${code ?? '无'}');
        _cancelPending();
        _socket = null;
        resume = null;
        connected = false;
        if (code == 1008) {
          nickname = null;
          settings = {};
          status = '连接授权已结束，请重新登录';
        } else if (_failures >= 5) {
          status = '连接失败，请检查网络';
        } else {
          const delays = [1, 2, 4, 8, 15];
          final delay = delays[_failures];
          _failures++;
          status = '连接中断，$delay 秒后重连';
          _retry = Timer(
            Duration(seconds: delay),
            () => _connect(uri, data, generation),
          );
        }
        notifyListeners();
      }
    }
  }

  Future<void> selectProduct(String code) async {
    final data = await request('product.select', {'code': code});
    final product = Map<String, dynamic>.from(data['product'] as Map);
    productCode = product['code']?.toString();
    productUrl = product['url']?.toString();
    productName = product['name']?.toString();
    productSelected = true;
    settings = {
      ...settings,
      'product_code': product['code'],
      'product_origin': product['origin'],
      'script_url': product['script_url'],
    };
    notifyListeners();
    unawaited(_rememberProduct(productCode ?? code));
  }

  static const _productKey = 'product_code';

  static Future<void> forgetProduct() async {
    try {
      await (await SharedPreferences.getInstance()).remove(_productKey);
    } catch (_) {}
  }

  Future<void> _rememberProduct(String code) async {
    try {
      await (await SharedPreferences.getInstance()).setString(
        _productKey,
        code,
      );
    } catch (_) {}
  }

  Future<void> _restoreProduct(int generation) async {
    String? saved;
    try {
      saved = (await SharedPreferences.getInstance()).getString(_productKey);
    } catch (_) {
      return;
    }
    if (saved == null ||
        !connected ||
        _generation != generation ||
        productSelected ||
        !products.any((product) => product['code']?.toString() == saved)) {
      return;
    }
    restoringProduct = true;
    notifyListeners();
    try {
      await selectProduct(saved);
    } catch (_) {
      // Keep the selection page when the saved product is unavailable.
    } finally {
      restoringProduct = false;
      notifyListeners();
    }
  }

  Future<void> updateDeviceSettings(
    bool accepting,
    int weight,
    int dailyLimit,
    int pendingLimit,
  ) async {
    final result = await request('device.set', {
      'status': accepting ? 1 : 0,
      'weight': weight,
      'daily_limit': dailyLimit,
      'pending_limit': pendingLimit,
    });
    serving = result['status'] == 1;
    device = {
      ...device,
      'status': result['status'],
      'weight': result['weight'],
      'daily_limit': result['daily_limit'],
      'pending_limit': result['pending_limit'],
    };
    notifyListeners();
  }

  Future<void> changePassword(String oldPassword, String newPassword) async {
    final username = user['username']?.toString() ?? '';
    await request('password.change', {
      'auth_digest': loginDigest(username, oldPassword),
      'new_password': md5.convert(utf8.encode(newPassword)).toString(),
    });
  }

  void logout() {
    _generation++;
    _cancelPending();
    _retry?.cancel();
    _heartbeat?.cancel();
    _socket?.close();
    _socket = null;
    _service = null;
    nickname = null;
    connected = false;
    settings = {};
    resume = null;
    statistics = {};
    wallet = {};
    products = [];
    productCode = null;
    productUrl = null;
    productName = null;
    productSelected = false;
    restoringProduct = false;
    status = '';
    _failures = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_flushLog());
    logout();
    events.close();
    super.dispose();
  }
}
