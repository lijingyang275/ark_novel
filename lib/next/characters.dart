import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show ValueNotifier, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'bangumi.dart';
import 'files.dart';
import 'progress.dart';
import 'rules.dart';
import 'session.dart';
import 'sync.dart';
import 'volumes.dart';

/// 人物高亮自动分配精选色板：避开在浅色纸面发虚的亮黄/荧光黄绿，保持柔和但高对比度。
const characterHighlightColors = <int>[
  0xFFC62828, // 深红
  0xFF1565C0, // 钴蓝
  0xFF2E7D32, // 森林绿
  0xFF6A1B9A, // 深紫
  0xFF00695C, // 青绿
  0xFFD84315, // 焦橙
  0xFFAD1457, // 玫红
  0xFF283593, // 靛蓝
  0xFF4E342E, // 咖啡棕
  0xFF0277BD, // 海蓝
  0xFF558B2F, // 橄榄绿
  0xFF8E24AA, // 兰紫
  0xFFBF360C, // 砖红
  0xFF37474F, // 蓝灰
];

/// 常见三字日本姓氏（无空格原名时用于精准切分 3+2 / 3+1 中文全名，避免误切）。
const _threeCharSurnames = <String>{
  '小佐内', '八奈见', '长谷川', '佐佐木', '五十岚', '宇佐美', '二阶堂', '一之濑', '五日市', '真木岛',
  '大久保', '小野寺', '小笠原', '伊集院', '西园寺', '东海林', '波多野', '阿波连', '久保田', '小日向',
  '小早川', '小山田', '雪之下', '比企谷', '由比滨', '四之宫', '千反田', '战场原', '八九寺', '斧乃木',
  '小木曾', '霞之丘', '伊井野', '牧之原', '绫小路', '轻井泽', '高圆寺', '九重', '佐々木', '長谷川',
  '五十嵐', '二階堂', '一ノ瀬', '西園寺', '阿波連',
};

/// 常见双字中文普通词停用表：自动拆分姓/名时跳过，防止把普通高频词误标成人名高亮。
const _commonWordStopList = <String>{
  '今天', '明天', '明日', '昨天', '世界', '未来', '希望', '青春', '初恋', '友情', '回忆', '秘密', '约定', '故事', '时光', '岁月',
  '学生', '老师', '同学', '前辈', '后辈', '学长', '学姐', '学弟', '学妹', '会长', '部长', '社长', '班长', '委员', '部员',
  '母亲', '父亲', '爸爸', '妈妈', '哥哥', '姐姐', '弟弟', '妹妹', '叔叔', '阿姨', '爷爷', '奶奶', '家人', '家庭',
  '先生', '小姐', '女士', '夫人', '少年', '少女', '男孩', '女孩', '男人', '女人', '大人', '小孩', '老人', '主角', '配角', '路人',
  '朋友', '大家', '自己', '时间', '时候', '地方', '东西', '问题', '事情', '关系', '生活', '学校', '教室', '心里', '手里',
  '天使', '恶魔', '神明', '魔王', '勇者', '公主', '王子', '骑士', '女仆', '执事', '管家', '侦探', '医生', '警察', '老板', '店长', '店员', '记者', '作家',
  '春夏', '秋冬', '太阳', '月亮', '星空', '大海', '天空', '森林', '微风', '阳光', '月光', '光明', '黑暗', '自由', '幸福', '快乐', '温柔', '正义', '勇气', '力量', '智慧',
};

/// 人物/设定定位常量。
class CharacterRole {
  const CharacterRole._();

  static const main = '主角';
  static const support = '配角';
  static const setting = '设定';
  static const all = [main, support, setting];

  /// 把 Bangumi 的角色定位映射为词典定位。
  static String fromBgmRelation(String relation) {
    final r = relation.trim();
    if (r.contains('主角')) return main;
    if (r.contains('设定') || r.contains('机械') || r.contains('组织')) return setting;
    return support;
  }
}

/// 书内人物或设定词条。
class BookCharacter {
  const BookCharacter({
    required this.id,
    required this.aid,
    required this.name,
    this.originalName = '',
    this.aliases = const [],
    this.role = CharacterRole.support,
    this.bgmId,
    this.avatarUrl = '',
    this.localAvatar = '',
    this.summary = '',
    this.cnSummary = '',
    this.spoilerVol = 0,
    this.color = 0xFFF9A825,
    this.ruleId = '',
    this.ts = 0,
  });

  final String id;
  final String aid;

  /// 显示中文名
  final String name;

  /// 日文/原名
  final String originalName;
  final List<String> aliases;

  /// 定位：主角 / 配角 / 设定
  final String role;
  final int? bgmId;

  /// Bangumi 角色图或书内插图 URL（可带 `#crop=`）
  final String avatarUrl;

  /// 本地裁剪头像相对文件名（位于 `ApplicationSupport/char_avatar/`）
  final String localAvatar;

  /// Bangumi 简介
  final String summary;

