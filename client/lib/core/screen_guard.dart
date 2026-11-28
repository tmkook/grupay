import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ScreenGuard extends StatefulWidget {
  const ScreenGuard({super.key, required this.child});

  final Widget child;

  static ScreenGuardState? of(BuildContext context) =>
      context.findAncestorStateOfType<ScreenGuardState>();

  @override
  State<ScreenGuard> createState() => ScreenGuardState();
}

class ScreenGuardState extends State<ScreenGuard> with WidgetsBindingObserver {
  static const _channel = MethodChannel('grupay/screen_guard');
  static const _idle = Duration(minutes: 10);
  final enabled = ValueNotifier(false);
  Timer? _timer;
  bool _foreground = true;
  bool _covered = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_restore());
  }

  Future<void> _restore() async {
    final preferences = await SharedPreferences.getInstance();
    if (!mounted) return;
    if (preferences.getBool('screen_guard') == true) enabled.value = true;
    // 未开启息屏保护时也主动清除常亮标记，保证默认允许锁屏。
    _activity();
  }

  Future<void> setEnabled(bool value) async {
    enabled.value = value;
    _activity();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('screen_guard', value);
  }

  Future<void> _applyDisplay() async {
    try {
      await _channel.invokeMethod<void>('display', {
        'awake': enabled.value && _foreground,
        'dimmed': _covered && _foreground,
      });
    } on MissingPluginException {
      // The visual overlay also works on hosts without display controls.
    }
  }

  void _activity() {
    if (_covered) setState(() => _covered = false);
    unawaited(_applyDisplay());
    _scheduleCover();
  }

  void _scheduleCover() {
    _timer?.cancel();
    if (!enabled.value || !_foreground) return;
    _timer = Timer(_idle, () {
      setState(() => _covered = true);
      unawaited(_applyDisplay());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _foreground) return;
    _foreground = foreground;
    _activity();
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) {
      if (!_covered) _scheduleCover();
    },
    onPointerMove: (_) {
      if (!_covered) _scheduleCover();
    },
    child: Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (_covered)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _activity,
              child: const ColoredBox(color: Colors.black),
            ),
          ),
      ],
    ),
  );

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _foreground = false;
    unawaited(_applyDisplay());
    enabled.dispose();
    super.dispose();
  }
}
