import 'dart:async';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import '../data/wenku8/wenku8_client.dart';
import '../data/wenku8/wenku8_exceptions.dart';
import 'catalog.dart';
import 'data.dart';
import 'progress.dart';
import 'session.dart';
import 'sync.dart';

/// 有多个译名的书，网站把第二个译名用括号包在书名最后：「败北女角太多了！(败犬女主太多了！)」。
/// 拆成 [前面的, 括号里的] 给改名时挑；只看最后一组括号（前面的括号是书名本身的一部分），拆不出两个返回空。
List<String> titleAlternatives(String title) {
  final t = title.trim();
  if (!t.endsWith(')') && !t.endsWith('）')) return const [];
  var depth = 0;
  for (var i = t.length - 1; i >= 0; i--) {
    final c = t[i];
    if (c == ')' || c == '）') depth++;
    if (c == '(' || c == '（') depth--;
    if (depth > 0) continue;
    String clean(String s) => s.replaceAll(RegExp(r'^[\s\-—–_]+|[\s\-—–_]+$'), '');
    final main = clean(t.substring(0, i)), alt = clean(t.substring(i + 1, t.length - 1));
    return main.isEmpty || alt.isEmpty || main == alt ? const [] : [main, alt];
  }
  return const [];
}

/// 本地书架里的一本书。书架页只读本地，网站书架只是定期对一下。
class LibBook {
  const LibBook({required this.aid, required this.title, required this.img, this.added = 0, this.cats = const [], this.bid, this.done = false, this.name, this.ts = 0});

  final String aid;
  final String title;
  final String img;

  /// 加入时间（毫秒）
  final int added;

  /// 所属分类 id，空表示在"默认"里
  final List<String> cats;

  /// 网站书架里这条记录的 id（在网站上移出要用）；null 表示还没同步到网站，或者只在本地
  final String? bid;

  /// 已完结（打开过详情页才知道）
  final bool done;

  /// 自己起的显示名称；null 用网站上的书名 [title]（同步、打开详情会更新 [title]，不动它）
  final String? name;

  /// 最近一次修改改名或分类的时间（毫秒），WebDAV 跨设备同步时按它决定哪边更新
  final int ts;

  String get shown => name ?? title;

  Map<String, Object?> toMap() => {'aid': aid, 'title': title, 'img': img, 'added': added, 'cats': cats, 'bid': bid, 'done': done, 'name': name, 'ts': ts};

  static LibBook fromMap(Map m) => LibBook(
    aid: m['aid'] as String,
    title: m['title'] as String,
    img: (m['img'] as String?) ?? '',
    added: (m['added'] as int?) ?? 0,
    cats: ((m['cats'] as List?) ?? const []).cast<String>(),
    bid: m['bid'] as String?,
    done: (m['done'] as bool?) ?? false,
    name: m['name'] as String?,
    ts: (m['ts'] as int?) ?? 0,
  );

  LibBook copyWith({String? title, String? img, List<String>? cats, String? bid, bool? done, int? ts}) =>
      LibBook(aid: aid, title: title ?? this.title, img: img ?? this.img, added: added, cats: cats ?? this.cats, bid: bid ?? this.bid, done: done ?? this.done, name: name, ts: ts ?? this.ts);

  LibBook withName(String? name, {int? ts}) => LibBook(aid: aid, title: title, img: img, added: added, cats: cats, bid: bid, done: done, name: name, ts: ts ?? this.ts);

  LibBook withoutBid() => LibBook(aid: aid, title: title, img: img, added: added, cats: cats, done: done, name: name, ts: ts);
}

class LibCategory {
  const LibCategory(this.id, this.name, [this.ts = 0]);

  final String id;
  final String name;
  final int ts;
}

/// 网站书架上的一本，[shelf] 是网站的书架分组 0~5。
typedef RemoteBook = ({String bid, String title, String img, int shelf});

