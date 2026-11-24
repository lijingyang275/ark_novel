import 'dart:async';
import 'dart:collection';

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

/// Bangumi 关联条目（动画 / 漫画等）。
class BgmRelation {
  const BgmRelation({
    required this.id,
    required this.name,
    required this.nameCn,
    required this.relation,
    required this.type,
    required this.img,
  });

  final int id;
  final String name;
  final String nameCn;
  final String relation;

  /// Bangumi 条目类型：2 为动画，1 为书籍（含漫画等）
  final int type;
  final String img;

  String get displayName => nameCn.isNotEmpty ? nameCn : name;
  String get url => 'https://bgm.tv/subject/$id';

  Map<String, Object> toMap() => {'id': id, 'n': name, 'c': nameCn, 'r': relation, 'tp': type, 'i': img};

  factory BgmRelation.fromMap(Map m) => BgmRelation(
    id: (m['id'] as num?)?.toInt() ?? 0,
    name: (m['n'] as String?) ?? (m['name'] as String?) ?? '',
    nameCn: (m['c'] as String?) ?? (m['name_cn'] as String?) ?? '',
    relation: (m['r'] as String?) ?? (m['relation'] as String?) ?? '',
    type: (m['tp'] as num?)?.toInt() ?? (m['type'] as num?)?.toInt() ?? 0,
    img: (m['i'] as String?) ?? _bgmThumbImg(m),
  );
}

/// Bangumi 小说条目详情（评分、标签、关联动画/漫画等），缓存 7 天。
class BgmSubjectInfo {
  const BgmSubjectInfo({
    required this.id,
    required this.name,
    required this.nameCn,
    required this.score,
    required this.ratingTotal,
    required this.rank,
    required this.date,
    required this.summary,
    required this.tags,
    required this.relations,
    this.fetchedAt = 0,
  });

  final int id;
  final String name;
  final String nameCn;
  final double score;
  final int ratingTotal;
  final int rank;
  final String date;
  final String summary;
  final List<String> tags;
  final List<BgmRelation> relations;
  final int fetchedAt;

  String get displayName => nameCn.isNotEmpty ? nameCn : name;
  String get url => 'https://bgm.tv/subject/$id';

  Map<String, Object> toMap() => {
    'id': id,
    'n': name,
    'c': nameCn,
    'sc': score,
    'rt': ratingTotal,
    'rk': rank,
    'd': date,
    's': summary,
    'tg': tags,
    'rl': [for (final r in relations) r.toMap()],
    't': fetchedAt,
  };

  factory BgmSubjectInfo.fromMap(Map m) => BgmSubjectInfo(
    id: (m['id'] as num?)?.toInt() ?? 0,
    name: (m['n'] as String?) ?? '',
    nameCn: (m['c'] as String?) ?? '',
    score: (m['sc'] as num?)?.toDouble() ?? 0,
    ratingTotal: (m['rt'] as num?)?.toInt() ?? 0,
    rank: (m['rk'] as num?)?.toInt() ?? 0,
    date: (m['d'] as String?) ?? '',
    summary: (m['s'] as String?) ?? '',
    tags: ((m['tg'] as List?) ?? const []).cast<String>(),
    relations: [for (final r in ((m['rl'] as List?) ?? const []).cast<Map>()) BgmRelation.fromMap(r)],
    fetchedAt: (m['t'] as num?)?.toInt() ?? 0,
  );

