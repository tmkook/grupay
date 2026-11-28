import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../orders/order_runner.dart';
import '../orders/dashboard.dart';
import '../../core/network/ws_client.dart';
import '../../core/webview/injection_manager.dart';

class ProductPage extends StatefulWidget {
  const ProductPage({
    super.key,
    required this.target,
    required this.client,
    required this.logout,
  });
  final Uri target;
  final WsClient client;
  final VoidCallback logout;
  @override
  State<ProductPage> createState() => _ProductPageState();
}

class _ProductPageState extends State<ProductPage> with WidgetsBindingObserver {
  late final OrderRunner runner;
  late final StreamSubscription<Map> subscription;
  Future<Map> productCall(String method, List args) async {
    if (method != 'getPayUrl') return runProductScript(method, args);
    final previous = tab;
    try {
      if (!background && tab != Dashboard.siteTab) {
        Navigator.of(context)
            .popUntil((candidate) => candidate == ModalRoute.of(context));
        showBrowser();
        try {
          await WidgetsBinding.instance.endOfFrame.timeout(
            const Duration(seconds: 5),
          );
        } on TimeoutException {
          return {
            'ok': false,
            'outcome': 'confirmed_not_created',
            'reason': '产品页未能切换到前台',
          };
        }
      }
      if (!mounted || background || tab != Dashboard.siteTab) {
        return {
          'ok': false,
          'outcome': 'confirmed_not_created',
          'reason': '接单时产品页不在前台',
        };
      }
      return await runProductScript(method, args);
    } finally {
      if (mounted && account != null && previous != Dashboard.siteTab) {
        selectTab(previous);
      }
    }
  }

  Future<Map> runProductScript(String method, List args) async {
    final controller = view;
    if (controller == null || !authorized || !injected || account == null) {
      if (method == 'getPayUrl') {
        return {
          'ok': false,
          'outcome': 'confirmed_not_created',
          'reason': '接单时产品页或登录会话未就绪',
        };
      }
      throw StateError('产品页未就绪');
    }
    final result = await controller
        .callAsyncJavaScript(
          functionBody: r'''
if (location.href !== new URL(target).href) {
  return method === 'getPayUrl'
    ? {ok: false, outcome: 'confirmed_not_created', reason: '当前页面已离开充值页'}
    : null;
}
const product = window.grupay;
if (method === 'getPayUrl' && typeof product?.getPayUrl !== 'function') {
  return {ok: false, outcome: 'confirmed_not_created', reason: '充值脚本建单接口未就绪'};
}
if (method !== 'queryOrder' || typeof product.queryOrder === 'function') {
  return await product[method](...args);
}
const p = args[0];
const url = new URL(p.url, location.href);
if (url.origin !== location.origin) return null;
const verb = String(p.method || 'GET').toUpperCase();
if (!['GET', 'POST'].includes(verb)) return null;
const response = await fetch(url, {method: verb, headers: p.headers,
  body: verb === 'POST' ? p.body : undefined, credentials: 'same-origin',
  redirect: 'error', signal: AbortSignal.timeout(14000)});
return response.ok ? await response.json() : null;
''',
          arguments: {
            'target': widget.target.toString(),
            'method': method,
            'args': args,
          },
        )
        .timeout(const Duration(seconds: 15));
    if (result?.value is! Map || result?.error != null) {
      if (result?.error != null && mounted && controller == view) {
        noteJsError(result!.error.toString());
      }
      throw StateError('未取得产品结果');
    }
    return result!.value as Map;
  }

  final scripts = InjectionManager();
  InAppWebViewController? view;
  Timer? timer;
  int page = 0;
  int tab = 0;
  bool injected = false, checking = false;
  String? account;
  String? productName, productAvatar;
  String title = '产品浏览器', lastNotice = '';
  bool get homeVisible => tab != Dashboard.siteTab;