/// 把网站书架对到本地，[ops] 是还没推到网站的本地操作（aid → add / remove）：
/// - 网站上有、本地没有、也不是本地刚移出的：加进本地；首次导入时网站书架 2~6 的书放进同名分类（`shelfN`）
/// - 本地同步过（有 bid）、网站上没了、也不是本地刚加入的：说明在网站上被移出了，本地也移出
/// - 网站整个是空的：多半是页面不对，不按它删本地的书
Map<String, LibBook> reconcile(Map<String, LibBook> local, Map<String, RemoteBook> remote, Map<String, String> ops, {required int now, bool firstImport = false}) {
  final out = <String, LibBook>{};
  for (final stored in local.values) {
    // 首次对当前账号：旧账号的 bid 不能用来判断这本书已从网站移出。
    final b = firstImport ? stored.withoutBid() : stored;
    final r = remote[b.aid];
    if (r != null) {
      out[b.aid] = b.copyWith(bid: r.bid, img: b.img.isEmpty ? r.img : null);
    } else if (b.bid == null || remote.isEmpty || ops[b.aid] == 'add') {
      out[b.aid] = b;
    }
  }
  for (final MapEntry(key: aid, value: r) in remote.entries) {
    if (out.containsKey(aid) || ops[aid] == 'remove') continue;
    out[aid] = LibBook(aid: aid, title: r.title, img: r.img, added: now, bid: r.bid, cats: firstImport && r.shelf > 0 ? ['shelf${r.shelf}'] : const []);
  }
  return out;
}

/// 网站书架对账移出的书里，上次对账（[since]）之后本机还读过的：要提示一下，可以加回来。
/// 网站不告诉什么时候移出的，只能拿上次对账的时间近似；第一次对账（[since] 为 0）不算。
List<LibBook> removedButRead(Map<String, LibBook> before, Map<String, LibBook> after, {required int since, required int Function(String aid) lastRead}) => [
  if (since > 0)
    for (final b in before.values)
      if (!after.containsKey(b.aid) && lastRead(b.aid) > since) b,
];

/// 加回书架的书：加入时间重新算（比删除的墓碑新，同步不会再删），分类只留还在的，自己起的名字照旧；
/// bid 清掉（网站上可能早就移出了），推到网站、下次对账再拿新的。
LibBook restoredBook(LibBook b, Set<String> cats, int now) =>
    LibBook(aid: b.aid, title: b.title, img: b.img, added: now, cats: [for (final c in b.cats) if (cats.contains(c)) c], done: b.done, name: b.name, ts: now);

Box get _box => Hive.box('session');

/// 不经 Riverpod 的只读查询（网页备份、图片缓存清理时判断哪些要留着）。
class LibraryStore {
  LibraryStore._();

  static Map get _raw => Hive.isBoxOpen('session') ? ((_box.get('lib:books') as Map?) ?? const {}) : const {};

  static bool contains(String aid) => _raw.containsKey(aid);

  static Map? get(String aid) => _raw[aid] as Map?;

  /// 书架上这本书的显示名称：自己改过名就是改的名字，否则 [fallback]（不在书架上也是 [fallback]）
  static String shown(String aid, String fallback) => (get(aid)?['name'] as String?) ?? fallback;

  static Iterable<String> aids() => _raw.keys.cast<String>();

  static Iterable<String> covers() => _raw.values.map((m) => ((m as Map)['img'] as String?) ?? '').where((e) => e.isNotEmpty);

  /// 同步时被移出书架（别的设备删了、网站书架上没了），但本机在那之后还读过的书。主界面看到就提示一下，可以一键加回（[LibraryController.restore]）。
  static final removedElsewhere = ValueNotifier<List<LibBook>>(const []);

  static void noteRemovedElsewhere(Iterable<LibBook> books) {
    final list = [...removedElsewhere.value];
    for (final b in books) {
      if (!list.any((e) => e.aid == b.aid)) list.add(b);
    }
    if (list.length != removedElsewhere.value.length) removedElsewhere.value = list;
  }
}

class LibraryState {
  const LibraryState(this.books, this.cats);

  final Map<String, LibBook> books;
  final List<LibCategory> cats;
}

/// 本地书架：加入 / 移出先改本地，再排队推到网站；[sync] 拉网站书架对一遍。分类只在本地。
class LibraryController extends Notifier<LibraryState> {
  // 同步合并完会重建这个 provider：放在实例上的话，新实例不知道旧实例还在推送，会同时推一遍
  static bool _syncing = false;
  static String? _flushingAid;

  @override
  LibraryState build() => _load();

  LibraryState _load() => LibraryState(
    {for (final e in ((_box.get('lib:books') as Map?) ?? const {}).entries) e.key as String: LibBook.fromMap(e.value as Map)},
    [for (final m in ((_box.get('lib:cats') as List?) ?? const []).cast<Map>()) LibCategory(m['id'] as String, m['name'] as String, (m['ts'] as int?) ?? 0)],
  );

  // WebDAV 已写入 Hive、但还没通知重建 provider 时，本地修改也必须基于最新数据。
  void _refresh() => state = _load();

