import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/network/ws_client.dart';
import '../../core/screen_guard.dart';

class Dashboard extends StatefulWidget {
  const Dashboard({
    super.key,
    required this.client,
    required this.showUa,
    required this.onLogout,
    required this.active,
    required this.canStart,
    this.recheck,
    this.productReady = false,
    this.productProfile,
    required this.tab,
    required this.onTabSelected,
    this.browser,
  });
  static const siteTab = 1;
  static const _statsTab = 2;

  final WsClient client;
  final Future<void> Function() showUa;
  final VoidCallback onLogout;
  final int Function() active;
  final bool Function() canStart;
  final Future<String> Function(Map)? recheck;
  final bool productReady;
  final (String?, String?) Function()? productProfile;
  final int tab;
  final ValueChanged<int> onTabSelected;
  final Widget? browser;
  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  static const statuses = {
    'created': '排队中',
    'assigned': '排队中',
    'placing': '进行中',
    'placed': '进行中',
    'paid': '已完成',
    'expired': '已超时',
    'failed': '已失败',
  };
  static const colors = {
    'created': Color(0xFF956018),
    'assigned': Color(0xFF956018),
    'placing': Color(0xFF426CA1),
    'placed': Color(0xFF426CA1),
    'paid': Color(0xFF38704F),
    'expired': Color(0xFF956018),
    'failed': Color(0xFFAA414B),
  };
  final scroll = ScrollController();
  final orders = <Map>[];
  final rechecking = <Object?>{};
  final pendingUpdates = <String, Map>{};
  Map deviceTotals = {}, accountTotals = {};
  List<Map> deviceHistory = [], accountHistory = [];
  bool showAccount = false;
  int epoch = 0;
  int? cursor;
  bool loading = false, switching = false;
  String error = '', statsError = '';
  int statsEpoch = 0;
  late bool wasConnected;
  late StreamSubscription<Map> subscription;
  Timer? midnight;
  @override
  void initState() {
    super.initState();
    scroll.addListener(() {
      if (widget.tab == 0 &&
          !loading &&
          cursor != null &&
          scroll.position.extentAfter < 160) {
        refresh(more: true);
      }
    });
    wasConnected = widget.client.connected;
    widget.client.addListener(connection);
    subscription = widget.client.events.stream.listen((message) {
      if (!mounted) return;
      if (message['type'] == 'order.update') {
        final update = Map.from(message['data']);
        if (loading) pendingUpdates[update['order_no']] = update;
        setState(() => merge(update));
        return;
      }
      if (message['type'] == 'stats.data') {
        setState(() => deviceTotals = message['data']);
      } else if (message['type'] == 'stats.account') {
        setState(() => accountTotals = message['data']);
      }
      if (message['type'] == 'wallet.update') setState(() {});
    });
    refresh();
    void scheduleDay() {
      final now = DateTime.now().toUtc().add(const Duration(hours: 8));
      final end = DateTime.utc(now.year, now.month, now.day + 1);
      midnight = Timer(end.difference(now), () {
        if (mounted) {
          refresh();
          scheduleDay();
        }
      });
    }

    scheduleDay();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && defaultTargetPlatform == TargetPlatform.android) {
        unawaited(checkUpdate(automatic: true));
      }
    });
  }

  void connection() {
    final reconnected = !wasConnected && widget.client.connected;
    wasConnected = widget.client.connected;
    if (reconnected && mounted) {
      unawaited(refresh());
    }
    if (widget.client.nickname == null && mounted) {
      Navigator.of(context).popUntil((r) => r.isFirst);
    } else if (mounted) {
      setState(() {});
    }
  }

  void merge(Map update) {
    final index = orders.indexWhere(
      (item) => item['order_no'] == update['order_no'],
    );
    if (index >= 0 && orders[index]['revision'] > update['revision']) return;
    if (index >= 0) orders.removeAt(index);
    if (update['removed'] != true) {
      orders.add(update);
      orders.sort((a, b) => (b['id'] as int).compareTo(a['id'] as int));
    }
  }

  Future<void> refresh({bool more = false}) async {
    final token = ++epoch;
    if (!more) unawaited(refreshStats());
    pendingUpdates.clear();
    setState(() {
      loading = true;
      error = '';
    });
    try {
      final result = await widget.client.request('order.list', {
        'limit': 20,
        if (more) 'before_id': cursor,
      });
      if (!mounted || token != epoch) return;
      setState(() {
        if (!more) orders.clear();
        for (final row in List<Map>.from(result['orders'])) {
          merge(row);
        }
        for (final row in pendingUpdates.values) {
          merge(row);
        }
        cursor = result['next_before_id'];
      });
    } catch (_) {
      if (mounted && token == epoch) setState(() => error = '读取失败，请重试');
    } finally {
      if (mounted && token == epoch) setState(() => loading = false);
    }
  }

  Future<void> refreshStats() async {
    final token = ++statsEpoch;
    try {
      final summary = await widget.client.request('stats.get', {
        'history': true,
      });
      if (!mounted || token != statsEpoch) return;
      setState(() {
        deviceTotals = summary;
        accountTotals = summary['account'] as Map? ?? {};
        deviceHistory = List<Map>.from(summary['device_history'] ?? []);
        accountHistory = List<Map>.from(summary['account_history'] ?? []);
        statsError = '';
      });
    } catch (_) {
      if (mounted && token == statsEpoch) {
        setState(() => statsError = '统计读取失败，点击重试');
      }
    }
  }

  void message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  Future<void> recheckOrder(Map order) async {
    final no = order['order_no'];
    setState(() => rechecking.add(no));
    try {
      final result = await widget.recheck!(order);
      if (mounted) message(result);
    } catch (_) {
      if (mounted) message('查单失败，请稍后重试');
    } finally {
      if (mounted) setState(() => rechecking.remove(no));
    }
  }

  Future<void> copy(String? value) async {
    if (value == null || value.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) message('已复制');
  }

  void openMessageLog() {
    var messages = widget.client.messageLog();
    var clearing = false;
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => StatefulBuilder(
          builder: (context, update) => Scaffold(
            appBar: AppBar(
              title: const Text('消息日志'),
              actions: [
                IconButton(
                  tooltip: '清除日志',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: clearing
                      ? null
                      : () async {
                          update(() => clearing = true);
                          try {
                            await widget.client.clearMessageLog();
                            if (context.mounted) {
                              update(
                                () => messages = widget.client.messageLog(),
                              );
                            }
                          } catch (_) {
                            if (context.mounted) message('清除失败，请重试');
                          } finally {
                            if (context.mounted) update(() => clearing = false);
                          }
                        },
                ),
              ],
            ),
            body: FutureBuilder<List<String>>(
              future: messages,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Center(child: Text('无法读取消息日志'));
                }
                final entries = snapshot.data;
                if (entries == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (entries.isEmpty) return const Center(child: Text('暂无消息'));
                return ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: entries.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, index) => ListTile(
                    title: SelectableText(formatLog(entries[index])),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Future<void> openOrder(Uri url) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) {
          var loading = true;
          var failed = false;
          InAppWebViewController? controller;
          return StatefulBuilder(
            builder: (context, update) => Scaffold(
              appBar: AppBar(
                centerTitle: true,
                title: const Text('订单收银台'),
                leading: IconButton(
                  tooltip: '关闭收银台',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ),
              body: SafeArea(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    InAppWebView(
                      initialUrlRequest: URLRequest(
                        url: WebUri(url.toString()),
                      ),
                      initialSettings: InAppWebViewSettings(
                        useHybridComposition: false,
                        incognito: Platform.isIOS,
                        cacheEnabled: false,
                        thirdPartyCookiesEnabled: false,
                        isInspectable: false,
                      ),
                      onWebViewCreated: (view) => controller = view,
                      onLoadStart: (_, _) {
                        if (context.mounted) {
                          update(() {
                            loading = true;
                            failed = false;
                          });
                        }
                      },
                      onLoadStop: (_, _) {
                        if (context.mounted) update(() => loading = false);
                      },
                      onReceivedError: (_, request, _) {
                        if (request.isForMainFrame == true && context.mounted) {
                          update(() {
                            loading = false;
                            failed = true;
                          });
                        }
                      },
                      onReceivedHttpError: (_, request, _) {
                        if (request.isForMainFrame == true && context.mounted) {
                          update(() {
                            loading = false;
                            failed = true;
                          });
                        }
                      },
                    ),
                    if (loading || failed)
                      ColoredBox(
                        color: Theme.of(context).colorScheme.surface,
                        child: Center(
                          child: failed
                              ? TextButton(
                                  onPressed: () => controller?.reload(),
                                  child: const Text('订单页面加载失败，点击重试'),
                                )
                              : const Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    CircularProgressIndicator(),
                                    SizedBox(height: 16),
                                    Text('订单加载中…'),
                                  ],
                                ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  String dateLabel(DateTime date) {
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${date.year}-${pad(date.month)}-${pad(date.day)} ${pad(date.hour)}:${pad(date.minute)}:${pad(date.second)}';
  }

  String formatLog(String entry) {
    final split = entry.indexOf('  ');
    if (split < 0) return entry;
    final date = DateTime.tryParse(entry.substring(0, split));
    return date == null
        ? entry
        : '${dateLabel(date.toLocal())}  ${entry.substring(split).trimLeft()}';
  }

  void showOrderDetails(Map order) {
    final fields = <String, String>{
      '平台订单号': order['order_no'],
      '商户名': order['merchant_name'] ?? '—',
      '商户订单号': order['merchant_order_no'] ?? '—',
      '状态': statuses[order['status']] ?? '未知',
      if (order['fail_reason'] case final String reason) '原因': reason,
      '金额': "${order['amount']} 元",
      '查单次数': "${order['query_count'] ?? 0} 次",
      for (final e in const {
        'created_at': '创建时间',
        'placed_at': '建单时间',
        'deadline_at': '支付截止',
        'paid_at': '支付时间',
        'expired_at': '超时时间',
      }.entries)
        if (order[e.key] is int)
          e.value: dateLabel(DateTime.fromMillisecondsSinceEpoch(order[e.key])),
    };
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('订单详情', style: Theme.of(context).textTheme.titleLarge),
              for (final e in fields.entries)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(e.key),
                  subtitle: SelectableText(e.value),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget orderCard(Map order) {
    final theme = Theme.of(context);
    final status = order['status'];
    final checks = order['query_count'] ?? 0;
    final accent = colors[status] ?? theme.colorScheme.primary;
    final time = DateTime.fromMillisecondsSinceEpoch(order['created_at']);
    String padded(int value) => value.toString().padLeft(2, '0');
    final timestamp =
        '${time.month}月${time.day}日 ${padded(time.hour)}:${padded(time.minute)}';
    final checking = rechecking.contains(order['order_no']);
    final cashier = widget.client.cashierUrl('${order['order_no']}');
    final secondary = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: cashier == null ? null : () => openOrder(cashier),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: accent,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${statuses[status] ?? status}',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '查单 $checks 次',
                      style: theme.textTheme.labelLarge,
                    ),
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "${order['amount']}",
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 2),
                      Text('元', style: theme.textTheme.labelSmall),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Text(
                      "${order['order_no']}",
                      overflow: TextOverflow.ellipsis,
                      style: secondary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        order['merchant_name'] ?? '—',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: secondary,
                      ),
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  Expanded(child: Text(timestamp, style: secondary)),
                  TextButton(
                    onPressed: () => showOrderDetails(order),
                    child: const Text('详情'),
                  ),
                  TextButton(
                    onPressed: () => copy(order['order_no']),
                    child: const Text('复制'),
                  ),
                  TextButton(
                    onPressed:
                        checking ||
                            !widget.client.connected ||
                            widget.recheck == null
                        ? null
                        : () => recheckOrder(order),
                    child: Text(checking ? '查询中' : '查单'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final balance = widget.client.wallet['balance'] ?? 0,
        frozen = widget.client.wallet['frozen'] ?? 0;
    final days = [
      showAccount ? accountTotals : deviceTotals,
      ...(showAccount ? accountHistory : deviceHistory),
    ];
    final reconnecting =
        widget.client.nickname != null && !widget.client.connected;
    // 与派单条件保持一致，逐项展示首个不满足的原因。
    final dispatchState = !widget.productReady
        ? '产品账号未登录'
        : !widget.client.serving
        ? '已暂停接单'
        : widget.client.device['version_ok'] == false
        ? '客户端版本过低'
        : '接单中';
    final statusColor = reconnecting
        ? const Color(0xFF956018)
        : switch (dispatchState) {
            '接单中' => const Color(0xFF38704F),
            '已暂停接单' => const Color(0xFF956018),
            '客户端版本过低' => const Color(0xFFAA414B),
            _ => const Color(0xFF58646E),
          };
    final (productName, productAvatar) =
        widget.productProfile?.call() ?? (null, null);
    final name = productName?.trim();
    final nickname = name == null || name.isEmpty ? '未登录' : name;
    final avatarValue = productAvatar;
    final avatar = avatarValue is String ? Uri.tryParse(avatarValue) : null;
    final labels = {
      'received': '接单数',
      'paid': '成功数',
      'failed': '失败数',
      'expired': '超时数',
      'completed': '完成数',
      'in_progress': '进行中',
      'total_amount': '总金额（元）',
      'paid_amount': '成功金额（元）',
    };
    return Scaffold(
      appBar: widget.tab == Dashboard.siteTab
          ? null
          : widget.tab == 0
          ? AppBar(
              automaticallyImplyLeading: false,
              toolbarHeight: 72,
              title: Row(
                children: [
                  CircleAvatar(
                    foregroundImage:
                        avatar != null &&
                            avatar.scheme == 'https' &&
                            avatar.hasAuthority
                        ? NetworkImage(avatar.toString())
                        : null,
                    child: Text(nickname.characters.firstOrNull ?? '?'),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(nickname, overflow: TextOverflow.ellipsis),
                        Text(
                          reconnecting ? '重新连接中…' : dispatchState,
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(color: statusColor),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            )
          : AppBar(
              title: Text(widget.tab == Dashboard._statsTab ? '统计' : '设置'),
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: widget.tab,
        onDestinationSelected: (i) {
          if (i == Dashboard._statsTab && widget.tab != i) {
            unawaited(refreshStats());
          }
          widget.onTabSelected(i);
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), label: '主页'),
          NavigationDestination(icon: Icon(Icons.language), label: '站点'),
          NavigationDestination(icon: Icon(Icons.bar_chart), label: '统计'),
          NavigationDestination(icon: Icon(Icons.settings), label: '设置'),
        ],
      ),
      body: IndexedStack(
        index: widget.tab,
        children: [
          RefreshIndicator(
            onRefresh: refresh,
            child: ListView(
              controller: scroll,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              children: [
                if (loading) const LinearProgressIndicator(),
                if (error.isNotEmpty)
                  TextButton(onPressed: refresh, child: Text(error)),
                if (orders.isEmpty && !loading && error.isEmpty)
                  const ListTile(title: Text('暂无订单')),
                for (final order in orders) orderCard(order),
                if (cursor != null)
                  TextButton(
                    onPressed: loading ? null : () => refresh(more: true),
                    child: const Text('加载更多'),
                  ),
              ],
            ),
          ),
          widget.browser ?? const SizedBox.shrink(),
          RefreshIndicator(
            onRefresh: refreshStats,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              children: [
                if (statsError.isNotEmpty)
                  TextButton(onPressed: refreshStats, child: Text(statsError)),
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(
                    selectedBackgroundColor: Theme.of(context)
                        .colorScheme
                        .primary,
                    selectedForegroundColor: Theme.of(context)
                        .colorScheme
                        .onPrimary,
                    foregroundColor: Theme.of(context).colorScheme.primary,
                    side: BorderSide(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  segments: const [
                    ButtonSegment(value: false, label: Text('本机统计')),
                    ButtonSegment(value: true, label: Text('全部统计')),
                  ],
                  selected: {showAccount},
                  onSelectionChanged: (value) =>
                      setState(() => showAccount = value.single),
                ),
                for (final totals in days) ...[
                  const SizedBox(height: 12),
                  Card(
                    child: Column(
                      children: [
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.surface,
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(14),
                            ),
                          ),
                          child: Text(
                            '${totals['date'] ?? '—'} · ${showAccount ? '账号全部设备' : '本机'}',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.primary,
                              fontSize: 19,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: LayoutBuilder(
                            builder: (context, box) => Wrap(
                              spacing: 12,
                              runSpacing: 16,
                              children: [
                                for (final e in labels.entries)
                                  SizedBox(
                                    width: (box.maxWidth - 12) / 2,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          e.value,
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelMedium,
                                        ),
                                        Text(
                                          '${totals[e.key] ?? '—'}',
                                          style: Theme.of(context)
                                              .textTheme
                                              .headlineSmall
                                              ?.copyWith(
                                                fontWeight: FontWeight.w600,
                                              ),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 8, 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.client.user['username']?.toString() ??
                                  widget.client.nickname ??
                                  '',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 20,
                              children: [
                                Text('余额 $balance 元'),
                                Text('冻结 $frozen 元'),
                              ],
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: '退出登录',
                        onPressed: () async {
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('退出当前账号？'),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: const Text('取消'),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: const Text('退出'),
                                ),
                              ],
                            ),
                          );
                          if (mounted && confirmed == true) widget.onLogout();
                        },
                        icon: const Icon(Icons.logout),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Column(
                children: [
                  if (ScreenGuard.of(context) case final guard?)
                    ValueListenableBuilder(
                      valueListenable: guard.enabled,
                      builder: (_, enabled, _) => SwitchListTile(
                        title: const Text('息屏保护'),
                        subtitle: const Text('开启后保持唤醒，闲置 10 分钟后变暗，点按恢复'),
                        value: enabled,
                        onChanged: guard.setEnabled,
                      ),
                    ),
                  const Divider(height: 1),
                  ListTile(
                    title: const Text('接单设置'),
                    subtitle: const Text('接单状态、设备日限额与权重'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: openDispatchSettings,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    title: const Text('修改密码'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: openPassword,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    title: const Text('浏览器 UA'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: widget.showUa,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    title: const Text('消息日志'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: openMessageLog,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    title: const Text('关于'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: openAbout,
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  void openDispatchSettings() {
    var dailyLimit = '${widget.client.device['daily_limit'] ?? 0}';
    var weight = '${widget.client.device['weight'] ?? 1}';
    var pendingLimit = '${widget.client.device['pending_limit'] ?? 5}';
    var accepting = widget.client.serving;
    var saving = false;
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => StatefulBuilder(
          builder: (context, update) => Scaffold(
            appBar: AppBar(title: const Text('接单设置')),
            bottomNavigationBar: SafeArea(
              minimum: const EdgeInsets.all(16),
              child: FilledButton(
                onPressed: saving
                    ? null
                    : () async {
                        final limitValue = int.tryParse(dailyLimit);
                        final weightValue = int.tryParse(weight);
                        final pendingValue = int.tryParse(pendingLimit);
                        if (limitValue == null ||
                            limitValue < 0 ||
                            weightValue == null ||
                            weightValue < 0 ||
                            pendingValue == null ||
                            pendingValue < 0) {
                          message('日限额、权重和未完成上限必须是非负整数');
                          return;
                        }
                        if (accepting && !widget.canStart()) {
                          message('请核对产品地址与应用版本后接单');
                          return;
                        }
                        setState(() => switching = true);
                        update(() => saving = true);
                        try {
                          await widget.client.updateDeviceSettings(
                            accepting,
                            weightValue,
                            limitValue,
                            pendingValue,
                          );
                          if (!context.mounted) return;
                          Navigator.pop(context);
                          message('接单设置已保存');
                        } catch (error) {
                          message('$error'.replaceFirst('Bad state: ', ''));
                        } finally {
                          if (mounted) setState(() => switching = false);
                          if (context.mounted) {
                            update(() => saving = false);
                          }
                        }
                      },
                child: Text(saving ? '保存中…' : '保存设置'),
              ),
            ),
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: Column(
                    children: [
                      SwitchListTile(
                        title: const Text('接单开关'),
                        subtitle: Text(accepting ? '接单中' : '已暂停接单'),
                        value: accepting,
                        onChanged: saving
                            ? null
                            : (enabled) => update(() => accepting = enabled),
                      ),
                      const Divider(height: 1),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: [
                            TextFormField(
                              initialValue: dailyLimit,
                              onChanged: (value) => dailyLimit = value,
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                              ],
                              decoration: const InputDecoration(
                                labelText: '设备日限额（元）',
                                helperText: '0 表示不限，按北京时间统计当日派单金额',
                              ),
                            ),
                            const SizedBox(height: 16),
                            TextFormField(
                              initialValue: weight,
                              onChanged: (value) => weight = value,
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                              ],
                              decoration: const InputDecoration(
                                labelText: '设备权重',
                                helperText: '默认 1；权重越高越优先，0 仍可接单',
                              ),
                            ),
                            const SizedBox(height: 16),
                            TextFormField(
                              initialValue: pendingLimit,
                              onChanged: (value) => pendingLimit = value,
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                              ],
                              decoration: const InputDecoration(
                                labelText: '未完成订单上限（笔）',
                                helperText: '默认 5，0 表示不限；含进行中与待支付订单',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '登录产品账号后默认接单。暂停只影响后续派单，进行中的订单仍需完成。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void openPassword() {
    final old = TextEditingController();
    final fresh = TextEditingController();
    final confirm = TextEditingController();
    var saving = false;
    Navigator.of(context)
        .push<void>(
          MaterialPageRoute(
            builder: (_) => StatefulBuilder(
              builder: (context, update) => Scaffold(
                appBar: AppBar(title: const Text('修改密码')),
                bottomNavigationBar: SafeArea(
                  minimum: const EdgeInsets.all(16),
                  child: FilledButton(
                    onPressed: saving
                        ? null
                        : () async {
                            final oldValue = old.text;
                            final newValue = fresh.text;
                            if (newValue.length < 6) {
                              message('新密码至少 6 位');
                              return;
                            }
                            if (newValue != confirm.text) {
                              message('两次输入的新密码不一致');
                              return;
                            }
                            update(() => saving = true);
                            try {
                              await widget.client.changePassword(
                                oldValue,
                                newValue,
                              );
                              if (!context.mounted) return;
                              Navigator.pop(context);
                              message('密码已修改');
                            } catch (error) {
                              if (context.mounted) {
                                message(
                                  '$error'.replaceFirst('Bad state: ', ''),
                                );
                              }
                            } finally {
                              if (context.mounted) update(() => saving = false);
                            }
                          },
                    child: Text(saving ? '提交中…' : '确认修改'),
                  ),
                ),
                body: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    TextField(
                      controller: old,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: '原密码'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: fresh,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: '新密码（至少 6 位）',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: confirm,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: '确认新密码'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        )
        .whenComplete(() {
          old.dispose();
          fresh.dispose();
          confirm.dispose();
        });
  }

  static const installer = MethodChannel('grupay/updates');
  bool checkingUpdate = false;
  Timer? installRetry;
  String? downloadedHash;

  Future<void> checkUpdate({bool automatic = false}) async {
    if (checkingUpdate) return;
    if (defaultTargetPlatform != TargetPlatform.android) {
      if (!automatic) message('请通过 iOS 分发渠道检查更新');
      return;
    }
    checkingUpdate = true;
    try {
      if (downloadedHash == null) {
        final build = await installer.invokeMethod<int>('build');
        final release = await widget.client.availableUpdate(build!);
        if (!mounted) return;
        if (release == null) {
          if (!automatic) message('当前已是最新版本');
          return;
        }
        message('正在下载新版安装包');
        await installer.invokeMethod<void>('download', {
          'url': release.$1.toString(),
          'sha256': release.$2,
        });
        downloadedHash = release.$2;
      }
      if (!mounted) return;
      if (widget.client.serving ||
          widget.active() > 0 ||
          switching ||
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        if (installRetry == null) message('新版已下载，设备空闲后将打开安装器');
        installRetry?.cancel();
        installRetry = Timer(
          const Duration(seconds: 5),
          () => checkUpdate(automatic: true),
        );
        return;
      }
      installRetry?.cancel();
      installRetry = null;
      await installer.invokeMethod<void>('install', {'sha256': downloadedHash});
      downloadedHash = null;
    } on PlatformException catch (e) {
      downloadedHash = null;
      if (mounted) message(e.message ?? '更新失败，请在关于页重试');
    } catch (_) {
      if (mounted && !automatic) message('检查更新失败，请稍后重试');
    } finally {
      checkingUpdate = false;
    }
  }

  void openAbout() {
    var checking = false;
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => StatefulBuilder(
          builder: (context, update) => Scaffold(
            appBar: AppBar(title: const Text('关于')),
            bottomNavigationBar: SafeArea(
              minimum: const EdgeInsets.all(16),
              child: FilledButton(
                onPressed: checking
                    ? null
                    : () async {
                        update(() => checking = true);
                        try {
                          await checkUpdate();
                        } finally {
                          if (context.mounted) update(() => checking = false);
                        }
                      },
                child: Text(checking ? '检查中…' : '检查更新'),
              ),
            ),
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Column(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Image.asset(
                          'assets/brand.png',
                          width: 72,
                          height: 72,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'GruPay',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const Text('v${WsClient.appVersion}'),
                    ],
                  ),
                ),
                ListTile(
                  title: const Text('设备号'),
                  subtitle: SelectableText(
                    '${widget.client.device['serial'] ?? '—'}',
                  ),
                  onTap: () => copy(widget.client.device['serial']),
                ),
                const Divider(height: 1),
                ListTile(
                  title: const Text('系统信息'),
                  subtitle: SelectableText(
                    '${Platform.operatingSystem} · ${Platform.operatingSystemVersion}',
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  title: const Text('联系我们'),
                  subtitle: SelectableText(
                    '${widget.client.settings['contact'] ?? '暂未配置'}',
                  ),
                  onTap: () => copy(widget.client.settings['contact']),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    scroll.dispose();
    midnight?.cancel();
    installRetry?.cancel();
    subscription.cancel();
    widget.client.removeListener(connection);
    super.dispose();
  }
}
