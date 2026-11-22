import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import 'cache.dart';
import 'library.dart';
import 'session.dart';
import 'stats.dart';

typedef BgmVol = ({String name, String img});

/// 主系列「番外篇」里的一个小说外传：外传系列有自己的单行本 [vols]；单本没有，封面就是 [img]。[cn] 是中文名（可能是空的）。
typedef BgmExtra = ({String name, String cn, String img, List<BgmVol> vols});

/// Bangumi 上一个小说系列：每一卷单行本的名字和封面（按卷的先后），还有外传 [extras]。封面是日文原版，大多 1000 像素以上。
typedef BgmSeries = ({int id, String name, List<BgmVol> vols, List<BgmExtra> extras});

/// 卷名里的卷号：「第十一卷 矮人工匠」→ 11，「第2卷」→ 2。短篇、特典、「第8.5卷」这类不是正卷，为 null。
int? wenkuVolumeNumber(String title) {
  final m = RegExp(r'^第\s*([0-9]+|[一二两三四五六七八九十〇零]+)\s*卷').firstMatch(title.trim());
  if (m == null) return null;
  final s = m[1]!;
  final n = int.tryParse(s);
  if (n != null) return n;
  const d = {'〇': 0, '零': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4, '五': 5, '六': 6, '七': 7, '八': 8, '九': 9};
  final i = s.indexOf('十');
  if (i < 0) return s.length == 1 ? d[s] : null;
  final tens = i == 0 ? 1 : d[s.substring(0, i)];
  final ones = i == s.length - 1 ? 0 : d[s.substring(i + 1)];
  return tens == null || ones == null ? null : tens * 10 + ones;
}

/// Bangumi 单行本名字里的卷号：`(2)`、`(8.5)`、`Ep.10`；第一本常常不写号，算 1。认不出为 null。
num? bgmVolumeNumber(String name, int index) {
  final m = RegExp(r'[(（]\s*(\d+(?:\.\d+)?)\s*[)）]').firstMatch(name) ?? RegExp(r'Ep\.?\s*(\d+)', caseSensitive: false).firstMatch(name);
  if (m != null) return num.parse(m[1]!);
  return index == 0 ? 1 : null;
}

/// 卷名里不算关键词的通用字眼
const _generic = ['短篇集', '短篇', '特典小说', '特典', '外传', '番外', '剧场版', '官方', '同人志', '小说', '上', '下'];
const _genericLatin = {'bd', 'vol', 'the', 'and', 'of'};

/// 非正卷（小数卷、外传）对 Bangumi：卷名 → 封面地址。
/// - 「第8.5卷」：主系列里卷号 8.5 的那本。
/// - 外传：卷名里的英文词（三个字母以上）、中文片段（三个字以上，去掉「短篇、特典、外传」这类字眼）当关键词，
///   去对外传的日文名、中文名（书名本身含的词不算，免得每个外传都对上）。
///   卷名里有数字（「Progressive 7」「Alter.1」）就在对上的外传系列里取这个卷号的那本；没有数字就用对上的单本。
///   对上不止一个、或者一个都没对上：不给。
Map<String, String> matchExtraCovers(List<String> titles, BgmSeries s) {
  final own = [s.name, ...s.vols.map((v) => v.name)].join(' ').toLowerCase();
  final out = <String, String>{};
  for (final t in titles) {
    if (wenkuVolumeNumber(t) != null) continue;
    final dec = RegExp(r'^第\s*(\d+\.\d+)\s*卷').firstMatch(t.trim());
    if (dec != null) {
      final n = num.parse(dec[1]!);
      final i = [for (final (i, v) in s.vols.indexed) bgmVolumeNumber(v.name, i)].indexOf(n);
      if (i >= 0) out[t] = s.vols[i].img;
      continue;
    }
    var cjk = t;
    for (final g in _generic) {
      cjk = cjk.replaceAll(g, ' ');
    }
    final keys = {
      for (final m in RegExp(r'[A-Za-z]{3,}').allMatches(t)) m[0]!.toLowerCase(),
      for (final m in RegExp(r'[\u4e00-\u9fff]{3,}').allMatches(cjk)) m[0]!,
    }..removeWhere((k) => _genericLatin.contains(k) || own.contains(k));
    if (keys.isEmpty) continue;
    final hits = [for (final x in s.extras) if (keys.any((k) => '${x.name} ${x.cn}'.toLowerCase().contains(k))) x];
    final n = RegExp(r'\d+(?:\.\d+)?').firstMatch(t.replaceAll(RegExp(r'^第[^卷]*卷'), ''))?[0];
    if (n != null) {
      final series = hits.where((x) => x.vols.isNotEmpty).toList();
      if (series.length != 1) continue;
      final vols = series.first.vols;
      final key = keys.firstWhere((k) => RegExp('[a-z]').hasMatch(k), orElse: () => '');
      // 卷号：(N)、Ep.N，或者跟在关键词后面（Alter.1）
      final i = [
        for (final (i, v) in vols.indexed)
          bgmVolumeNumber(v.name, i) ?? (key.isEmpty ? null : num.tryParse(RegExp('${RegExp.escape(key)}\\.?\\s*(\\d+)', caseSensitive: false).firstMatch(v.name)?[1] ?? '')),
      ].indexOf(num.parse(n));
      if (i >= 0) out[t] = vols[i].img;
    } else {
      final singles = hits.where((x) => x.vols.isEmpty).toList();
      if (singles.length == 1) out[t] = singles.first.img;
    }
  }
  return out;
}