  /// 从 Bangumi `/v0/subjects/{id}` 与 `/v0/subjects/{id}/subjects` 原始响应解析条目详情。
  factory BgmSubjectInfo.fromApi(Map subject, List<Map> rawRelations, {int? fetchedAt}) {
    final rating = (subject['rating'] as Map?) ?? const {};
    final rawTags = ((subject['tags'] as List?) ?? const []).whereType<Map>().toList()
      ..sort((a, b) => ((b['count'] as num?)?.toInt() ?? 0).compareTo((a['count'] as num?)?.toInt() ?? 0));
    final tags = <String>[];
    for (final t in rawTags) {
      final tn = (t['name'] as String?)?.trim() ?? '';
      if (tn.isNotEmpty && !tags.contains(tn)) tags.add(tn);
      if (tags.length >= 8) break;
    }
    final seenRel = <int>{};
    final relations = <BgmRelation>[];
    for (final r in rawRelations) {
      final rid = (r['id'] as num?)?.toInt() ?? 0;
      final type = (r['type'] as num?)?.toInt() ?? 0;
      final rel = (r['relation'] as String?)?.trim() ?? '';
      if (rid <= 0 || !seenRel.add(rid)) continue;
      if (type == 2 || (type == 1 && rel != '单行本')) {
        relations.add(
          BgmRelation(
            id: rid,
            name: (r['name'] as String?)?.trim() ?? '',
            nameCn: (r['name_cn'] as String?)?.trim() ?? '',
            relation: rel,
            type: type,
            img: _bgmThumbImg(r),
          ),
        );
      }
    }
    return BgmSubjectInfo(
      id: (subject['id'] as num?)?.toInt() ?? 0,
      name: (subject['name'] as String?)?.trim() ?? '',
      nameCn: (subject['name_cn'] as String?)?.trim() ?? '',
      score: (rating['score'] as num?)?.toDouble() ?? 0,
      ratingTotal: (rating['total'] as num?)?.toInt() ?? 0,
      rank: (rating['rank'] as num?)?.toInt() ?? 0,
      date: (subject['date'] as String?)?.trim() ?? '',
      summary: (subject['summary'] as String?)?.trim() ?? '',
      tags: tags,
      relations: relations,
      fetchedAt: fetchedAt ?? DateTime.now().millisecondsSinceEpoch,
    );
  }
}

/// Bangumi 角色条目（列表项 + 可选的单角色详情 `infobox` 与 `summary`）。
class BgmCharacter {
  const BgmCharacter({
    required this.id,
    required this.name,
    this.nameCn = '',
    this.spacedName = '',
    this.aliases = const [],
    this.relation = '',
    this.img = '',
    this.summary = '',
    this.enriched = false,
  });

  final int id;
  final String name;
  final String nameCn;

  /// `infobox` 里带姓/名空格分界的原名（如 `小佐内 ゆき`、`小鳩 常悟朗`），仅用于辅助拆出常用中文称呼，不直接作为别名展示。
  final String spacedName;
  final List<String> aliases;
  final String relation;
  final String img;
  final String summary;
  final bool enriched;

  String get displayName => nameCn.isNotEmpty ? nameCn : name;

  BgmCharacter copyWith({
    String? name,
    String? nameCn,
    String? spacedName,
    List<String>? aliases,
    String? relation,
    String? img,
    String? summary,
    bool? enriched,
  }) => BgmCharacter(
    id: id,
    name: name ?? this.name,
    nameCn: nameCn ?? this.nameCn,
    spacedName: spacedName ?? this.spacedName,
    aliases: aliases ?? this.aliases,
    relation: relation ?? this.relation,
    img: img ?? this.img,
    summary: summary ?? this.summary,
    enriched: enriched ?? this.enriched,
  );

  Map<String, Object> toMap() => {
    'id': id,
    'n': name,
    'c': nameCn,
    if (spacedName.isNotEmpty) 'sn': spacedName,
    'al': aliases,
    'r': relation,
    'i': img,
    's': summary,
    'e': enriched,
  };

  factory BgmCharacter.fromMap(Map m) => BgmCharacter(
    id: (m['id'] as num?)?.toInt() ?? 0,
    name: (m['n'] as String?) ?? (m['name'] as String?) ?? '',
    nameCn: (m['c'] as String?) ?? '',
    spacedName: (m['sn'] as String?) ?? '',
    aliases: ((m['al'] as List?) ?? const []).cast<String>(),
    relation: (m['r'] as String?) ?? (m['relation'] as String?) ?? '',
    img: (m['i'] as String?) ?? _bgmCharImg(m),
    summary: (m['s'] as String?) ?? (m['summary'] as String?) ?? '',
    enriched: (m['e'] as bool?) ?? false,
  );