  Future<void> _save(Map<String, LibBook> books, [List<LibCategory>? cats]) async {
    state = LibraryState(books, cats ?? state.cats);
    // Hive 在返回 Future 前就更新内存；书籍和分类一起提交，中间不 await，避免其他操作读到半份状态。
    await _box.putAll({
      'lib:books': {for (final b in books.values) b.aid: b.toMap()},
      if (cats != null) 'lib:cats': [for (final c in cats) {'id': c.id, 'name': c.name, 'ts': c.ts}],
    });
  }

  Map<String, Map> _ops() => ((_box.get('lib:ops') as Map?) ?? const {}).map((k, v) => MapEntry(k as String, Map.from(v as Map)));

  /// 把操作队列记到 [uid] 名下。队列还属于对过账的旧账号时先清空：旧账号的操作不能发给新账号，
  /// 而换号后在新账号下排的操作要留着。游客（从没对过账）排的操作照常保留。
  /// Hive 在返回前就更新了内存，调用后可以直接读 [_ops]。
  Future<void> _claimOps(String? uid) {
    if (uid == null || _box.get('lib:opsFor') == uid) return Future<void>.value();
    final owner = _box.get('lib:imported');
    return Future.wait([if (owner != null && owner != uid) _box.delete('lib:ops'), _box.put('lib:opsFor', uid)]);
  }

  String? get _uid => switch (ref.read(sessionProvider)) {
    SessionLoggedIn(:final user) => user.uid,
    _ => null,
  };

  /// 把一个操作并进 [ops]：加了又移（或反过来）且还没推到网站，两个操作抵消（正在推送中的那条不能抵消）。
  /// 移出又加回时返回原来的 bid（书还用它），否则返回 null。
  String? _enqueue(Map<String, Map> ops, String aid, Map op) {
    final prev = ops.remove(aid);
    if (_flushingAid == aid || prev == null || prev['op'] == op['op']) {
      ops[aid] = op;
      return null;
    }
    return prev['op'] == 'remove' && op['op'] == 'add' ? prev['bid'] as String? : null;
  }

  Future<void> _queue(String aid, Map op) async {
    final claiming = _claimOps(_uid);
    final ops = _ops();
    final bid = _enqueue(ops, aid, op);
    final saving = bid != null && state.books[aid] != null ? _save({...state.books, aid: state.books[aid]!.copyWith(bid: bid)}) : Future<void>.value();
    await Future.wait([claiming, saving, _box.put('lib:ops', ops)]);
  }

  Future<void> add(String aid, String title, String img, {List<String> cats = const []}) async {
    _refresh();
    if (state.books.containsKey(aid)) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    await Future.wait([
      _save({...state.books, aid: LibBook(aid: aid, title: title, img: img, added: now, cats: cats, ts: now)}),
      _queue(aid, {'op': 'add'}),
    ]);
    unawaited(_push());
  }

  Future<void> remove(Iterable<String> aids) async {
    _refresh();
    final books = {...state.books};
    final removed = <String>[];
    final claiming = _claimOps(_uid);
    final ops = _ops();
    for (final aid in aids) {
      final b = books.remove(aid);
      if (b != null) {
        removed.add('lib:$aid');
        _enqueue(ops, aid, {'op': 'remove', 'bid': b.bid});
      }
    }
    // 先在同一轮事件里提交全部改动，再等落盘；等待期间新增的书不能被旧 books 覆盖。
    await Future.wait([claiming, _save(books), _box.put('lib:ops', ops), Sync.tombstone(removed)]);
    unawaited(_push());
  }

  /// 把同步时被移出的书加回来（见 [LibraryStore.removedElsewhere]），分类和自己起的名字照旧。
  Future<void> restore(List<LibBook> books) async {
    _refresh();
    final now = DateTime.now().millisecondsSinceEpoch;
    final cats = {for (final c in state.cats) c.id};
    final back = [for (final b in books) if (!state.books.containsKey(b.aid)) restoredBook(b, cats, now)];
    if (back.isEmpty) return;
    // 不走 [_queue]：同步排的「移出」要直接换成「加入」，不能当成本机加了又移、互相抵消（网站上可能早就移出了）
    final claiming = _claimOps(_uid);
    await Future.wait([
      claiming,
      _save({...state.books, for (final b in back) b.aid: b}),
      _box.put('lib:ops', {..._ops(), for (final b in back) b.aid: {'op': 'add'}}),
    ]);
    unawaited(_push());
  }

  /// 改显示名称；空的或和原书名一样就恢复原名
  Future<void> rename(String aid, String? name) async {
    _refresh();
    final b = state.books[aid];
    if (b == null) return;
    final n = name?.trim();
    final now = DateTime.now().millisecondsSinceEpoch;
    await _save({...state.books, aid: b.withName(n == null || n.isEmpty || n == b.title ? null : n, ts: now)});
  }