  /// 萌娘百科中文首段简介
  final String cnSummary;

  /// 0 表示不折叠，>0 表示读到该卷前折叠笔记防剧透
  final int spoilerVol;

  /// 高亮颜色（ARGB）
  final int color;

  /// 绑定的 `ReplaceRule.id`，空串表示未开启正文高亮
  final String ruleId;

  /// 修改时间戳（毫秒）
  final int ts;

  /// 与 `RuleNotes` 互通的备注键：优先使用绑定的 `ruleId`，未开高亮时使用稳定键 `chr_$id` 防止关闭高亮后丢失笔记。
  String get effectiveNoteKey => ruleId.isNotEmpty ? ruleId : 'chr_$id';

  /// 供 A-1 书内搜索使用的名称+别名列表（去重、按长度倒序）。
  List<String> get searchTerms => sortedNames(name, aliases);

  /// 当前阅读卷小于 [spoilerVol] 时折叠个人笔记防剧透。
  bool shouldHideSpoiler(int currentVol) => spoilerVol > 0 && currentVol < spoilerVol;

  /// 优先展示萌娘百科中文简介，其次 Bangumi 简介。
  String get preferredSummary => cnSummary.trim().isNotEmpty ? cnSummary.trim() : summary.trim();

  static List<String> sortedNames(String name, List<String> aliases) {
    final set = <String>{};
    for (final raw in [name, ...aliases]) {
      final s = raw.trim();
      if (s.isNotEmpty) set.add(s);
    }
    final list = set.toList()
      ..sort((a, b) {
        final c = b.length.compareTo(a.length);
        return c != 0 ? c : a.compareTo(b);
      });
    return list;
  }

  /// 按 `[name, ...aliases]` 长度倒序 `RegExp.escape` 后拼成 `A|B|C`。
  static String buildHighlightPattern(String name, List<String> aliases) => sortedNames(name, aliases).map(RegExp.escape).join('|');

  static final _cjkPureRe = RegExp(r'^[\u4e00-\u9fff]+$');
  static final _kanjiPrefixKanaSuffixRe = RegExp(r'^([\u4e00-\u9fff]{2,3})([\u3040-\u309F\u30A0-\u30FF]{2,})$');
  static final _spaceRe = RegExp(r'[\s\u3000]+');
  static final _kanaRe = RegExp(r'[\u3040-\u309F\u30A0-\u30FF]');
  static final _latinRe = RegExp(r'^[A-Za-z0-9\s._-]+$');

  static String _compact(String s) => s.replaceAll(_spaceRe, '').toLowerCase();

  /// 判断某条别名是否属于与原名/中文名重复的冗余项（例如 Bangumi `日文名` 带空格重复项 `小鳩 常悟朗`、`小佐内 ゆき`）。
  static bool isRedundantAlias(String alias, {required String name, String originalName = ''}) {
    final s = alias.trim();
    if (s.isEmpty) return true;
    final c = _compact(s);
    if (c == _compact(name)) return true;
    if (originalName.trim().isNotEmpty && c == _compact(originalName)) return true;
    // 含空白且带有日文假名或纯拉丁注音（如 `小佐内 ゆき`、`Kobato Jogoro`），在中文小说正文里几乎不会出现
    if (_spaceRe.hasMatch(s) && (_kanaRe.hasMatch(s) || _latinRe.hasMatch(s))) return true;
    return false;
  }

  /// 清理别名列表：去掉空白、与名称/原名重复的冗余日文带空格项，同时保留有意义的中文称呼/昵称。
  static List<String> cleanAliases(List<String> aliases, {required String name, String originalName = ''}) {
    final out = <String>[];
    final seen = <String>{};
    for (final raw in aliases) {
      final s = raw.trim();
      if (isRedundantAlias(s, name: name, originalName: originalName)) continue;
      if (seen.add(s)) out.add(s);
    }
    return out;
  }

  static bool _validCallTerm(String s) {
    final t = s.trim();
    if (t.length < 2) return false;
    if (_commonWordStopList.contains(t)) return false;
    return true;
  }