  /// 解析 `/v0/subjects/{id}/characters` 单条角色记录。
  factory BgmCharacter.fromSubjectApi(Map m) => BgmCharacter(
    id: (m['id'] as num?)?.toInt() ?? 0,
    name: (m['name'] as String?)?.trim() ?? '',
    relation: (m['relation'] as String?)?.trim() ?? '',
    img: _bgmCharImg(m),
  );

  /// 合并 `/v0/characters/{cid}` 详情（解析 `infobox` 中的简体中文名与别名，以及简介与头像）。
  BgmCharacter mergeDetail(Map detail) {
    final resolvedName = (detail['name'] as String?)?.trim().isNotEmpty == true ? (detail['name'] as String).trim() : name;
    final parsed = parseInfobox(detail['infobox'], originalName: resolvedName);
    final spaced = extractSpacedName(detail['infobox'], fallback: resolvedName);
    final imgFromDetail = _bgmCharImg(detail);
    final sum = (detail['summary'] as String?)?.trim() ?? '';
    return copyWith(
      name: resolvedName,
      nameCn: parsed.nameCn.isNotEmpty ? parsed.nameCn : nameCn,
      spacedName: spaced.isNotEmpty ? spaced : spacedName,
      aliases: parsed.aliases.isNotEmpty ? parsed.aliases : aliases,
      img: img.isNotEmpty ? img : imgFromDetail,
      summary: sum.isNotEmpty ? sum : summary,
      enriched: true,
    );
  }

  /// 从 Bangumi `infobox` 提取带空格分隔姓/名的原名（如 `小鳩 常悟朗`、`小佐内 ゆき`），用于辅助推导中文姓氏与名字。
  static String extractSpacedName(Object? raw, {String fallback = ''}) {
    if (raw is List) {
      String? jp;
      String? kana;
      for (final item in raw.whereType<Map>()) {
        final key = (item['key'] as String?)?.trim() ?? '';
        final val = item['value'];
        if (key != '别名' || val is! List) continue;
        for (final entry in val.whereType<Map>()) {
          final k = (entry['k'] as String?)?.trim() ?? '';
          final v = (entry['v'] as String?)?.trim() ?? '';
          if (v.isEmpty || !RegExp(r'[\s\u3000]').hasMatch(v)) continue;
          if (k == '日文名' || k == '本名') jp ??= v;
          if (k == '纯假名' || k == '平假名') kana ??= v;
        }
      }
      if (jp != null) return jp;
      if (kana != null) return kana;
    }
    return RegExp(r'[\s\u3000]').hasMatch(fallback.trim()) ? fallback.trim() : '';
  }

  /// 从 Bangumi 角色详情 `infobox` 解析「简体中文名」与「别名」（自动跳过日文原名、假名、罗马字及与原名去空格重复的冗余项）。
  static ({String nameCn, List<String> aliases}) parseInfobox(Object? raw, {String originalName = ''}) {
    var nameCn = '';
    final aliases = <String>[];
    if (raw is! List) return (nameCn: nameCn, aliases: aliases);
    const skipKeys = {'纯假名', '平假名', '片假名', '罗马字', '假名', '日文名', '英文名', '韩文名', '外文名', '拉丁转写', '拼音'};
    String compact(String s) => s.replaceAll(RegExp(r'[\s\u3000]+'), '').toLowerCase();
    final origCompact = compact(originalName);
    void addAlias(String v) {
      final s = v.trim();
      if (s.isEmpty) return;
      final c = compact(s);
      if (origCompact.isNotEmpty && c == origCompact) return;
      if (!aliases.contains(s)) aliases.add(s);
    }

    for (final item in raw.whereType<Map>()) {
      final key = (item['key'] as String?)?.trim() ?? '';
      final val = item['value'];
      if (key == '简体中文名' && val is String && val.trim().isNotEmpty) {
        nameCn = val.trim();
      } else if (key == '别名') {
        if (val is String) {
          for (final part in val.split(RegExp(r'[、/／,，]'))) {
            addAlias(part);
          }
        } else if (val is List) {
          for (final entry in val) {
            if (entry is String) {
              addAlias(entry);
            } else if (entry is Map) {
              final k = (entry['k'] as String?)?.trim() ?? '';
              final v = (entry['v'] as String?)?.trim() ?? '';
              if (v.isEmpty || skipKeys.contains(k)) continue;
              addAlias(v);
            }
          }
        }
      }
    }
    if (nameCn.isNotEmpty) {
      final cnCompact = compact(nameCn);
      aliases.removeWhere((a) => compact(a) == cnCompact);
    }
    return (nameCn: nameCn, aliases: aliases);
  }
}

