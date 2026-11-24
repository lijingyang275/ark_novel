import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;

const _cacheTtl = Duration(seconds: 3);
List<ConnectivityResult>? _cachedResult;
DateTime? _cachedAt;
Future<List<ConnectivityResult>?>? _inflight;

@visibleForTesting
void resetNetStateCache() {
  _cachedResult = null;
  _cachedAt = null;
  _inflight = null;
}

Future<List<ConnectivityResult>?> _connectivity() async {
  if (kIsWeb) return null;
  final now = DateTime.now();
  if (_cachedResult != null && _cachedAt != null && now.difference(_cachedAt!) < _cacheTtl) {
    return _cachedResult;
  }
  return _inflight ??= () async {
    try {
      final res = await Connectivity().checkConnectivity();
      _cachedResult = res;
      _cachedAt = DateTime.now();
      return res;
    } catch (_) {
      return null;
    } finally {
      _inflight = null;
    }
  }();
}

/// 现在是不是 Wi-Fi（或有线）。查不出来就当是，免得一个限制让功能一直不工作。
Future<bool> onWifi() async {
  final c = await _connectivity();
  if (c == null) return true;
  return c.contains(ConnectivityResult.wifi) || c.contains(ConnectivityResult.ethernet);
}

/// 当前是否处于完全断网状态。查不出来时返回 false（保守放行，不误杀请求）。
Future<bool> isOffline() async {
  final c = await _connectivity();
  if (c == null || c.isEmpty) return false;
  return c.every((r) => r == ConnectivityResult.none);
}