  /// 从中文全名（配合可选的带空格原名 [spacedOrig] 或无空格日文原名 [originalName]）推导常用的姓氏和名字。
  ///
  /// 规则：
  /// 1. 西式/音译名带中点（`艾莉丝·格雷拉特`）：拆出首段名与末段姓；
  /// 2. 中文名自带空格（`小佐内 由纪`）：直接按空格切分；
  /// 3. 纯汉字全名配合带空格原名（`小鳩 常悟朗` / `小佐内 ゆき` / `堂島 健吾`）：按原名空格边界精确切分；
  /// 4. 纯汉字全名配合「汉字姓+假名名」原名（`小佐内ゆき`、`真木島みどり`）：按汉字→假名边界切分；
  /// 5. 命中常见三字日本姓氏表，或 4 字纯汉字全名默认按 2+2 切分。
  static ({String? family, String? given}) splitChineseName(String nameCn, {String spacedOrig = '', String originalName = ''}) {
    final cn = nameCn.trim();
    if (cn.length < 3) return (family: null, given: null);

    // 1. 中点分隔的西式音译名（如 `艾莉丝·格雷拉特`）
    if (cn.contains('·') || cn.contains('・')) {
      final parts = cn.split(RegExp(r'[·・]')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      if (parts.length >= 2) {
        final given = _validCallTerm(parts.first) ? parts.first : null;
        final family = parts.length == 2 && _validCallTerm(parts.last) ? parts.last : null;
        return (family: family, given: given);
      }
    }

    // 2. 中文名自身带空格
    if (_spaceRe.hasMatch(cn)) {
      final parts = cn.split(_spaceRe).where((e) => e.isNotEmpty).toList();
      if (parts.length == 2) {
        return (family: _validCallTerm(parts[0]) ? parts[0] : null, given: _validCallTerm(parts[1]) ? parts[1] : null);
      }
    }

    if (!_cjkPureRe.hasMatch(cn) || cn.length < 4 || cn.length > 6) {
      return (family: null, given: null);
    }

    // 3. 借助 Bangumi infobox 的带空格日文名/假名精准定位姓氏与名字边界
    final spaced = spacedOrig.trim();
    if (spaced.isNotEmpty && _spaceRe.hasMatch(spaced)) {
      final parts = spaced.split(_spaceRe).where((e) => e.isNotEmpty).toList();
      if (parts.length == 2) {
        final a = parts[0].length;
        final b = parts[1].length;
        if (a + b == cn.length && a >= 1 && b >= 1) {
          final fam = cn.substring(0, a);
          final giv = cn.substring(a);
          return (family: _validCallTerm(fam) ? fam : null, given: _validCallTerm(giv) ? giv : null);
        }
        // 姓为汉字、名为假名导致音节长度不等（如 `小佐内 ゆき` 3+2 对应 4 字译名 `小佐内雪`）
        if (_cjkPureRe.hasMatch(parts[0]) && a >= 2 && a <= 3 && cn.length - a >= 1) {
          final fam = cn.substring(0, a);
          final giv = cn.substring(a);
          return (family: _validCallTerm(fam) ? fam : null, given: _validCallTerm(giv) ? giv : null);
        }
      }
    }

    // 4. 无空格原名但呈「汉字姓 + 假名名」（如 `小佐内ゆき`、`真木島みどり`）
    final origCompact = originalName.trim().replaceAll(_spaceRe, '');
    final km = _kanjiPrefixKanaSuffixRe.firstMatch(origCompact);
    if (km != null) {
      final famLen = km.group(1)!.length;
      if (cn.length > famLen) {
        final fam = cn.substring(0, famLen);
        final giv = cn.substring(famLen);
        return (family: _validCallTerm(fam) ? fam : null, given: _validCallTerm(giv) ? giv : null);
      }
    }

    // 5. 常见三字日本姓氏匹配（如 `小佐内由纪`、`八奈见杏菜`、`雪之下雪乃`）
    if (cn.length >= 4) {
      final head3 = cn.substring(0, 3);
      if (_threeCharSurnames.contains(head3)) {
        final giv = cn.substring(3);
        return (family: _validCallTerm(head3) ? head3 : null, given: _validCallTerm(giv) ? giv : null);
      }
    }

    // 6. 四字纯汉字全名默认按 2+2 切分（如 `堂岛健吾`、`温水和彦`）
    if (cn.length == 4) {
      final fam = cn.substring(0, 2);
      final giv = cn.substring(2);
      return (family: _validCallTerm(fam) ? fam : null, given: _validCallTerm(giv) ? giv : null);
    }

    return (family: null, given: null);
  }

  /// 为整本书的一批人物批量清理冗余日文别名并推导中文姓/名称呼，自动避开多角色同姓冲突：
  /// - 仅一位主角与配角共用姓氏（如 `小佐内由纪` 与 `小佐内母`）时，姓氏称呼优先归属主角；
  /// - 同层级多位角色同姓（如 `堂岛健吾` 与 `堂岛知里`）时，丢弃有歧义的共享姓氏，各自保留唯一名字；
  /// - 绝不把其他角色的全名当作当前角色的派生别名。
  static List<List<String>> deriveCallNamesForBatch(
    List<({String name, String originalName, String spacedName, String role, List<String> aliases})> batch,
  ) {
    final fullNames = {for (final item in batch) item.name.trim()};
    final splits = [
      for (final item in batch) splitChineseName(item.name, spacedOrig: item.spacedName, originalName: item.originalName),
    ];

    // 统计每个候选称呼在全书中被哪些角色提名
    final famOwners = <String, List<int>>{};
    final givOwners = <String, List<int>>{};
    for (var i = 0; i < batch.length; i++) {
      final sp = splits[i];
      if (sp.family != null) famOwners.putIfAbsent(sp.family!, () => []).add(i);
      if (sp.given != null) givOwners.putIfAbsent(sp.given!, () => []).add(i);
      // 同时识别像「小佐内母」这种以另一角色姓氏开头的称谓，防止它误抢姓氏
      final trimmedName = batch[i].name.trim();
      for (final fam in famOwners.keys.toList()) {
        if (trimmedName.startsWith(fam) && trimmedName != fam && !famOwners[fam]!.contains(i)) {
          famOwners[fam]!.add(i);
        }
      }
    }
    // 再补扫一遍确保顺序无关
    for (var i = 0; i < batch.length; i++) {
      final trimmedName = batch[i].name.trim();
      for (final entry in famOwners.entries) {
        if (trimmedName.startsWith(entry.key) && trimmedName != entry.key && !entry.value.contains(i)) {
          entry.value.add(i);
        }
      }
    }

    bool canOwn(String term, int idx, Map<String, List<int>> ownersMap) {
      if (fullNames.contains(term) && batch[idx].name.trim() != term) return false;
      final owners = ownersMap[term] ?? const [];
      if (owners.length <= 1) return true;
      // 多人共享时：仅当恰好有一位主角占有该称呼，才只赋予这位主角
      final mainOwners = [for (final o in owners) if (batch[o].role == CharacterRole.main) o];
      return mainOwners.length == 1 && mainOwners.single == idx;
    }

    return [
      for (var i = 0; i < batch.length; i++)
        () {
          final item = batch[i];
          // 保留用户/Bangumi 原始非冗余别名；若别名里曾混入带空格日文名则顺便清理
          final cleaned = cleanAliases(item.aliases, name: item.name, originalName: item.originalName);
          final out = <String>[...cleaned];
          final sp = splits[i];
          void tryAdd(String? term, Map<String, List<int>> map) {
            if (term == null || term.isEmpty || term == item.name.trim()) return;
            if (!canOwn(term, i, map)) return;
            if (!out.contains(term)) out.add(term);
          }

          tryAdd(sp.family, famOwners);
          tryAdd(sp.given, givOwners);
          return out;
        }(),
    ];
  }

  BookCharacter copyWith({
    String? id,
    String? aid,
    String? name,
    String? originalName,
    List<String>? aliases,
    String? role,
    int? bgmId,
    bool clearBgmId = false,
    String? avatarUrl,
    String? localAvatar,
    String? summary,
    String? cnSummary,
    int? spoilerVol,
    int? color,
    String? ruleId,
    int? ts,
  }) => BookCharacter(
    id: id ?? this.id,
    aid: aid ?? this.aid,
    name: name ?? this.name,
    originalName: originalName ?? this.originalName,
    aliases: aliases ?? this.aliases,
    role: role ?? this.role,
    bgmId: clearBgmId ? null : (bgmId ?? this.bgmId),
    avatarUrl: avatarUrl ?? this.avatarUrl,
    localAvatar: localAvatar ?? this.localAvatar,
    summary: summary ?? this.summary,
    cnSummary: cnSummary ?? this.cnSummary,
    spoilerVol: spoilerVol ?? this.spoilerVol,
    color: color ?? this.color,
    ruleId: ruleId ?? this.ruleId,
    ts: ts ?? this.ts,
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'aid': aid,
    'name': name,
    'orig': originalName,
    'aliases': aliases,
    'role': role,
    if (bgmId != null) 'bgmId': bgmId,
    'avatar': avatarUrl,
    'localAvatar': localAvatar,
    'summary': summary,
    'cnSummary': cnSummary,
    'spoilerVol': spoilerVol,
    'color': color,
    'ruleId': ruleId,
    'ts': ts,
  };

  factory BookCharacter.fromMap(Map m, {String? fallbackAid}) => BookCharacter(
    id: (m['id'] as String?) ?? '',
    aid: (m['aid'] as String?) ?? fallbackAid ?? '',
    name: (m['name'] as String?) ?? '',
    originalName: (m['orig'] as String?) ?? (m['originalName'] as String?) ?? '',
    aliases: ((m['aliases'] as List?) ?? const []).whereType<String>().toList(),
    role: (m['role'] as String?)?.isNotEmpty == true ? m['role'] as String : CharacterRole.support,
    bgmId: (m['bgmId'] as num?)?.toInt(),
    avatarUrl: (m['avatar'] as String?) ?? (m['avatarUrl'] as String?) ?? '',
    localAvatar: (m['localAvatar'] as String?) ?? '',
    summary: (m['summary'] as String?) ?? '',
    cnSummary: (m['cnSummary'] as String?) ?? '',
    spoilerVol: (m['spoilerVol'] as num?)?.toInt() ?? 0,
    color: (m['color'] as num?)?.toInt() ?? ruleColors[2],
    ruleId: (m['ruleId'] as String?) ?? '',
    ts: (m['ts'] as num?)?.toInt() ?? 0,
  );
}

/// 人物 / 设定词典存储（`Hive.box('session')` 键 `chars:$aid`），并与 `ReplaceRules` / `RuleNotes` 互通。
class BookCharacters {
  BookCharacters._();