/// 将 Bangumi 角色全身立绘 URL 转为官方上半身特写 `pic/crt/m/`（220×330），配合 `Alignment.topCenter` 在头像框中稳定露出脸部。
/// 非 Bangumi 角色图原样返回。
String bgmCharacterAvatarUrl(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return trimmed;
  final re = RegExp(r'^(https?://lain\.bgm\.tv/)(?:r/\d+/)?pic/crt/(?:l|s|g)/(.+)$');
  final m = re.firstMatch(trimmed);
  if (m != null) return '${m[1]}pic/crt/m/${m[2]}';
  return trimmed;
}

/// 将 Bangumi 角色任意尺寸头像 URL 还原为完整立绘原图 `pic/crt/l/`，用于点击放大查看。
String bgmCharacterFullUrl(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return trimmed;
  final re = RegExp(r'^(https?://lain\.bgm\.tv/)(?:r/\d+/)?pic/crt/(?:m|s|g|l)/(.+)$');
  final m = re.firstMatch(trimmed);
  if (m != null) return '${m[1]}pic/crt/l/${m[2]}';
  return trimmed;
}

String _bgmThumbImg(Map s) {
  final imgs = s['images'] as Map?;
  if (imgs == null) return '';
  for (final k in const ['medium', 'common', 'large', 'small', 'grid']) {
    final v = imgs[k] as String?;
    if (v != null && v.isNotEmpty) return v;
  }
  return '';
}

String _bgmCharImg(Map s) {
  final imgs = s['images'] as Map?;
  if (imgs == null) return '';
  for (final k in const ['medium', 'large', 'small', 'grid']) {
    final v = imgs[k] as String?;
    if (v != null && v.isNotEmpty) return v;
  }
  return '';
}

/// 从 Bangumi 搜索结果中挑出最合适的小说条目：优先 `platform == '小说' && series == true`，否则兜底单卷小说（`platform == '小说'`）。
Map? pickBgmNovelHit(List<Map> items) {
  final novels = items.where((s) => s['platform'] == '小说');
  return novels.where((s) => s['series'] == true).firstOrNull ?? novels.firstOrNull;
}

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

/// 简单异步信号量，用于限制 Bangumi 并发查询的书数与请求数。
class _Semaphore {
  _Semaphore(this._max);

  final int _max;
  int _inUse = 0;
  final _waiters = Queue<Completer<void>>();

  Future<T> run<T>(Future<T> Function() fn) async {
    if (_inUse >= _max) {
      final c = Completer<void>();
      _waiters.add(c);
      await c.future;
    } else {
      _inUse++;
    }
    try {
      return await fn();
    } finally {
      if (_waiters.isNotEmpty) {
        _waiters.removeFirst().complete();
      } else {
        _inUse--;
      }
    }
  }
}

/// 去 Bangumi（bgm.tv）找各卷封面：文库没插图的卷（受限书、没有插图章节的卷）只有一张很小的书封。
/// 一本书只查一次（搜系列、取各卷），结果存在 `bgm:aid`；没找到也记下，30 天后再试；网络出错不记，下次再试。
class BangumiCovers {
  BangumiCovers(this._dio, {this.rateLimitBase = const Duration(seconds: 2)});

  final Dio _dio;
  final Duration rateLimitBase;
  final _running = <String, Future<BgmSeries?>>{};
  final _runningInfo = <String, Future<BgmSubjectInfo?>>{};
  final _runningChars = <String, Future<List<BgmCharacter>>>{};
  // 全局并发上限：最多同时查 2 本书 / 4 条 HTTP 请求，防止文库熔断时瞬间触发百级并发
  final _bookSem = _Semaphore(2);
  final _reqSem = _Semaphore(4);
  DateTime _pausedUntil = DateTime.fromMillisecondsSinceEpoch(0);
  int _consecutive429 = 0;

