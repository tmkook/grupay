import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/network/ws_client.dart';

typedef ProductCall = Future<Map> Function(String method, List arguments);

class OrderRunner {
  final WsClient client;
  final ProductCall call;
  final String? Function() account;
  final Future<void> Function()? onReauth;
  final String prefix;
  final store = const FlutterSecureStorage();
  final tasks = <String, Map>{};
  final busy = <String>{};
  final next = <String, int>{};
  bool disposed = false;
  Timer? timer;
  int clockOffset = 0;
  int get now => DateTime.now().millisecondsSinceEpoch + clockOffset;
  OrderRunner(this.client, this.call, this.account, [this.onReauth])
    : prefix =
          'order-${client.settings['product_code'] as String}/${client.scope}/';

  void receive(String type, Map data) {
    if (type == 'order.resume') {
      clockOffset =
          (data['server_time'] as int) - DateTime.now().millisecondsSinceEpoch;
      for (final task in data['orders']) {
        final no = task['order_no'];
        // Query parameters stay on this device; keep the local snapshot.
        tasks[no] = {...?tasks[no], ...Map.from(task)};
      }
    } else if (type == 'order.query') {
      final no = data['order_no'];
      final local = tasks[no];
      if (no is! String || local == null) return;
      tasks[no] = {...local, ...Map.from(data)};
      next.remove(no);
    } else if (type == 'order.task') {
      final current = tasks[data['order_no']];
      if (current != null && current['attempt'] >= data['attempt']) return;
      tasks[data['order_no']] = {...data, 'status': 'assigned'};
    } else {
      return;
    }
    pump();
  }

  Future<void> start() async {
    final records = await store.readAll();
    if (disposed) return;
    for (final entry in records.entries.where(
      (e) => e.key.startsWith(prefix),
    )) {
      final record = jsonDecode(entry.value) as Map;
      tasks.putIfAbsent(record['order_no'], () => record);
    }
    timer = Timer.periodic(const Duration(seconds: 1), (_) => pump());
    pump();
  }

  void pump() {
    if (disposed) return;
    for (final task in tasks.values.toList()) {
      final no = task['order_no'] as String;
      if (task['status'] == 'expired' &&
          ((task['query_count'] as int?) ?? 0) >= expiredQueryLimit) {
        tasks.remove(no);
        next.remove(no);
        unawaited(store.delete(key: '$prefix$no'));
        continue;
      }
      if (busy.contains(no) || (next[no] ?? 0) > now) continue;
      final recheck = task['status'] == 'expired';
      if ((task['status'] == 'placed' || recheck) && busy.length >= 20) {
        continue;
      }
      busy.add(no);
      unawaited(
        step(task).catchError((Object _) {}).whenComplete(() {
          busy.remove(no);
          final interval =
              int.tryParse('${client.settings['query_interval_ms']}') ?? 10000;
          if (tasks.containsKey(no)) {
            next[no] = now + interval.clamp(1000, 60000);
          }
        }),
      );
    }
  }

  /// Expired orders are rechecked every interval up to this many queries.
  static const expiredQueryLimit = 60;