  Future<void> setCats(Iterable<String> aids, List<String> cats) {
    _refresh();
    final now = DateTime.now().millisecondsSinceEpoch;
    return _save({...state.books, for (final aid in aids) if (state.books[aid] != null) aid: state.books[aid]!.copyWith(cats: cats, ts: now)});
  }

  /// 打开详情页拿到最新信息时顺手记下（书名、封面、是否完结）。
  Future<void> noteDetail(String aid, {required String title, required String img, required String status}) async {
    _refresh();
    final b = state.books[aid];
    if (b == null) return;
    final next = b.copyWith(title: title, img: img.isEmpty ? null : img, done: status.contains('完'));
    if (next.title != b.title || next.img != b.img || next.done != b.done) await _save({...state.books, aid: next});
  }

  Future<void> addCategory(String name) {
    _refresh();
    final now = DateTime.now().millisecondsSinceEpoch;
    return _save(state.books, [...state.cats, LibCategory('c${DateTime.now().microsecondsSinceEpoch}', name, now)]);
  }

  Future<void> renameCategory(String id, String name) {
    _refresh();
    final now = DateTime.now().millisecondsSinceEpoch;
    return _save(state.books, [for (final c in state.cats) c.id == id ? LibCategory(id, name, now) : c]);
  }

  Future<void> reorderCategories(List<LibCategory> cats) {
    _refresh();
    final ids = cats.map((c) => c.id).toSet();
    final current = {for (final c in state.cats) c.id: c};
    return _save(state.books, [for (final c in cats) if (current[c.id] != null) current[c.id]!, ...state.cats.where((c) => !ids.contains(c.id))]);
  }

  /// 删除分类：里面的书不删，只是不再属于它（没有别的分类就回到"默认"）。
  Future<void> deleteCategory(String id) async {
    _refresh();
    final now = DateTime.now().millisecondsSinceEpoch;
    await Future.wait([
      _save(
        {for (final b in state.books.values) b.aid: b.cats.contains(id) ? b.copyWith(cats: b.cats.where((c) => c != id).toList(), ts: now) : b},
        state.cats.where((c) => c.id != id).toList(),
      ),
      Sync.tombstone(['cat:$id']),
    ]);
  }

  bool _prefetching = false;

  bool get _online {
    final s = ref.read(sessionProvider);
    return s is SessionLoggedIn && !s.offline;
  }

  bool _sameAccount(String uid) {
    if (!ref.mounted) return false;
    final s = ref.read(sessionProvider);
    return s is SessionLoggedIn && !s.offline && s.user.uid == uid;
  }

  /// 只推本地排队的操作，不拉网站书架（加入 / 移出后马上调）。
  Future<void> _push() async {
    if (!ref.mounted || !_online || _syncing) return;
    final uid = (ref.read(sessionProvider) as SessionLoggedIn).user.uid;
    // 新账号先拉书架建立自己的绑定，不能把旧账号的队列和 bid 发给它。
    if (_box.get('lib:imported') != uid) return;
    _syncing = true;
    try {
      await _flush(ref.read(apiProvider), null, uid);
    } finally {
      _syncing = false;
    }
  }

  /// 推送排队的操作。[remote] 不为空时据此跳过网站上已经是那样的、补上缺的 bid，并把结果写回 [remote]。
  /// 加入被网站明确拒绝（例如书架满了）：书只留在本地；删除失败、登录失效或网络问题：保留操作，下次重试。
  Future<String?> _flush(Api api, Map<String, RemoteBook>? remote, String uid) async {
    final done = <String, Object?>{}; // 处理完的 aid → 当时的操作
    String? error;
    try {
      for (final MapEntry(key: aid, value: op) in _ops().entries) {
        if (!_sameAccount(uid)) return null;
        _flushingAid = aid;
        try {
          if (op['op'] == 'add') {
            if (remote == null || !remote.containsKey(aid)) await api.addToBookshelf(aid);
          } else {
            final bid = remote?[aid]?.bid ?? op['bid'] as String?;
            if (bid == null) {
              if (remote == null) continue; // 不知道 bid：等下次拉到网站书架再说
            } else if (remote == null || remote.containsKey(aid)) {
              await api.removeFromBookshelf(bid);
            }
            remote?.remove(aid);
          }
          if (!_sameAccount(uid)) return null;
          done[aid] = op['op'];
        } on Wenku8ActionRejectedException catch (e) {
          if (op['op'] == 'add') {
            done[aid] = op['op'];
          } else {
            error = e.toString();
            break;
          }
        } catch (e) {
          error = e.toString();
          break;
        }
      }
    } finally {
      _flushingAid = null;
    }
    // 推送期间用户可能又加 / 移了书：重新读一遍，只去掉处理过且没变的
    if (!_sameAccount(uid)) return null;
    final ops = _ops()..removeWhere((aid, op) => done.containsKey(aid) && done[aid] == op['op']);
    await _box.put('lib:ops', ops);
    return error;
  }