  static Box get _box => Hive.box('session');
  static final changes = ValueNotifier<int>(0);
  static String? _avatarDirPath;
  static int _idSeq = 0;

  static String _newId() => 'ch_${DateTime.now().microsecondsSinceEpoch}_${++_idSeq}';

  static List<BookCharacter> of(String aid) {
    if (!Hive.isBoxOpen('session')) return const [];
    final raw = _box.get('chars:$aid') as List?;
    if (raw == null || raw.isEmpty) return const [];
    return [for (final m in raw.whereType<Map>()) BookCharacter.fromMap(m, fallbackAid: aid)];
  }

  static BookCharacter? byId(String aid, String id) {
    if (id.isEmpty) return null;
    for (final c in of(aid)) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// 阅读器点击正文高亮词时按 `ruleId` 查找对应人物词条。
  static BookCharacter? byRuleId(String aid, String ruleId) {
    if (ruleId.isEmpty) return null;
    for (final c in of(aid)) {
      if (c.ruleId == ruleId) return c;
    }
    return null;
  }

  static String noteOf(BookCharacter c) {
    if (!Hive.isBoxOpen('session')) return '';
    return RuleNotes.get(c.aid, c.effectiveNoteKey);
  }

  static Future<void> setNote(BookCharacter c, String text) async {
    await RuleNotes.set(c.aid, c.effectiveNoteKey, text);
    changes.value++;
  }

  /// 判断当前人物是否实际开启了正文高亮（绑定了启用的 `ReplaceRule`）。
  static bool isHighlightActive(BookCharacter c) {
    if (c.ruleId.isEmpty || !Hive.isBoxOpen('session')) return false;
    return ReplaceRules.all().any((r) => r.id == c.ruleId && r.enabled && r.kind != RuleKind.replace);
  }

  /// 计算当前书籍的阅读卷号（从 1 开始；未开始阅读返回 0）。
  static int currentReadingVolume(String aid, {String? currentCid}) {
    if (!Hive.isBoxOpen('session')) return 0;
    final cid = currentCid ?? ReadingProgress.of(aid)?.cid;
    if (cid == null || cid.isEmpty) return 0;
    final vols = Volumes.of(aid);
    final idx = vols.indexWhere((v) => v.cids.contains(cid));
    if (idx < 0) return 0;
    return wenkuVolumeNumber(vols[idx].title) ?? (idx + 1);
  }

  /// 新增或更新一个人物/设定词条，可选同步维护绑定的正文高亮规则与备注。
  static Future<BookCharacter> upsert(BookCharacter input, {bool? enableHighlight, String? note}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = input.id.isEmpty ? _newId() : input.id;
    var char = input.copyWith(id: id, ts: now);
    final list = List<BookCharacter>.of(of(char.aid));
    final existingIdx = list.indexWhere((c) => c.id == id);
    final old = existingIdx >= 0 ? list[existingIdx] : null;
    final wantHighlight = enableHighlight ?? char.ruleId.isNotEmpty;

    final rules = ReplaceRules.all();
    var rulesChanged = false;

    if (wantHighlight) {
      final pattern = BookCharacter.buildHighlightPattern(char.name, char.aliases);
      if (pattern.isNotEmpty) {
        final targetRuleId = char.ruleId.isNotEmpty ? char.ruleId : 'chr_$id';
        final nextRule = ReplaceRule(
          id: targetRuleId,
          aid: char.aid,
          kind: RuleKind.highlight,
          pattern: pattern,
          replacement: '',
          name: char.name,
          color: char.color,
          enabled: true,
        );
        final ri = rules.indexWhere((r) => r.id == targetRuleId);
        if (ri >= 0) {
          rules[ri] = nextRule;
        } else {
          rules.add(nextRule);
        }
        rulesChanged = true;
        char = char.copyWith(ruleId: targetRuleId);
      }
    } else if (char.ruleId.isNotEmpty || (old != null && old.ruleId.isNotEmpty)) {
      final oldRuleId = char.ruleId.isNotEmpty ? char.ruleId : old!.ruleId;
      final stableKey = 'chr_$id';
      if (oldRuleId != stableKey) {
        final oldNote = RuleNotes.get(char.aid, oldRuleId);
        if (oldNote.isNotEmpty && RuleNotes.get(char.aid, stableKey).isEmpty) {
          await RuleNotes.set(char.aid, stableKey, oldNote);
        }
        if (oldNote.isNotEmpty) await RuleNotes.set(char.aid, oldRuleId, '');
      }
      final beforeLen = rules.length;
      rules.removeWhere((r) => r.id == oldRuleId);
      if (rules.length != beforeLen) rulesChanged = true;
      char = char.copyWith(ruleId: '');
    }

    if (rulesChanged) await ReplaceRules.save(rules);
    if (note != null) await RuleNotes.set(char.aid, char.effectiveNoteKey, note);

    if (existingIdx >= 0) {
      list[existingIdx] = char;
    } else {
      list.add(char);
    }
    await _box.put('chars:${char.aid}', [for (final c in list) c.toMap()]);
    changes.value++;
    return char;
  }

  /// 批量导入人物（一次性写入词典与高亮规则）。
  /// 可通过 [shouldHighlight] 按角色精细决定哪些角色开启正文高亮（默认沿用 [enableHighlight]）。
  static Future<List<BookCharacter>> importMany(
    String aid,
    List<BookCharacter> inputs, {
    bool enableHighlight = true,
    bool Function(BookCharacter c)? shouldHighlight,
  }) async {
    if (inputs.isEmpty) return const [];
    final now = DateTime.now().millisecondsSinceEpoch;
    final list = List<BookCharacter>.of(of(aid));
    final rules = ReplaceRules.all();
    var rulesChanged = false;
    final added = <BookCharacter>[];

    for (final raw in inputs) {
      final id = raw.id.isEmpty ? _newId() : raw.id;
      var char = raw.copyWith(id: id, aid: aid, ts: now);
      final wantHl = shouldHighlight != null ? shouldHighlight(char) : enableHighlight;
      if (wantHl) {
        final pattern = BookCharacter.buildHighlightPattern(char.name, char.aliases);
        if (pattern.isNotEmpty) {
          final targetRuleId = char.ruleId.isNotEmpty ? char.ruleId : 'chr_$id';
          final rule = ReplaceRule(
            id: targetRuleId,
            aid: aid,
            kind: RuleKind.highlight,
            pattern: pattern,
            replacement: '',
            name: char.name,
            color: char.color,
            enabled: true,
          );
          final ri = rules.indexWhere((r) => r.id == targetRuleId);
          if (ri >= 0) {
            rules[ri] = rule;
          } else {
            rules.add(rule);
          }
          rulesChanged = true;
          char = char.copyWith(ruleId: targetRuleId);
        }
      }
      final existingIdx = list.indexWhere((c) => c.id == id);
      if (existingIdx >= 0) {
        list[existingIdx] = char;
      } else {
        list.add(char);
      }
      added.add(char);
    }

    if (rulesChanged) await ReplaceRules.save(rules);
    await _box.put('chars:$aid', [for (final c in list) c.toMap()]);
    changes.value++;
    return added;
  }

  /// 批量按条件切换整本书人物的正文高亮（单次落盘，关闭高亮时自动保留个人笔记）。
  static Future<void> setHighlightForAll(String aid, {required bool Function(BookCharacter c) predicate}) async {
    final list = List<BookCharacter>.of(of(aid));
    if (list.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final rules = ReplaceRules.all();
    var rulesChanged = false;
    var charsChanged = false;

    for (var i = 0; i < list.length; i++) {
      final c = list[i];
      final want = predicate(c);
      final active = c.ruleId.isNotEmpty && rules.any((r) => r.id == c.ruleId && r.enabled && r.kind != RuleKind.replace);
      if (want && !active) {
        final pattern = BookCharacter.buildHighlightPattern(c.name, c.aliases);
        if (pattern.isEmpty) continue;
        final targetRuleId = c.ruleId.isNotEmpty ? c.ruleId : 'chr_${c.id}';
        final nextRule = ReplaceRule(
          id: targetRuleId,
          aid: aid,
          kind: RuleKind.highlight,
          pattern: pattern,
          replacement: '',
          name: c.name,
          color: c.color,
          enabled: true,
        );
        final ri = rules.indexWhere((r) => r.id == targetRuleId);
        if (ri >= 0) {
          rules[ri] = nextRule;
        } else {
          rules.add(nextRule);
        }
        rulesChanged = true;
        list[i] = c.copyWith(ruleId: targetRuleId, ts: now);
        charsChanged = true;
      } else if (!want && (c.ruleId.isNotEmpty || active)) {
        final oldRuleId = c.ruleId;
        final stableKey = 'chr_${c.id}';
        if (oldRuleId.isNotEmpty && oldRuleId != stableKey) {
          final oldNote = RuleNotes.get(aid, oldRuleId);
          if (oldNote.isNotEmpty && RuleNotes.get(aid, stableKey).isEmpty) {
            await RuleNotes.set(aid, stableKey, oldNote);
          }
          if (oldNote.isNotEmpty) await RuleNotes.set(aid, oldRuleId, '');
        }
        final beforeLen = rules.length;
        rules.removeWhere((r) => r.id == oldRuleId);
        if (rules.length != beforeLen) rulesChanged = true;
        list[i] = c.copyWith(ruleId: '', ts: now);
        charsChanged = true;
      }
    }

    if (rulesChanged) await ReplaceRules.save(rules);
    if (charsChanged) {
      await _box.put('chars:$aid', [for (final c in list) c.toMap()]);
      changes.value++;
    }
  }

  /// 一键整理已有词条：清除冗余带空格日文别名、推导常用中文姓/名称呼、同步更新开启中的高亮规则。返回有变动的条数。
  static Future<int> normalizeExisting(String aid) async {
    final list = List<BookCharacter>.of(of(aid));
    if (list.isEmpty) return 0;
    final bgmCached = BangumiCovers.savedCharacters(aid) ?? const <BgmCharacter>[];
    final spacedByBgmId = {for (final b in bgmCached) if (b.spacedName.isNotEmpty) b.id: b.spacedName};

    final batch = [
      for (final c in list)
        (
          name: c.name,
          originalName: c.originalName,
          spacedName: (c.bgmId != null ? spacedByBgmId[c.bgmId!] : null) ??
              c.aliases.firstWhere((a) => RegExp(r'[\s\u3000]').hasMatch(a), orElse: () => ''),
          role: c.role,
          aliases: c.aliases,
        ),
    ];
    final derived = BookCharacter.deriveCallNamesForBatch(batch);

    final now = DateTime.now().millisecondsSinceEpoch;
    final rules = ReplaceRules.all();
    var rulesChanged = false;
    var updatedCount = 0;

    for (var i = 0; i < list.length; i++) {
      final c = list[i];
      final nextAliases = derived[i];
      final sameAliases = nextAliases.length == c.aliases.length && [for (var k = 0; k < nextAliases.length; k++) nextAliases[k] == c.aliases[k]].every((e) => e);
      if (sameAliases) continue;
      final next = c.copyWith(aliases: nextAliases, ts: now);
      list[i] = next;
      updatedCount++;
      if (next.ruleId.isNotEmpty) {
        final ri = rules.indexWhere((r) => r.id == next.ruleId);
        if (ri >= 0) {
          rules[ri] = rules[ri].copyWith(pattern: BookCharacter.buildHighlightPattern(next.name, next.aliases));
          rulesChanged = true;
        }
      }
    }

    if (rulesChanged) await ReplaceRules.save(rules);
    if (updatedCount > 0) {
      await _box.put('chars:$aid', [for (final c in list) c.toMap()]);
      changes.value++;
    }
    return updatedCount;
  }

  /// 批量删除指定 id 集合的人物词条，同步移除对应高亮规则、笔记、本地头像并记录墓碑。
  static Future<int> deleteMany(String aid, Set<String> ids) async {
    if (ids.isEmpty) return 0;
    final list = List<BookCharacter>.of(of(aid));
    final removed = <BookCharacter>[];
    list.removeWhere((c) {
      if (ids.contains(c.id)) {
        removed.add(c);
        return true;
      }
      return false;
    });
    if (removed.isEmpty) return 0;

    final removeRuleIds = {for (final r in removed) if (r.ruleId.isNotEmpty) r.ruleId};
    if (removeRuleIds.isNotEmpty) {
      final rules = ReplaceRules.all();
      final next = [for (final r in rules) if (!removeRuleIds.contains(r.id)) r];
      if (next.length != rules.length) await ReplaceRules.save(next);
    }
    for (final r in removed) {
      if (r.ruleId.isNotEmpty) await RuleNotes.set(aid, r.ruleId, '');
      await RuleNotes.set(aid, 'chr_${r.id}', '');
      if (r.localAvatar.isNotEmpty) await deleteLocalAvatar(r.localAvatar);
    }
    await Sync.tombstone([for (final r in removed) 'ch:$aid:${r.id}']);
    await _box.put('chars:$aid', [for (final c in list) c.toMap()]);
    changes.value++;
    return removed.length;
  }

  /// 删除一个人物词条：移除绑定高亮规则与备注、清理本地裁剪头像、记录 `ch:$aid:$id` 墓碑。
  static Future<void> delete(String aid, String id) async {
    final list = List<BookCharacter>.of(of(aid));
    final idx = list.indexWhere((c) => c.id == id);
    if (idx < 0) return;
    final removed = list.removeAt(idx);

    if (removed.ruleId.isNotEmpty) {
      final rules = ReplaceRules.all();
      final next = [for (final r in rules) if (r.id != removed.ruleId) r];
      if (next.length != rules.length) await ReplaceRules.save(next);
      await RuleNotes.set(aid, removed.ruleId, '');
    }
    await RuleNotes.set(aid, 'chr_$id', '');
    if (removed.localAvatar.isNotEmpty) await deleteLocalAvatar(removed.localAvatar);
    await Sync.tombstone(['ch:$aid:$id']);
    await _box.put('chars:$aid', [for (final c in list) c.toMap()]);
    changes.value++;
  }

  // ---- 本地裁剪头像（ApplicationSupport/char_avatar/）----

  static Future<Directory> avatarDir() async {
    final path = _avatarDirPath ??= p.join((await getApplicationSupportDirectory()).path, 'char_avatar');
    return Directory(path).create(recursive: true);
  }

  /// 初始化目录缓存，方便列表页同步解析本地头像文件而不闪烁。
  static Future<void> ensureAvatarDirLoaded() async {
    if (kIsWeb || _avatarDirPath != null) return;
    try {
      _avatarDirPath = p.join((await getApplicationSupportDirectory()).path, 'char_avatar');
    } catch (_) {}
  }

  /// 同步解析本地头像文件（未加载路径或不存在时返回 null）。
  static File? localAvatarFileSync(String fileName) {
    if (kIsWeb || fileName.isEmpty || _avatarDirPath == null) return null;
    final f = File(p.join(_avatarDirPath!, p.basename(fileName)));
    return f.existsSync() ? f : null;
  }

  static Future<File?> resolveLocalAvatar(String fileName) async {
    if (kIsWeb || fileName.isEmpty) return null;
    await ensureAvatarDirLoaded();
    return localAvatarFileSync(fileName);
  }

  static Future<String> saveLocalAvatar(String charId, Uint8List bytes, {String ext = '.png'}) async {
    final dir = await avatarDir();
    final safeExt = ext.startsWith('.') ? ext : '.$ext';
    final safeId = charId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final fileName = '${safeId}_${DateTime.now().millisecondsSinceEpoch}$safeExt';
    final file = File(p.join(dir.path, fileName));
    await writeFileAtomic(file, bytes);
    return fileName;
  }

  static Future<void> deleteLocalAvatar(String fileName) async {
    if (kIsWeb || fileName.isEmpty) return;
    try {
      final f = await resolveLocalAvatar(fileName);
      if (f != null && await f.exists()) await f.delete();
    } catch (_) {}
  }
}

/// 词典变更通知 provider。
final bookCharactersChangesProvider = Provider<int>((ref) {
  void listener() => ref.invalidateSelf();
  BookCharacters.changes.addListener(listener);
  ref.onDispose(() => BookCharacters.changes.removeListener(listener));
  return BookCharacters.changes.value;
});

/// 萌娘百科轻量纯文本首段接口（仅走 `action=query&prop=extracts&exintro=1&explaintext=1`，不抓图、不碰 `action=parse`）。
class MoegirlApi {
  MoegirlApi(this._dio);

  final Dio _dio;

  static final _kanaRe = RegExp(r'[\u3040-\u309F\u30A0-\u30FF\uFF66-\uFF9F]');

  /// 判断一段简介是否以日文为主（含较多平假名/片假名）。
  static bool isMostlyJapanese(String text) {
    final compact = text.replaceAll(RegExp(r'\s+'), '');
    if (compact.isEmpty) return false;
    final kana = _kanaRe.allMatches(compact).length;
    return kana >= 3 && (kana >= 6 || kana * 10 >= compact.length);
  }

  /// 是否需要展示「获取萌娘百科中文简介」按钮：中文简介为空，且原简介为空或以日文为主。
  static bool needsCnSummary(String summary, String cnSummary) => cnSummary.trim().isEmpty && (summary.trim().isEmpty || isMostlyJapanese(summary));

  /// 外部浏览器打开的萌娘百科页面链接。
  static Uri pageUrl(String title) => Uri.https('zh.moegirl.org.cn', '/${title.trim()}');

  /// 解析 MediaWiki `action=query&prop=extracts&exintro=1&explaintext=1&format=json` 响应，返回纯文本首段；未命中返回 null。
  static String? parseExtract(Object? data) {
    if (data is! Map) return null;
    final query = data['query'];
    if (query is! Map) return null;
    final pages = query['pages'];
    if (pages is! Map || pages.isEmpty) return null;
    for (final entry in pages.entries) {
      if ('${entry.key}' == '-1') continue;
      final page = entry.value;
      if (page is! Map || page.containsKey('missing')) continue;
      final raw = (page['extract'] as String?)?.trim() ?? '';
      if (raw.isEmpty) continue;
      final cleaned = raw.replaceAll(RegExp(r'\r\n?'), '\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
      if (cleaned.isNotEmpty) return cleaned;
    }
    return null;
  }

  /// 按简体中文名查询萌娘百科纯文本中文首段。
  Future<String?> fetchIntro(String title) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return null;
    final res = await _dio.get<Map>(
      'https://zh.moegirl.org.cn/api.php',
      queryParameters: {
        'action': 'query',
        'titles': trimmed,
        'prop': 'extracts',
        'exintro': 1,
        'explaintext': 1,
        'redirects': 1,
        'format': 'json',
      },
    );
    return parseExtract(res.data);
  }
}

final moegirlApiProvider = Provider<MoegirlApi>((ref) {
  final store = ref.watch(sessionStoreProvider);
  ref.watch(proxyProvider);
  ref.watch(nativeNetProvider);
  final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 10), receiveTimeout: const Duration(seconds: 15), headers: {'User-Agent': 'ark_novel (https://github.com/chenshi221/ark_novel)'}))
    ..httpClientAdapter = store.adapter();
  ref.onDispose(dio.close);
  return MoegirlApi(dio);
});
