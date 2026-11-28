import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/network/ws_client.dart';
import '../webview/product_page.dart';
import 'product_select_page.dart';

/// 设备品牌型号，例如 `Xiaomi 23127PN0CC`；取不到时退回系统平台名。
Future<String> deviceModel() async {
  try {
    final model = await const MethodChannel(
      'grupay/session',
    ).invokeMethod<String>('model');
    if (model != null && model.trim().isNotEmpty) return model.trim();
  } catch (_) {}
  return Platform.operatingSystem;
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final client = WsClient();
  final fields = List.generate(3, (_) => TextEditingController());
  final vault = const FlutterSecureStorage();
  bool remember = false;
  bool loading = true;
  String error = '';
  Map<String, dynamic> saved = {};

  @override
  void initState() {
    super.initState();
    client.addListener(showConnectionFailure);
    restore();
  }

  bool showingConnectionFailure = false;

  void showConnectionFailure() {
    if (!client.connectionFailed || showingConnectionFailure) return;
    showingConnectionFailure = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (client.connectionFailed) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            content: const Text('连接失败，请检查网络'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('确定'),
              ),
            ],
          ),
        );
        if (mounted && client.connectionFailed) client.logout();
      }
      showingConnectionFailure = false;
    });
  }

  Future<void> restore() async {
    try {
      final raw = await vault.read(key: 'login');
      if (raw != null && mounted) {
        saved = jsonDecode(raw);
        fields[0].text = saved['username'];
        fields[1].text = saved['password'] as String? ?? '';
        fields[2].text = saved['server'];
        remember = true;
      }
    } catch (_) {
      error = '无法读取已保存的登录信息';
    }
    if (!mounted) return;
    setState(() => loading = false);
  }

  Future<void> submit() async {
    final name = fields[0].text;
    final password = fields[1].text;
    final uri = Uri.tryParse(fields[2].text.trim());
    final reused =
        saved['username'] == name &&
        saved['server'] == uri?.toString() &&
        saved['digest'] is String;
    if (name.isEmpty ||
        (password.isEmpty && !reused) ||
        uri == null ||
        uri.host.isEmpty ||
        uri.scheme != 'wss' ||
        uri.userInfo.isNotEmpty) {
      setState(() => error = '请填写账号、密码和 WSS 服务地址');
      return;
    }
    setState(() {
      loading = true;
      error = '';
    });
    try {
      final digest = password.isEmpty
          ? saved['digest'] as String
          : loginDigest(name, password);
      final prefs = await SharedPreferences.getInstance();
      var serial = prefs.getString('device_serial');
      if (serial == null) {
        final random = Random.secure();
        serial = List.generate(
          16,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
        await prefs.setString('device_serial', serial);
      }
      if (remember) {
        saved = {
          'username': name,
          'digest': digest,
          if (password.isNotEmpty) 'password': password,
          'server': uri.toString(),
        };
        await vault.write(key: 'login', value: jsonEncode(saved));
      } else {
        await vault.delete(key: 'login');
        saved = {};
      }
      if (!mounted) return;
      client.login(
        uri.path.isEmpty || uri.path == '/' ? uri.replace(path: '/ws') : uri,
        {
          'username': name,
          'auth_digest': digest,
          'serial': serial,
          'version': WsClient.appVersion,
          'model': await deviceModel(),
        },
      );
    } catch (_) {
      error = '设备信息保存失败，请重试';
    }
    if (mounted) setState(() => loading = false);
  }

  void signOut() {
    fields[1].clear();
    client.logout();
    saved = {};
    remember = false;
    unawaited(WsClient.forgetProduct());
    restore();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: client,
    builder: (context, _) {
      final connected = client.nickname != null;
      if (connected) {
        final productCode = client.productCode;
        final target = Uri.tryParse(client.productUrl ?? '');
        if (client.productSelected &&
            productCode != null &&
            target != null &&
            target.host.isNotEmpty) {
          return ProductPage(
            key: ValueKey((productCode, target)),
            target: target,
            client: client,
            logout: signOut,
          );
        }
        if (client.restoringProduct) {
          return const Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('正在恢复产品…'),
                ],
              ),
            ),
          );
        }
        return ProductSelectPage(client: client, logout: signOut);
      }
      const labels = ['账号', '密码', '服务器地址'];
      final busy = loading || client.status == '正在连接';
      return Stack(
        children: [
          Scaffold(
            appBar: AppBar(title: const Text('GruPay')),
            body: SafeArea(
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  for (var i = 0; i < 3; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: TextField(
                        controller: fields[i],
                        enabled: !loading,
                        obscureText: i == 1,
                        autocorrect: false,
                        decoration: InputDecoration(
                          labelText: labels[i],
                          hintText: i == 1 && saved.isNotEmpty
                              ? '使用已保存的凭据'
                              : null,
                        ),
                      ),
                    ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('记住登录信息'),
                    value: remember,
                    onChanged: loading
                        ? null
                        : (value) async {
                            setState(() => remember = value ?? false);
                            if (!remember) {
                              saved = {};
                              try {
                                await vault.delete(key: 'login');
                              } catch (_) {
                                if (mounted) {
                                  setState(() => error = '无法删除已保存的登录信息');
                                }
                              }
                            }
                          },
                  ),
                  FilledButton(
                    onPressed: busy ? null : submit,
                    child: const Text('登录服务'),
                  ),
                  if (error.isNotEmpty || (!busy && client.status.isNotEmpty))
                    Text(error.isNotEmpty ? error : client.status),
                ],
              ),
            ),
          ),
          if (busy)
            const Positioned.fill(
              child: Stack(
                children: [
                  ModalBarrier(dismissible: false, color: Colors.black38),
                  Center(
                    child: Card(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(),
                            SizedBox(height: 16),
                            Text('登录中…'),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      );
    },
  );

  @override
  void dispose() {
    client.removeListener(showConnectionFailure);
    client.dispose();
    for (final field in fields) {
      field.dispose();
    }
    super.dispose();
  }
}