  static Box get _box => Hive.box('session');
  static const _api = 'https://api.bgm.tv/v0';

  /// 条目详情与角色列表缓存有效期（7 天）
  static const infoCacheTtl = Duration(days: 7);

  /// 网站上的原书名（不是自己改的显示名）：书架、统计、离线缓存里有哪个用哪个
  static String? bookTitle(String aid) =>
      (Hive.isBoxOpen('session') ? (LibraryStore.get(aid)?['title'] as String?) ?? ReadingStats.meta(aid)?.title : null) ??
      (Hive.isBoxOpen('chapter_index') ? ChapterCache.books()[aid]?.$1 : null);

  /// 存下来的结果，没查过或没找到为 null（不联网）
  static BgmSeries? saved(String aid) {
    if (!Hive.isBoxOpen('session')) return null;
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

  /// 本地缓存的 Bangumi 条目详情（不联网，未查过或未命中返回 null）。
  static BgmSubjectInfo? savedInfo(String aid) {
    if (!Hive.isBoxOpen('session')) return null;
    final m = _box.get('bgm_info:$aid') as Map?;
    if (m == null || (m['id'] as num?)?.toInt() == 0) return null;
    return BgmSubjectInfo.fromMap(m);
  }

  /// 判断缓存的条目详情是否超过 7 天需要按需刷新。
  static bool isInfoExpired(BgmSubjectInfo info, {DateTime? now}) {
    final elapsed = (now ?? DateTime.now()).millisecondsSinceEpoch - info.fetchedAt;
    return elapsed < 0 || elapsed >= infoCacheTtl.inMilliseconds;
  }

  /// 本地缓存的 Bangumi 角色列表（不联网）。
  static List<BgmCharacter>? savedCharacters(String aid) {
    if (!Hive.isBoxOpen('session')) return null;
    final m = _box.get('bgm_chars:$aid') as Map?;
    if (m == null) return null;
    final list = m['list'];
    if (list is! List) return null;
    return [for (final item in list.whereType<Map>()) BgmCharacter.fromMap(item)];
  }

  /// 同一本书同时要几次（几卷一起补）只查一次；全局最多同时查 2 本书。
  Future<BgmSeries?> series(String aid) => _running[aid] ??= _bookSem.run(() => _series(aid)).whenComplete(() {
    _running.remove(aid);
  });

  /// 拉取并缓存 Bangumi 条目详情（`bgm_info:$aid`，7 天内直接复用缓存；网络失败时回退旧缓存）。
  Future<BgmSubjectInfo?> subjectInfo(String aid, {String? fallbackTitle, CancelToken? cancelToken}) {
    final cachedMap = Hive.isBoxOpen('session') ? _box.get('bgm_info:$aid') as Map? : null;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (cachedMap != null) {
      final t = (cachedMap['t'] as num?)?.toInt() ?? 0;
      if (nowMs - t >= 0 && nowMs - t < infoCacheTtl.inMilliseconds) {
        return Future.value((cachedMap['id'] as num?)?.toInt() == 0 ? null : BgmSubjectInfo.fromMap(cachedMap));
      }
    }
    return _runningInfo[aid] ??= _bookSem.run(() => _subjectInfo(aid, fallbackTitle: fallbackTitle, cancelToken: cancelToken)).whenComplete(() {
      _runningInfo.remove(aid);
    });
  }

  Future<BgmSubjectInfo?> _subjectInfo(String aid, {String? fallbackTitle, CancelToken? cancelToken}) async {
    final stale = savedInfo(aid);
    try {
      final s = await _series(aid, fallbackTitle: fallbackTitle, cancelToken: cancelToken);
      if (s == null) {
        if (Hive.isBoxOpen('session')) await _box.put('bgm_info:$aid', {'id': 0, 't': DateTime.now().millisecondsSinceEpoch});
        return null;
      }
      final results = await Future.wait<Object?>([
        _request(() => _dio.get<Map>('$_api/subjects/${s.id}', cancelToken: cancelToken)),
        _relations(s.id, cancelToken: cancelToken),
      ]);
      final subj = ((results[0] as Response<Map>).data ?? const {});
      final rels = results[1] as List<Map>;
      final info = BgmSubjectInfo.fromApi(subj, rels);
      if (Hive.isBoxOpen('session')) await _box.put('bgm_info:$aid', info.toMap());
      return info;
    } catch (_) {
      if (stale != null) return stale;
      rethrow;
    }
  }

  /// 拉取并缓存 Bangumi 角色列表（`bgm_chars:$aid`）；若小说条目角色少于 3 个且有关联动画，自动合并首个关联动画条目的角色。
  Future<List<BgmCharacter>> characters(String aid, {String? fallbackTitle, bool forceRefresh = false, CancelToken? cancelToken}) {
    if (!forceRefresh && Hive.isBoxOpen('session')) {
      final m = _box.get('bgm_chars:$aid') as Map?;
      if (m != null) {
        final t = (m['t'] as num?)?.toInt() ?? 0;
        final elapsed = DateTime.now().millisecondsSinceEpoch - t;
        if (elapsed >= 0 && elapsed < infoCacheTtl.inMilliseconds) {
          final list = m['list'];
          if (list is List) return Future.value([for (final item in list.whereType<Map>()) BgmCharacter.fromMap(item)]);
        }
      }
    }
    return _runningChars[aid] ??= _bookSem.run(() => _characters(aid, fallbackTitle: fallbackTitle, cancelToken: cancelToken)).whenComplete(() {
      _runningChars.remove(aid);
    });
  }

  Future<List<BgmCharacter>> _characters(String aid, {String? fallbackTitle, CancelToken? cancelToken}) async {
    final s = await _series(aid, fallbackTitle: fallbackTitle, cancelToken: cancelToken);
    if (s == null) return const [];
    final raw = ((await _request(() => _dio.get<List>('$_api/subjects/${s.id}/characters', cancelToken: cancelToken))).data ?? const []).whereType<Map>().toList();
    final chars = <BgmCharacter>[];
    final seen = <int>{};
    for (final m in raw) {
      final c = BgmCharacter.fromSubjectApi(m);
      if (c.id > 0 && seen.add(c.id)) chars.add(c);
    }
    if (chars.length < 3) {
      try {
        final rels = savedInfo(aid)?.relations ?? BgmSubjectInfo.fromApi({'id': s.id}, await _relations(s.id, cancelToken: cancelToken)).relations;
        final firstAnime = rels.where((r) => r.type == 2).firstOrNull;
        if (firstAnime != null) {
          final animeRaw = ((await _request(() => _dio.get<List>('$_api/subjects/${firstAnime.id}/characters', cancelToken: cancelToken))).data ?? const []).whereType<Map>().toList();
          for (final m in animeRaw) {
            final c = BgmCharacter.fromSubjectApi(m);
            if (c.id > 0 && seen.add(c.id)) chars.add(c);
          }
        }
      } catch (_) {}
    }
    if (Hive.isBoxOpen('session')) {
      await _box.put('bgm_chars:$aid', {
        't': DateTime.now().millisecondsSinceEpoch,
        'list': [for (final c in chars) c.toMap()],
      });
    }
    return chars;
  }

  /// 按需拉取单个角色详情 `GET /v0/characters/{cid}`，合并 `infobox` 中的简体中文名、别名和简介。
  Future<BgmCharacter> characterDetail(BgmCharacter base, {CancelToken? cancelToken}) async {
    final d = (await _request(() => _dio.get<Map>('$_api/characters/${base.id}', cancelToken: cancelToken))).data;
    if (d == null) return base;
    return base.mergeDetail(d);
  }

  /// 批量按需补全角色列表中尚未拉取详情的条目的简体中文名/别名/简介，并回写 `bgm_chars:$aid` 缓存。
  /// 传入 [targetIds] 时优先补全指定的角色集合（不受 [maxFetch] 限制）。
  Future<List<BgmCharacter>> enrichCharacters(
    String aid,
    List<BgmCharacter> list, {
    int maxFetch = 20,
    Set<int>? targetIds,
    void Function(int done, int total, List<BgmCharacter> current)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final updated = List<BgmCharacter>.of(list);
    final pendingIdx = targetIds != null
        ? [for (var i = 0; i < updated.length; i++) if (!updated[i].enriched && targetIds.contains(updated[i].id)) i]
        : [for (var i = 0; i < updated.length; i++) if (!updated[i].enriched) i].take(maxFetch).toList();
    if (pendingIdx.isEmpty) return updated;
    var done = 0;
    for (var i = 0; i < pendingIdx.length; i += 4) {
      if (cancelToken?.isCancelled == true) break;
      final batch = pendingIdx.sublist(i, i + 4 > pendingIdx.length ? pendingIdx.length : i + 4);
      await Future.wait(batch.map((idx) async {
        if (cancelToken?.isCancelled == true) return;
        try {
          updated[idx] = await characterDetail(updated[idx], cancelToken: cancelToken);
        } catch (_) {}
        done++;
      }));
      onProgress?.call(done, pendingIdx.length, List<BgmCharacter>.unmodifiable(updated));
    }
    if (Hive.isBoxOpen('session') && cancelToken?.isCancelled != true) {
      await _box.put('bgm_chars:$aid', {
        't': DateTime.now().millisecondsSinceEpoch,
        'list': [for (final c in updated) c.toMap()],
      });
    }
    return updated;
  }

  Future<Response<T>> _request<T>(Future<Response<T>> Function() call) async {
    for (var attempt = 0; ; attempt++) {
      while (true) {
        final wait = _pausedUntil.difference(DateTime.now());
        if (wait <= Duration.zero) break;
        await Future<void>.delayed(wait);
      }
      try {
        final res = await _reqSem.run(call);
        _consecutive429 = 0;
        return res;
      } on DioException catch (e) {
        if (e.response?.statusCode != 429 || attempt >= 2) rethrow;
        _consecutive429++;
        final retryAfter = int.tryParse(e.response?.headers.value('retry-after')?.trim() ?? '');
        final pause = retryAfter != null
            ? Duration(seconds: retryAfter.clamp(1, 60))
            : Duration(milliseconds: (rateLimitBase.inMilliseconds * (1 << (_consecutive429 - 1).clamp(0, 3))).clamp(0, 30000));
        final until = DateTime.now().add(pause);
        if (until.isAfter(_pausedUntil)) _pausedUntil = until;
      }
    }
  }

  Future<BgmSeries?> _series(String aid, {String? fallbackTitle, CancelToken? cancelToken}) async {
    final m = Hive.isBoxOpen('session') ? _box.get('bgm:$aid') as Map? : null;
    if (m != null && m['id'] != 0) {
      // 加外传之前存的只有主系列：补查一次外传
      if (m['x'] == null) await _box.put('bgm:$aid', {...m, 'x': await _extras(await _relations(m['id'] as int, cancelToken: cancelToken), cancelToken: cancelToken)});
      return saved(aid);
    }
    if (m != null && DateTime.now().millisecondsSinceEpoch - (m['t'] as int) < const Duration(days: 30).inMilliseconds) return null;
    final title = bookTitle(aid) ?? fallbackTitle;
    if (title == null || title.trim().isEmpty) return null;
    // 有两个译名时先用拆开的（Bangumi 上的中文名多是其中一个），再用整个书名；
    // 优先匹配系列小说（series == true），都未命中时兜底匹配单卷小说（platform == '小说'）。
    Map? fallbackSingle;
    for (final k in {...titleAlternatives(title), title}) {
      final r = await _request(() => _dio.post<Map>('$_api/search/subjects', queryParameters: {'limit': 10}, data: {'keyword': k, 'filter': {'type': [1]}}, cancelToken: cancelToken));
      final list = ((r.data?['data'] as List?) ?? const []).cast<Map>();
      final hit = pickBgmNovelHit(list);
      if (hit == null) continue;
      if (hit['series'] == true) {
        return _saveSeriesHit(aid, hit, cancelToken: cancelToken);
      }
      fallbackSingle ??= hit;
    }
    if (fallbackSingle != null) {
      return _saveSeriesHit(aid, fallbackSingle, cancelToken: cancelToken);
    }
    if (Hive.isBoxOpen('session')) await _box.put('bgm:$aid', {'id': 0, 't': DateTime.now().millisecondsSinceEpoch});
    return null;
  }

  Future<BgmSeries?> _saveSeriesHit(String aid, Map hit, {CancelToken? cancelToken}) async {
    final id = (hit['id'] as num).toInt();
    final rel = await _relations(id, cancelToken: cancelToken);
    final vols = _vols(rel);
    // 单卷小说没有「单行本」子条目，兜底把自身封面作为第 1 卷
    final resolvedVols = vols.isEmpty && _img(hit).isNotEmpty ? [{'n': (hit['name'] as String?) ?? '', 'i': _img(hit)}] : vols;
    final extras = await _extras(rel, cancelToken: cancelToken);
    if (Hive.isBoxOpen('session')) {
      await _box.put('bgm:$aid', {'id': id, 'name': _nameOf(hit), 'vols': resolvedVols, 'x': extras, 't': DateTime.now().millisecondsSinceEpoch});
      return saved(aid);
    }
    return (
      id: id,
      name: _nameOf(hit),
      vols: [for (final v in resolvedVols) (name: v['n'] as String, img: v['i'] as String)],
      extras: [
        for (final x in extras)
          (name: x['n'] as String, cn: x['c'] as String, img: x['i'] as String, vols: [for (final v in ((x['v'] as List?) ?? const []).cast<Map>()) (name: v['n'] as String, img: v['i'] as String)]),
      ],
    );
  }

  static String _nameOf(Map s) => (s['name_cn'] as String?)?.isNotEmpty ?? false ? s['name_cn'] as String : s['name'] as String;

  static String _img(Map s) => (s['images'] as Map?)?['large'] as String? ?? '';

  Future<List<Map>> _relations(int id, {CancelToken? cancelToken}) async =>
      ((await _request(() => _dio.get<List>('$_api/subjects/$id/subjects', cancelToken: cancelToken))).data ?? const []).cast<Map>();

  static List<Map> _vols(List<Map> rel) => [
    for (final s in rel)
      if (s['relation'] == '单行本' && _img(s).isNotEmpty) {'n': s['name'] as String, 'i': _img(s)},
  ];

  /// 「番外篇」里的小说外传（漫画、游戏、画集不要）：外传系列取它的单行本，单本取它自己的封面。
  /// 单条外传独立 try/catch，局部失败不影响其余外传与主系列结果落盘。
  Future<List<Map>> _extras(List<Map> rel, {CancelToken? cancelToken}) async {
    final candidates = rel.where((s) => s['relation'] == '番外篇' && s['type'] == 1).take(30).toList();
    final out = <Map>[];
    for (var i = 0; i < candidates.length; i += 4) {
      final batch = candidates.sublist(i, i + 4 > candidates.length ? candidates.length : i + 4);
      final items = await Future.wait(batch.map((s) async {
        try {
          final d = (await _request(() => _dio.get<Map>('$_api/subjects/${s['id']}', cancelToken: cancelToken))).data ?? const {};
          if (d['platform'] != '小说') return null;
          final vols = d['series'] == true ? _vols(await _relations(s['id'] as int, cancelToken: cancelToken)) : const <Map>[];
          if (vols.isEmpty && _img(d).isEmpty) return null;
          return <String, Object>{'n': d['name'] as String, 'c': (d['name_cn'] as String?) ?? '', 'i': _img(d), 'v': vols};
        } catch (_) {
          return null;
        }
      }));
      out.addAll(items.whereType<Map>());
    }
    return out;
  }
}

final bangumiProvider = Provider<BangumiCovers>((ref) {
  final store = ref.watch(sessionStoreProvider);
  ref.watch(proxyProvider);
  ref.watch(nativeNetProvider);
  // Bangumi 要求带上说明是哪个程序的 User-Agent
  final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 10), receiveTimeout: const Duration(seconds: 20), headers: {'User-Agent': 'ark_novel (https://github.com/chenshi221/ark_novel)'}))
    ..httpClientAdapter = store.adapter();
  ref.onDispose(() => dio.close(force: true));
  return BangumiCovers(dio);
});