  void notice(String message) {
    if (!mounted || message == lastNotice) return;
    lastNotice = message;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  int visibilityEpoch = 0;
  bool returningToTarget = false;
  int missingProbes = 0;
  bool? lastSessionReady;

  Future<void> recordSession(bool ready) async {
    if (!Platform.isAndroid ||
        lastSessionReady == ready ||
        !(widget.target.host == 'douyin.com' ||
            widget.target.host.endsWith('.douyin.com'))) {
      return;
    }
    lastSessionReady = ready;
    final client = widget.client;
    final state = ready ? '检测到产品账号' : '未检测到产品账号';
    try {
      final sample = await const MethodChannel('grupay/session')
          .invokeMapMethod<String, dynamic>('snapshot', {'flush': ready});
      if (sample == null) return;
      final expires = sample['expiry'] as int?;
      final expiry = expires == null
          ? '无可读到期时间'
          : '最早到期 ${DateTime.fromMillisecondsSinceEpoch(expires * 1000).toLocal()}';
      client.logSession(
        "$state · Cookie ${sample['cookies']} 条 · 登录标记 ${sample['markers']} 条 · $expiry",
      );
    } catch (_) {
      client.logSession('$state · 会话元数据暂不可读');
    }
  }

  Future<void> restoreTarget(
    InAppWebViewController controller,
    int epoch,
  ) async {
    bool active() =>
        mounted &&
        epoch == visibilityEpoch &&
        identical(controller.platform, view?.platform);
    try {
      final url = await controller.getUrl();
      if (!active() || returningToTarget || url?.uriValue == widget.target) {
        return;
      }
      returningToTarget = true;
      await controller.loadUrl(
        urlRequest: URLRequest(url: WebUri(widget.target.toString())),
      );
    } catch (_) {
      if (active()) notice('无法返回配置的产品地址，请刷新重试');
    }
  }

  void selectTab(int next) {
    if (!mounted || tab == next) return;
    final leavingSite = tab == Dashboard.siteTab;
    setState(() => tab = next);
    visibilityEpoch++;
    returningToTarget = false;
    final controller = view;
    // 离开站点页时先把页面恢复到产品地址，回来时不会停在支付页或登录页。
    if (controller != null && leavingSite) {
      unawaited(restoreTarget(controller, visibilityEpoch));
    }
  }

  void openHome() {
    if (!mounted) return;
    selectTab(0);
  }

  void showBrowser() => selectTab(Dashboard.siteTab);

  bool get authorized =>
      widget.target.scheme == 'https' &&
      widget.target.origin == widget.client.settings['product_origin'];
  bool current(int generation) => mounted && page == generation;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 产品配置不完整时直接展示站点页，让用户看到地址不符的提示。
    if (!authorized) tab = Dashboard.siteTab;
    wasConnected = widget.client.connected;
    widget.client.addListener(connectionChanged);
    runner = OrderRunner(
      widget.client,
      productCall,
      () => injected && widget.client.connected ? account : null,
      reauth,
    );
    subscription = widget.client.events.stream.listen((message) {
      runner.receive(message['type'], message['data']);
    });
    if (widget.client.resume != null) {
      runner.receive('order.resume', widget.client.resume!);
    }
    unawaited(
      runner.start().catchError((Object _) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => notice('无法恢复本地执行记录'),
        );
      }),
    );
  }

  /// 上游判定登录态失效时，立即退出就绪状态并要求重新登录。
  Future<void> reauth() async {
    if (!mounted) return;
    setState(() {
      account = null;
      injected = false;
    });
    try {
      await widget.client.request('ready.set', {'ready': 0});
    } catch (_) {}
    if (!mounted) return;
    lastNotice = '';
    notice('产品登录已失效，请重新登录');
    view?.reload();
  }

  static const foregroundMessage = '接单时必须保持grupay在前台活跃';
  bool background = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      background = false;
    } else if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      background = true;
    }
  }

  bool wasConnected = false;

  void connectionChanged() {
    final connected = widget.client.connected;
    if (connected == wasConnected) return;
    wasConnected = connected;
    if (connected) unawaited(refreshReadiness());
  }

  Future<void> refreshReadiness() async {
    final controller = view;
    final resetState = reset();
    final generation = page;
    await resetState;
    if (!current(generation) || controller == null || !authorized) return;
    final url = await controller.getUrl();
    if (current(generation) && url?.uriValue == widget.target) {
      await inspect(generation);
    }
  }

  Future<void> reset() async {
    missingProbes = 0;
    final generation = ++page;
    timer?.cancel();
    injected = false;
    checking = false;
    setState(() => account = null);
    try {
      await widget.client.request('ready.set', {'ready': 0});
    } catch (_) {
      if (current(generation) && account == null) notice('设备状态同步失败');
    }
  }

  final jsErrors = <String>[];
  bool ignoredWasmPolicy = false;

  void noteJsError(String message) {
    final line = message.trim();
    if (line.isEmpty) return;
    jsErrors.add(line.length > 300 ? '${line.substring(0, 300)}…' : line);
    if (jsErrors.length > 10) jsErrors.removeAt(0);
  }

  Future<void> showScriptStatus() async {
    final controller = view;
    final generation = page;
    String state = '浏览器尚未就绪', version = '—';
    if (controller != null && authorized) {
      try {
        final result = await controller
            .callAsyncJavaScript(
              functionBody: r"""
if (location.href !== new URL(target).href) return { state: '当前页面不是配置的产品页' };
const api = window.grupay;
if (!api) return { state: '未检测到注入脚本' };
const missing = ['getUserInfo','getPayUrl','getProcessUrl'].filter(k => typeof api[k] !== 'function');
return { state: missing.length ? '缺少接口：' + missing.join(', ') : '已注入，接口就绪',
         version: typeof api.version === 'string' ? api.version.slice(0, 80) : null };
""",
              arguments: {'target': widget.target.toString()},
            )
            .timeout(const Duration(seconds: 5));
        final data = result?.value;
        if (result?.error != null || data is! Map) {
          state = '无法读取脚本状态';
        } else {
          state = data['state'] as String;
          version =
              data['version'] as String? ??
              (state.startsWith('已注入') ? '脚本未声明版本' : '—');
        }
      } catch (_) {
        state = '检查失败，请重试';
      }
    }
    if (!mounted) return;
    if (!current(generation) || controller != view) {
      state = '页面已切换，请重新检查';
      version = '—';
    }
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('脚本检查'),
        content: SingleChildScrollView(
          child: SelectableText(
            '注入状态　$state\n脚本版本　$version\n\n本页 JS 错误\n${jsErrors.isEmpty ? '尚未捕获到错误' : jsErrors.reversed.join('\n\n')}${ignoredWasmPolicy ? '\n\n浏览器兼容提示\n当前 WebView 忽略了页面策略中的 wasm-unsafe-eval。' : ''}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> inspect(int generation) async {
    final controller = view;
    if (!current(generation) || controller == null || checking) return;
    checking = true;
    final target = jsonEncode(widget.target.toString());
    try {
      if (!injected) {
        final source = await scripts
            .load(widget.client.settings['script_url'] as String?)
            .timeout(const Duration(seconds: 15));
        if (!current(generation)) return;
        await controller.evaluateJavascript(
          source: 'if (location.href === new URL($target).href) {\n$source\n}',
        );
        if (!current(generation)) return;
        injected = true;
      }
      final probe = await controller
          .callAsyncJavaScript(
            functionBody:
                'if(location.href !== new URL($target).href) return null; return await window.grupay.getUserInfo();',
          )
          .timeout(const Duration(seconds: 15));
      if (!current(generation)) return;
      if (probe?.error != null || probe?.value is! Map) {
        if (probe?.error != null) noteJsError(probe!.error.toString());
        throw StateError('产品登录检测失败');
      }
      final result = probe!.value as Map;
      final data = result['data'];
      final uid = result['ok'] == true && data is Map
          ? data['uid']?.toString()
          : null;
      final next = uid == null || uid.trim().isEmpty ? null : uid;
      missingProbes = next == null ? missingProbes + 1 : 0;
      if (next != null || missingProbes >= 2) {
        unawaited(recordSession(next != null));
      }
      if (next != account) {
        await widget.client.request('ready.set', {
          'ready': next == null ? 0 : 1,
          'account': ?next,
        });
        if (!current(generation)) return;
      }
      lastNotice = '';
      setState(() {
        account = next;
        if (next != null) {
          productName = data['name'] as String?;
          productAvatar = data['avatar'] as String?;
        }
      });
    } catch (e) {
      if (!current(generation)) return;
      missingProbes = 0;
      injected = false;
      setState(() => account = null);
      notice(e is FormatException ? e.message : '检测失败，稍后重试');
      try {
        await widget.client.request('ready.set', {'ready': 0});
      } catch (_) {}
    } finally {
      if (current(generation)) {
        checking = false;
        timer?.cancel();
        timer = Timer(const Duration(seconds: 5), () => inspect(generation));
      }
    }
  }

  int historyGeneration = 0;
  bool clearing = false;
  Future<void> clearBrowserData() async {
    final controller = view;
    if (controller == null || clearing) return;
    final selected = {'缓存', '会话', '历史记录'};
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: const Text('清除浏览器数据'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final entry in const {
                '缓存': '浏览器缓存的网页资源',
                '会话': '清除网页 Cookie 和站点存储，需要重新登录网站',
                '历史记录': '清除产品浏览器的前进和后退记录',
              }.entries)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(entry.key),
                  subtitle: Text(entry.value),
                  value: selected.contains(entry.key),
                  onChanged: (v) => update(() {
                    if (v == true) {
                      selected.add(entry.key);
                    } else {
                      selected.remove(entry.key);
                    }
                  }),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.pop(ctx, true),
              child: const Text('清除'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted || controller != view) return;
    final messenger = ScaffoldMessenger.of(context);
    if (widget.client.serving || runner.tasks.isNotEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('请先暂停接单并等待在途任务结束')));
      return;
    }
    clearing = true;
    try {
      if (selected.contains('缓存')) await InAppWebViewController.clearAllCache();
      if (selected.contains('会话')) {
        await reset();
        await CookieManager.instance().deleteAllCookies();
        if (Platform.isAndroid) {
          await WebStorageManager.instance().deleteAllData();
        } else {
          await WebStorageManager.instance().removeDataModifiedSince(
            dataTypes: {
              WebsiteDataType.WKWebsiteDataTypeLocalStorage,
              WebsiteDataType.WKWebsiteDataTypeSessionStorage,
              WebsiteDataType.WKWebsiteDataTypeIndexedDBDatabases,
            },
            date: DateTime.fromMillisecondsSinceEpoch(0),
          );
        }
      }
      if (!mounted) return;
      if (selected.contains('历史记录') || selected.contains('会话')) {
        if (selected.contains('历史记录') && Platform.isAndroid) {
          await controller.clearHistory();
        }
        if (selected.contains('会话') || !Platform.isAndroid) {
          if (selected.contains('历史记录')) {
            setState(() {
              view = null;
              historyGeneration++;
            });
          } else {
            await controller.reload();
          }
        }
      }
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('已清除${selected.join('、')}')),
        );
      }
    } catch (_) {
      if (mounted) {
        messenger.showSnackBar(const SnackBar(content: Text('未能完成清除，请重试')));
      }
    } finally {
      clearing = false;
    }
  }

  Future<void> showUa() async {
    String systemUa;
    try {
      systemUa = await InAppWebViewController.getDefaultUserAgent();
    } catch (_) {
      systemUa = '系统 UA 暂时无法读取';
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('系统 WebView UA'),
        content: SingleChildScrollView(child: SelectableText(systemUa)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (popped, _) {
      if (popped) return;
      if (tab != 0) {
        selectTab(0);
      } else if (widget.client.serving && account != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text(foregroundMessage)));
      }
    },
    child: Dashboard(
      client: widget.client,
      showUa: showUa,
      onLogout: widget.logout,
      active: () => runner.tasks.length,
      productReady: account != null && injected,
      productProfile: () =>
          account == null ? (null, null) : (productName, productAvatar),
      recheck: runner.recheck,
      canStart: () => authorized && widget.client.device['version_ok'] != false,
      tab: tab,
      onTabSelected: selectTab,
      browser: buildBrowser(context),
    ),
  );

  Widget buildBrowser(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        centerTitle: true,
        actions: [
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (value) async {
              final controller = view;
              switch (value) {
                case 'clear':
                  clearBrowserData();
                case 'script':
                  await showScriptStatus();
                case 'refresh':
                  view?.reload();
                case 'back':
                  if (await controller?.canGoBack() == true &&
                      controller == view) {
                    await controller?.goBack();
                  }
                case 'forward':
                  if (await controller?.canGoForward() == true &&
                      controller == view) {
                    await controller?.goForward();
                  }
                case 'ua':
                  showUa();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'refresh', child: Text('刷新')),
              PopupMenuItem(value: 'back', child: Text('后退')),
              PopupMenuItem(value: 'forward', child: Text('前进')),
              PopupMenuItem(value: 'script', child: Text('脚本')),
              PopupMenuItem(value: 'ua', child: Text('设备 UA')),
              PopupMenuItem(value: 'clear', child: Text('清除数据')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (!authorized)
              const ListTile(
                title: Text('产品地址与服务端配置不符'),
                subtitle: Text('请核对产品地址和 product_origin 配置'),
              )
            else
              Expanded(
                child: InAppWebView(
                  key: ValueKey(historyGeneration),
                  initialUrlRequest: URLRequest(
                    url: WebUri(widget.target.toString()),
                  ),
                  initialSettings: InAppWebViewSettings(isInspectable: false),
                  onWebViewCreated: (c) => view = c,
                  onConsoleMessage: (c, message) {
                    if (!identical(c.platform, view?.platform)) return;
                    if (message.message.contains("wasm-unsafe-eval") &&
                        message.message.contains(
                          "contains an invalid source",
                        ) &&
                        message.message.contains("will be ignored")) {
                      ignoredWasmPolicy = true;
                    } else if (message.messageLevel ==
                        ConsoleMessageLevel.ERROR) {
                      noteJsError(message.message);
                    }
                  },
                  onLoadStart: (c, url) {
                    if (identical(c.platform, view?.platform)) {
                      jsErrors.clear();
                      ignoredWasmPolicy = false;
                      reset();
                    }
                  },
                  onUpdateVisitedHistory: (c, url, _) {
                    if (!mounted || !identical(c.platform, view?.platform)) {
                      return;
                    }
                    if (url?.uriValue != widget.target) {
                      if (injected || checking || account != null) {
                        unawaited(reset());
                      }
                      if (homeVisible) {
                        unawaited(restoreTarget(c, visibilityEpoch));
                      }
                    } else if (!injected && !checking) {
                      // Same-document navigation may have no subsequent load-stop event.
                      timer?.cancel();
                      final generation = page;
                      timer = Timer(
                        const Duration(milliseconds: 500),
                        () => inspect(generation),
                      );
                    }
                  },
                  onLoadStop: (c, url) async {
                    if (!identical(c.platform, view?.platform) || !mounted) {
                      return;
                    }
                    if (homeVisible && url?.uriValue != widget.target) {
                      if (returningToTarget) {
                        // Keep redirects hidden until the user asks to start accepting orders.
                        if (url != await c.getUrl() ||
                            !mounted ||
                            !homeVisible) {
                          return;
                        }
                        return;
                      } else {
                        await restoreTarget(c, visibilityEpoch);
                        return;
                      }
                    }
                    returningToTarget = false;
                    if (url?.uriValue != widget.target) {
                      await reset();
                      return;
                    }
                    await inspect(page);
                  },
                  onTitleChanged: (c, value) {
                    if (mounted && identical(c.platform, view?.platform)) {
                      setState(
                        () => title = value?.trim().isNotEmpty == true
                            ? value!
                            : '产品浏览器',
                      );
                    }
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.client.removeListener(connectionChanged);
    page++;
    timer?.cancel();
    runner.dispose();
    subscription.cancel();
    scripts.dispose();
    super.dispose();
  }
}