/// 文库的正卷（第 N 卷）对上 Bangumi 卷号是 N 的那本：卷名 → 封面地址。
/// Bangumi 那边大半认不出卷号时（比如「第三部「領主の養女IV」」），只有正卷数和单行本数一样才按顺序对，否则一卷都不给。
Map<String, String> matchVolumeCovers(List<String> titles, List<({String name, String img})> vols) {
  final mains = {for (final t in titles) t: wenkuVolumeNumber(t)}..removeWhere((_, n) => n == null);
  final numbers = [for (final (i, v) in vols.indexed) bgmVolumeNumber(v.name, i)];
  if (numbers.where((n) => n != null).length * 2 >= vols.length) {
    return {
      for (final e in mains.entries)
        if (numbers.indexOf(e.value) case final i when i >= 0) e.key: vols[i].img,
    };
  }
  final order = mains.values.toList();
  if (order.length != vols.length || !order.indexed.every((e) => e.$2 == e.$1 + 1)) return const {};
  return {for (final (i, t) in mains.keys.indexed) t: vols[i].img};
}

/// 去 Bangumi（bgm.tv）找各卷封面：文库没插图的卷（受限书、没有插图章节的卷）只有一张很小的书封。
/// 一本书只查一次（搜系列、取各卷），结果存在 `bgm:aid`；没找到也记下，30 天后再试；网络出错不记，下次再试。
class BangumiCovers {
  BangumiCovers(this._dio);

  final Dio _dio;
  final _running = <String, Future<BgmSeries?>>{};

  static Box get _box => Hive.box('session');
  static const _api = 'https://api.bgm.tv/v0';

  /// 网站上的原书名（不是自己改的显示名）：书架、统计、离线缓存里有哪个用哪个
  static String? bookTitle(String aid) => (LibraryStore.get(aid)?['title'] as String?) ?? ReadingStats.meta(aid)?.title ?? ChapterCache.books()[aid]?.$1;

  /// 存下来的结果，没查过或没找到为 null（不联网）
  static BgmSeries? saved(String aid) {
    final m = _box.get('bgm:$aid') as Map?;
    if (m == null || m['id'] == 0) return null;
    List<BgmVol> vols(Object? l) => [for (final v in ((l as List?) ?? const []).cast<Map>()) (name: v['n'] as String, img: v['i'] as String)];
    return (
      id: m['id'] as int,
      name: m['name'] as String,
      vols: vols(m['vols']),
      extras: [
        for (final x in ((m['x'] as List?) ?? const []).cast<Map>()) (name: x['n'] as String, cn: x['c'] as String, img: x['i'] as String, vols: vols(x['v'])),
      ],
    );
  }

