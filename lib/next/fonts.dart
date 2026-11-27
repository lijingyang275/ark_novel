import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/services.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'theme.dart';

/// 阅读器字体：系统默认 / 衬线 / 自己选的字体文件（ttf、otf）。
/// 选的文件复制到应用目录，每次选择换一个新的字体名，避免旧字体被缓存。
class FontStore {
  FontStore._();

  static Box get _box => Hive.box('session');

  static String? get customFamily => _box.get('font:family') as String?;

  static String? _loadedFamily;
  static String? _loadedPath;
  static Future<void>? _loading;

  /// 启动时仅在当前阅读字体就是自选字体（`r.font == 2`）时才读取并加载字体文件；
  /// 否则跳过磁盘读取直接置 [ready] 为 true，避免启动空读十几 MB 字体文件。
  static Future<void> loadSaved() async {
    if ((_box.get('r.font') as int?) != 2) {
      ready.value = true;
      return;
    }
    await ensureLoaded();
  }

  /// 幂等按需加载已保存的自选字体文件（供启动或用户稍后切回 `font == 2` 时调用）。
  /// 加载前将 [ready] 置为 false，加载完成（或无需加载/失败回退）后置为 true。
  static Future<void> ensureLoaded() async {
    final path = _box.get('font:path') as String?;
    final family = customFamily;
    if (path == null || family == null) {
      ready.value = true;
      return;
    }
    if (_loadedFamily == family && _loadedPath == path) {
      ready.value = true;
      return;
    }
    final running = _loading;
    if (running != null) return running;
    ready.value = false;
    final task = () async {
      try {
        final file = File(path);
        if (await file.exists()) {
          await _load(family, await file.readAsBytes());
          _loadedFamily = family;
          _loadedPath = path;
        }
      } catch (_) {
        // 字体文件坏了就按系统字体显示
      } finally {
        ready.value = true;
      }
    }();
    _loading = task;
    try {
      await task;
    } finally {
      if (identical(_loading, task)) _loading = null;
    }
  }

  /// 上次选的字体加载完了（或者没有要加载的）
  static final ready = ValueNotifier<bool>(false);

  static Future<void> _load(String family, Uint8List bytes) async {
    final loader = FontLoader(family)..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  }

  /// 弹出文件选择器并加载；用户取消返回 false。
  static Future<bool> pick() async {
    final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['ttf', 'otf']);
    final src = file?.path;
    if (src == null) return false;
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'font'));
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final dest = await File(src).copy(p.join(dir.path, 'font_$stamp${p.extension(src)}'));
    final family = 'ReaderFont$stamp';
    await _load(family, await dest.readAsBytes());
    _loadedFamily = family;
    _loadedPath = dest.path;
    ready.value = true;
    await _box.put('font:path', dest.path);
    await _box.put('font:family', family);
    return true;
  }

  /// 字体选项：编号 → 显示名。0 系统默认 1 系统衬线 2 自选文件 3 霞鹜文楷 4 思源宋体。
  static const names = {0: '系统默认', 1: '系统衬线', 3: '霞鹜文楷', 4: '思源宋体', 2: '自选字体'};

  /// 没有自选字体时按系统默认。内置字体只含常用字，缺的字回退到系统字体。
  static ({String? family, List<String>? fallback}) resolve(int font) {
    if (font == 2) {
      final family = customFamily;
      if (family != null) {
        final path = _box.get('font:path') as String?;
        if (path != null && (_loadedFamily != family || _loadedPath != path) && _loading == null) {
          Future.microtask(ensureLoaded);
        }
        return (family: family, fallback: null);
      }
    }
    return switch (font) {
      1 => (family: null, fallback: kSerifFallback),
      3 => (family: 'LXGWWenKai', fallback: kSerifFallback),
      4 => (family: 'NotoSerifSCBundled', fallback: kSerifFallback),
      _ => (family: null, fallback: null),
    };
  }
}