  Future<void> step(Map task) async {
    final no = task['order_no'] as String;
    final key = '$prefix$no';
    if (!identical(tasks[no], task)) {
      task = {...?tasks[no], ...Map.from(task)};
      tasks[no] = task;
    }
    final ref = {'order_no': no, 'attempt': task['attempt']};
    final raw = await store.read(key: key);
    Map? saved = raw == null ? null : jsonDecode(raw);
    if (disposed) return;
    if (saved?['status'] == 'placed' &&
        saved?['attempt'] == task['attempt'] &&
        task['status'] != 'placed') {
      task = Map.from(saved!);
      tasks[no] = task;
    }
    Future<void> report(String type, Map data) async {
      final payload = {...ref, ...data};
      await store.write(
        key: key,
        value: jsonEncode({...task, 'event': type, 'payload': payload}),
      );
      if (disposed) return;
      final result = await client.request(type, payload);
      if (disposed) return;
      if (result['status'] == 'placed') {
        tasks[no] = {
          ...task,
          'status': 'placed',
          'deadline_at': result['deadline_at'],
        };
        await store.write(key: key, value: jsonEncode(tasks[no]));
      } else if (result['status'] == 'expired') {
        // Keep expired orders so late payments can be rechecked automatically.
        tasks[no] = {
          ...task,
          'status': 'expired',
          'query_params': task['query_params'],
          'deadline_at': result['deadline_at'] ?? task['deadline_at'],
          'query_count': result['query_count'] ?? task['query_count'],
        };
        await store.write(key: key, value: jsonEncode(tasks[no]));
      } else if (result['status'] == 'stale' ||
          result['recorded'] == true ||
          ['paid', 'failed'].contains(result['status'])) {
        tasks.remove(no);
        next.remove(no);
        await store.delete(key: key);
      } else if (type == 'order.failed' && data['outcome'] == 'unknown') {
        // Keep the execution marker until the server resolves this attempt.
        tasks[no] = {...task, 'status': 'placing'};
      }
    }

    if (saved?['event'] != null) {
      await report(saved!['event'], saved['payload']);
      return;
    }
    if (task['status'] == 'placed') {
      if (now > task['deadline_at'] + 30000) {
        await report('order.expired', {});
        return;
      }
      if ((await paymentConfirmed(task)).paid) {
        final proof = paymentProof(task);
        if (proof != null) await report('order.paid', proof);
      }
      return;
    }
    if (task['status'] == 'expired') {
      final params = task['query_params'];
      if (params is! Map || params['tradeNo'] == null) {
        tasks.remove(no);
        next.remove(no);
        await store.delete(key: key);
        return;
      }
      final uid = account();
      if (uid == null) return;
      if (params['account'] != uid) {
        tasks.remove(no);
        next.remove(no);
        await store.delete(key: key);
        return;
      }
      final outcome = await paymentConfirmed(task);
      if (outcome.paid) {
        final proof = paymentProof(task);
        if (proof != null) await report('order.paid', proof);
      } else if (!outcome.allowed) {
        tasks.remove(no);
        next.remove(no);
        await store.delete(key: key);
      }
      return;
    }
    if (saved?['status'] == 'executing' ||
        task['status'] == 'placing' ||
        task['status'] == 'executing') {
      final result = await client.request('order.failed', {
        ...ref,
        'outcome': 'unknown',
        'reason': '恢复时需核对原尝试',
      });
      if (!disposed &&
          ['stale', 'paid', 'expired', 'failed'].contains(result['status'])) {
        tasks.remove(no);
        next.remove(no);
        await store.delete(key: key);
      }
      return;
    }
    final uid = account();
    final accepted = uid != null && client.serving;
    final ack = await client.request('order.ack', {
      ...ref,
      'accepted': accepted,
    });
    if (disposed) return;
    if (ack['can_execute'] != true) {
      tasks.remove(no);
      await store.delete(key: key);
      return;
    }
    await store.write(
      key: key,
      value: jsonEncode({...task, 'status': 'executing'}),
    );
    if (disposed) return;
    if (account() != uid || uid == null) {
      await report('order.failed', {
        'outcome': 'confirmed_not_created',
        'reason': '产品账号已变化',
      });
      return;
    }
    Map pay;
    try {
      pay = await call('getPayUrl', [task['amount'], no, uid]);
    } on TimeoutException {
      pay = {'ok': false, 'reason': '等待产品页返回建单结果超时'};
    } catch (_) {
      pay = {'ok': false, 'reason': '未取得建单结果'};
    }
    final data = pay['data'];
    if (pay['ok'] != true ||
        data is! Map ||
        Uri.tryParse('${data['payUrl']}')?.scheme != 'https') {
      if (pay['reauth'] == true && !disposed) unawaited(onReauth?.call());
      await report('order.failed', {
        'outcome':
            pay['ok'] == false && pay['outcome'] == 'confirmed_not_created'
            ? 'confirmed_not_created'
            : 'unknown',
        'reason': pay['reason'] ?? '支付链接无效',
      });
      return;
    }
    Map? queryParams(Object? snapshot) {
      if (snapshot is! Map) return null;
      return {...snapshot, 'tradeNo': data['tradeNo'], 'account': uid};
    }

    var params = queryParams(data['query_params']);
    if (params != null) task['query_params'] = params;
    if (data['query_params'] == null) {
      // Older adapters return the query separately. Save the link before calling them.
      await store.write(
        key: key,
        value: jsonEncode({
          ...task,
          'event': 'order.placed',
          'payload': {...ref, 'pay_url': data['payUrl']},
        }),
      );
      try {
        if (account() == uid) {
          final result = await call('getProcessUrl', []);
          if (result['ok'] == true) {
            params = queryParams(result['data']);
            if (params != null) task['query_params'] = params;
          }
        }
      } catch (_) {}
    }
    await report('order.placed', {'pay_url': data['payUrl']});
  }