  /// 和网站书架同步：拉网站全部 6 个书架 → 推本地排队的操作 → 对一遍。没登录、离线时什么都不做。
  /// 距上次不到 30 分钟时跳过（[force] 除外）。返回出错信息，成功或跳过返回 null；[force]（用户下拉）时跳过也说明原因。
  Future<String?> sync({bool force = false, bool details = true}) async {
    final s = ref.read(sessionProvider);
    if (s is! SessionLoggedIn) return null;
    if (s.offline) return force ? '现在是离线模式（没连上网站），点顶部的提示重新连接后再下拉' : null;
    if (_syncing) return force ? '正在同步，稍等一下' : null;
    final now = DateTime.now().millisecondsSinceEpoch;
    final owner = _box.get('lib:imported');
    final first = owner != s.user.uid;
    final since = first ? 0 : ((_box.get('lib:sync') as int?) ?? 0);
    if (!first && !force && now - since < 30 * 60 * 1000) return null;
    _syncing = true;
    try {
      // 旧账号的操作不能发送给新账号；换号后在新账号下排的、游客排的照常推送。
      await _claimOps(s.user.uid);
      if (!_sameAccount(s.user.uid)) return null;
      final api = ref.read(apiProvider);
      final remote = <String, RemoteBook>{};
      for (var shelf = 0; shelf < 6; shelf++) {
        if (shelf > 0) await Future<void>.delayed(const Duration(seconds: 1)); // 连续读太快，网站会回 429
        if (!_sameAccount(s.user.uid)) return null;
        final shelfBooks = (await api.bookshelf(shelf, fresh: true)).list;
        if (!_sameAccount(s.user.uid)) return null;
        for (final b in shelfBooks) {
          remote.putIfAbsent(b.aid, () => (bid: b.bid, title: b.title, img: b.img, shelf: shelf));
        }
      }
      final flushError = await _flush(api, remote, s.user.uid);
      // 网络期间账号可能已改变，或 WebDAV 已重建书架：旧结果不再对账。
      if (!_sameAccount(s.user.uid)) return null;
      _refresh();
      var cats = state.cats;
      if (first) {
        // 第一次导入：网站书架 2~6 里有书的，建同名分类，书放进去，以后网站上只用默认书架
        final used = remote.values.map((r) => r.shelf).where((n) => n > 0).toSet();
        cats = [...cats, for (final n in used.toList()..sort()) if (!cats.any((c) => c.id == 'shelf$n')) LibCategory('shelf$n', shelfNames[n])];
      }
      final ops = {for (final e in _ops().entries) e.key: e.value['op'] as String};
      final next = reconcile(state.books, remote, ops, now: now, firstImport: first);
      // 网站上被移除的：记下删除，不然别的设备下次同步又把它带回来
      final removed = [for (final aid in state.books.keys) if (!next.containsKey(aid)) 'lib:$aid'];
      final readAfter = removedButRead(state.books, next, since: since, lastRead: ReadingProgress.lastRead);
      await Future.wait([
        _save(next, cats),
        Sync.tombstone(removed),
        _box.putAll({'lib:imported': s.user.uid, 'lib:sync': now}),
      ]);
      LibraryStore.noteRemovedElsewhere(readAfter);
      if (details && _sameAccount(s.user.uid)) unawaited(prefetchDetails());
      return flushError;
    } catch (e) {
      return e.toString();
    } finally {
      _syncing = false;
    }
  }

  /// 书架里还没存过详情的书，后台一本本取下来存好（离线也能看简介）；目录由检查更新顺带存。
  /// 网络出问题就停，下次接着取（已有的会跳过）。
  Future<void> prefetchDetails() async {
    if (!_online || _prefetching) return;
    _prefetching = true;
    try {
      final api = ref.read(apiProvider);
      for (final b in state.books.values.toList()) {
        if (api.hasDetail(b.aid)) continue;
        final d = await runInBackground(() => api.detail(b.aid));
        await noteDetail(b.aid, title: d.title, img: d.imgUrl, status: d.status);
      }
    } catch (_) {
    } finally {
      _prefetching = false;
    }
  }
}

final libraryProvider = NotifierProvider<LibraryController, LibraryState>(LibraryController.new);