  /// 同一本书同时要几次（几卷一起补）只查一次
  Future<BgmSeries?> series(String aid) => _running[aid] ??= _series(aid).whenComplete(() {
    _running.remove(aid);
  });

  Future<BgmSeries?> _series(String aid) async {
    final m = _box.get('bgm:$aid') as Map?;
    if (m != null && m['id'] != 0) {
      // 加外传之前存的只有主系列：补查一次外传
      if (m['x'] == null) await _box.put('bgm:$aid', {...m, 'x': await _extras(await _relations(m['id'] as int))});
      return saved(aid);
    }
    if (m != null && DateTime.now().millisecondsSinceEpoch - (m['t'] as int) < const Duration(days: 30).inMilliseconds) return null;
    final title = bookTitle(aid);
    if (title == null) return null;
    // 有两个译名时先用拆开的（Bangumi 上的中文名多是其中一个），再用整个书名
    for (final k in {...titleAlternatives(title), title}) {
      final r = await _dio.post<Map>('$_api/search/subjects', queryParameters: {'limit': 10}, data: {'keyword': k, 'filter': {'type': [1]}});
      final hit = ((r.data?['data'] as List?) ?? const []).cast<Map>().where((s) => s['platform'] == '小说' && s['series'] == true).firstOrNull;
      if (hit == null) continue;
      final rel = await _relations(hit['id'] as int);
      await _box.put('bgm:$aid', {'id': hit['id'] as int, 'name': _nameOf(hit), 'vols': _vols(rel), 'x': await _extras(rel), 't': DateTime.now().millisecondsSinceEpoch});
      return saved(aid);
    }
    await _box.put('bgm:$aid', {'id': 0, 't': DateTime.now().millisecondsSinceEpoch});
    return null;
  }

  static String _nameOf(Map s) => (s['name_cn'] as String?)?.isNotEmpty ?? false ? s['name_cn'] as String : s['name'] as String;

  static String _img(Map s) => (s['images'] as Map?)?['large'] as String? ?? '';

  Future<List<Map>> _relations(int id) async => ((await _dio.get<List>('$_api/subjects/$id/subjects')).data ?? const []).cast<Map>();

  static List<Map> _vols(List<Map> rel) => [
    for (final s in rel)
      if (s['relation'] == '单行本' && _img(s).isNotEmpty) {'n': s['name'] as String, 'i': _img(s)},
  ];

  /// 「番外篇」里的小说外传（漫画、游戏、画集不要）：外传系列取它的单行本，单本取它自己的封面（小批量并发，避免长篇串行几十次阻塞）
  Future<List<Map>> _extras(List<Map> rel) async {
    final candidates = rel.where((s) => s['relation'] == '番外篇' && s['type'] == 1).take(30).toList();
    final out = <Map>[];
    for (var i = 0; i < candidates.length; i += 4) {
      final batch = candidates.sublist(i, i + 4 > candidates.length ? candidates.length : i + 4);
      final items = await Future.wait(batch.map((s) async {
        final d = (await _dio.get<Map>('$_api/subjects/${s['id']}')).data ?? const {};
        if (d['platform'] != '小说') return null;
        final vols = d['series'] == true ? _vols(await _relations(s['id'] as int)) : const <Map>[];
        if (vols.isEmpty && _img(d).isEmpty) return null;
        return <String, Object>{'n': d['name'] as String, 'c': (d['name_cn'] as String?) ?? '', 'i': _img(d), 'v': vols};
      }));
      out.addAll(items.whereType<Map>());
    }
    return out;
  }
}

final bangumiProvider = Provider<BangumiCovers>((ref) {
  final store = ref.watch(sessionStoreProvider);
  ref.watch(proxyProvider);
  // Bangumi 要求带上说明是哪个程序的 User-Agent
  final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 10), receiveTimeout: const Duration(seconds: 20), headers: {'User-Agent': 'ark_novel (https://github.com/chenshi221/ark_novel)'}))
    ..httpClientAdapter = store.adapter();
  ref.onDispose(dio.close);
  return BangumiCovers(dio);
});