  Future<({bool paid, bool allowed})> paymentConfirmed(Map task) async {
    final params = task['query_params'];
    if (params is! Map || params['tradeNo'] == null) {
      return (paid: false, allowed: false);
    }
    final uid = account();
    if (uid == null) return (paid: false, allowed: true);
    if (params['account'] != uid) return (paid: false, allowed: false);
    if (disposed) return (paid: false, allowed: false);
    final permit = await client.request('order.query.begin', {
      'order_no': task['order_no'],
      'attempt': task['attempt'],
      'tradeNo': params['tradeNo'],
      if (task['counted_revision'] != null)
        'counted_revision': task['counted_revision'],
      'account': uid,
    });
    task.remove('counted_revision');
    if (permit['query_count'] is int) {
      task['query_count'] = permit['query_count'];
    }
    final allowed = permit['allowed'] == true;
    if (!allowed || disposed || account() != uid) {
      return (paid: false, allowed: allowed);
    }
    Map result;
    try {
      result = await call('queryOrder', [params]);
    } catch (_) {
      result = {'ok': false};
    }
    final data = result['data'];
    final paid =
        result['ok'] == true &&
        data is Map &&
        data['status'] == 'paid' &&
        params['tradeNo'] != null &&
        data['tradeNo'] == params['tradeNo'] &&
        data['amount'] == task['amount'] &&
        data['account'] == uid;
    if (!paid) {
      await client.request('order.query.result', {
        'order_no': task['order_no'],
        'attempt': task['attempt'],
        'outcome': result['ok'] != true
            ? 'error'
            : data is Map && data['status'] == 'pending'
            ? 'pending'
            : 'unknown',
      });
    }
    return (paid: paid, allowed: true);
  }

  Map? paymentProof(Map task) {
    final params = task['query_params'];
    if (params is! Map || params['tradeNo'] == null) return null;
    return {
      'tradeNo': params['tradeNo'],
      'account': params['account'],
      'amount': task['amount'],
    };
  }

  Future<void> drop(String no) async {
    tasks.remove(no);
    next.remove(no);
    await store.delete(key: '$prefix$no');
  }

  Future<String> recheck(Map order) async {
    final no = order['order_no'];
    final local = no is String ? tasks[no] : null;
    final params = local?['query_params'];
    if (local == null || params is! Map || params['tradeNo'] == null) {
      return '本机没有保存这笔订单的查单参数';
    }
    final ref = {'order_no': no, 'attempt': local['attempt']};
    final state = await client.request('order.recheck', {
      ...ref,
      'count_on_request': true,
    });
    if (state['status'] == 'paid') {
      await drop(no as String);
      return '订单已支付';
    }
    if (state['status'] == 'stale') return '请在原接单设备上查单';
    if (['created', 'assigned', 'placing'].contains(state['status'])) {
      return '订单尚未生成支付链接';
    }
    if (state['status'] == 'failed') {
      await drop(no as String);
      return '订单已失败';
    }
    if (state['reason'] is String) return state['reason'] as String;
    if (state['query_count'] is int) {
      local['query_count'] = state['query_count'];
    }
    if (state['deadline_at'] is int) {
      local['deadline_at'] = state['deadline_at'];
    }
    if (state['counted_revision'] != null) {
      local['counted_revision'] = state['counted_revision'];
    }
    if (account() == null || params['account'] != account()) {
      return '请用建单时的抖音账号登录后复查';
    }
    final outcome = await paymentConfirmed(local);
    if (!outcome.paid) {
      return outcome.allowed ? '暂未确认支付成功' : '查单次数已用完';
    }
    final proof = paymentProof(local);
    if (proof == null) return '本机没有保存这笔订单的查单参数';
    final result = await client.request('order.paid', {...ref, ...proof});
    if (result['status'] == 'paid' || result['status'] == 'stale') {
      await drop(no as String);
    }
    return result['status'] == 'paid'
        ? (state['status'] == 'expired' ? '已确认支付并完成补结算' : '已确认支付')
        : (result['reason'] as String? ?? '复查状态已变化，请刷新');
  }

  void dispose() {
    disposed = true;
    timer?.cancel();
  }
}
