import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import 'app_prefs.dart';
import 'incognito.dart';
import 'motion.dart';
import 'text.dart';

bool get lockSupported => !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS);

bool get secureScreenSupported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// 弹系统的生物识别 / 锁屏密码验证。设备不支持或出错返回 false。
Future<bool> authenticate(String reason) async {
  try {
    final auth = LocalAuthentication();
    if (!await auth.isDeviceSupported()) return false;
    return await auth.authenticate(localizedReason: reason, persistAcrossBackgrounding: true);
  } catch (_) {
    return false;
  }
}

/// 包在整个 App 外面：开了"生物识别锁"时，冷启动、或者离开超过设定时间再回来，先盖一层锁屏要验证；
/// 同时按"防截屏"设置通知安卓开关 FLAG_SECURE（截不了屏、最近任务里不显示内容）。
class AppGuard extends ConsumerStatefulWidget {
  const AppGuard({
    super.key,
    required this.child,
    @visibleForTesting this.canAuth,
    @visibleForTesting this.onAuthenticate,
    @visibleForTesting this.now,
  });

  final Widget child;
  final Future<bool> Function()? canAuth;
  final Future<bool> Function(String reason)? onAuthenticate;
  final DateTime Function()? now;

  @override
  ConsumerState<AppGuard> createState() => _AppGuardState();
}

class _AppGuardState extends ConsumerState<AppGuard> with WidgetsBindingObserver {
  static const _secure = MethodChannel('ark/secure');
  late bool _locked = lockSupported && AppPrefs.read(P.lock, false);
  DateTime? _pausedAt;
  bool _asking = false;
  bool? _secureOn;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_locked) WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
    _syncSecure();
  }

  void _syncSecure() {
    if (!secureScreenSupported) return;
    final incognito = ref.read(incognitoProvider);
    final mode = AppPrefs.read(P.secure, 0);
    final want = mode == 1 || (mode == 2 && incognito);
    if (want != _secureOn) {
      _secureOn = want;
      _secure.invokeMethod('setSecure', {'secure': want}).ignore();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 系统的验证界面会让 App 暂停又恢复：验证期间的这些事件不算离开，不然刚解锁又锁上、反复弹验证
    if (!lockSupported || !AppPrefs.read(P.lock, false) || _asking) return;
    final desktop = defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.windows;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden || (desktop && state == AppLifecycleState.inactive)) {
      _pausedAt ??= (widget.now ?? DateTime.now)();
      if (!_locked && AppPrefs.read(P.lockAfter, 0) == 0) setState(() => _locked = true);
    } else if (state == AppLifecycleState.resumed && _pausedAt != null) {
      final away = (widget.now ?? DateTime.now)().difference(_pausedAt!);
      _pausedAt = null;
      if (_locked || away.inSeconds >= AppPrefs.read(P.lockAfter, 0) * 60) {
        if (!_locked) setState(() => _locked = true);
        _unlock();
      }
    }
  }

  Future<void> _unlock() async {
    if (_asking) return;
    _asking = true;
    final bool ok;
    try {
      // 开锁之后系统里关掉了锁屏密码：没法验证了，直接放行，不然再也进不了 App
      final canAuth = widget.canAuth ?? _canAuthenticate;
      final auth = widget.onAuthenticate ?? authenticate;
      ok = !await canAuth() || await auth('解锁 Ark Novel');
    } finally {
      _asking = false;
      _pausedAt = null;
    }
    if (ok && mounted) setState(() => _locked = false);
  }

  static Future<bool> _canAuthenticate() async {
    try {
      return await LocalAuthentication().isDeviceSupported();
    } catch (_) {
      return true; // 查不了就照常验证，验证失败还能再点
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(appPrefProvider(P.secure), (_, _) => _syncSecure());
    ref.listen(incognitoProvider, (_, _) => _syncSecure());
    return PopScope(
      canPop: !_locked,
      child: Stack(
        children: [
          ExcludeFocus(
            excluding: _locked,
            child: ExcludeSemantics(
              excluding: _locked,
              child: IgnorePointer(ignoring: _locked, child: widget.child),
            ),
          ),
          Positioned.fill(
            child: AppReveal(
              visible: _locked,
              offset: Offset.zero,
              beginScale: 1.0,
              // 上锁必须立刻遮挡内容防泄露，解锁时由底色柔滑淡出露出界面（锁屏控件本身即刻卸载不拦交互）
              duration: Duration.zero,
              reverseDuration: AppMotion.fast,
              child: ColoredBox(color: Theme.of(context).colorScheme.surface),
            ),
          ),
          if (_locked)
            Positioned.fill(
              child: Material(
                type: MaterialType.transparency,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 280),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.lock_outline, size: 56),
                          const SizedBox(height: 16),
                          const Text('Ark Novel 已锁定'),
                          const SizedBox(height: 24),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton(onPressed: _unlock, child: const Text('解锁')),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
