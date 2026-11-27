import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show compute, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:html/parser.dart' show parse;

import '../data/wenku8/wenku8_client.dart';
import '../data/wenku8/wenku8_exceptions.dart';
import '../data/wenku8/wenku8_parser.dart';
import '../data/wenku8/wenku8_urls.dart';
import '../data/wenku8/wenku8_charset.dart';
import '../models/bookshelf.dart';
import '../models/common/charset_type.dart';
import '../models/cat_volume.dart';
import '../models/comment_item.dart';
import '../models/content.dart';
import '../models/novel_cover.dart';
import '../models/recommend_block.dart';
import '../models/reply_item.dart';
import 'cache.dart';
import 'session.dart';
import 'unlock.dart';

/// 最近一次解析失败的搜索页原文（只读兼容入口，实际归属 [Api] 维护），供搜索页"复制页面源码"排查网站结构变化。
String? get lastFailedHtml => Api.lastFailedHtml;

/// 列表的一页：[maxPage] 为 0 表示不知道总页数。
class PageResult {
  const PageResult(this.items, this.maxPage);

  final List<NovelCover> items;
  final int maxPage;
}

class NovelPage {
  const NovelPage(this.detail, this.catalogue);

  final Wenku8NovelDetail detail;
  final List<CatVolume> catalogue;
}

/// 所有网络请求的入口：每个方法 = 请求页面 + 交给解析层。页面结构不对（多半是没登录）时抛出
/// [Wenku8UnexpectedPageException]，界面据此提示去登录。
class Api {
  Api(this._client, this._urls, this._base, this._scope, {this.unlock, this.onCloudflare});

  static String? _lastFailedHtml;
  static const _asyncParseThreshold = 16 * 1024;
  static const _listCacheTtl = Duration(minutes: 5);
  static const _listCacheCap = 20;
  static final _wsRe = RegExp(r'\s+');

  /// 最近一次解析失败的搜索页原文（兼容旧顶层访问）。
  static String? get lastFailedHtml => _lastFailedHtml;

  /// 响应内存告警时释放静态缓存的失败搜索页原文。
  static void evictMemory() => _lastFailedHtml = null;

  final Wenku8Client _client;
  final Wenku8Urls _urls;
  final String _base;

  /// 受限章节的正文由运行期扩展工具尝试获取
  final UnlockService? unlock;

  /// 遇到 Cloudflare 拦截时回调（即使回落到旧缓存也会通知上层点亮验证提示）。
  final void Function()? onCloudflare;

  /// 当前用户 ID（游客为 guest）：账号私有页面（书架）的离线备份按它分开存。
  final String _scope;

  String? _lastFailedSearchHtml;
  final _listCache = <String, (DateTime at, PageResult result)>{};

  /// 当前 [Api] 实例最近一次解析失败的搜索页原文。
  String? get lastFailedSearchHtml => _lastFailedSearchHtml;

  void _setFailedSearchHtml(String? html) {
    _lastFailedSearchHtml = html;
    _lastFailedHtml = html;
  }

  /// 清空列表页短期内存缓存。
  void clearListCache() => _listCache.clear();

  /// 响应内存压力告警：清空列表缓存与最近失败搜索页源码。
  void onMemoryPressure() {
    _listCache.clear();
    _setFailedSearchHtml(null);
  }

  static Future<Wenku8NovelDetail> _parseNovelDetail(String html) =>
      !kIsWeb && html.length > _asyncParseThreshold ? compute(Wenku8Parser.novelDetail, html) : Future.value(Wenku8Parser.novelDetail(html));

  static Future<List<CatVolume>> _parseCatalogue(String html) =>
      !kIsWeb && html.length > _asyncParseThreshold ? compute(Wenku8Parser.catalogue, html) : Future.value(Wenku8Parser.catalogue(html));

  static Future<Content> _parseChapterContent(String html) =>
      !kIsWeb && html.length > _asyncParseThreshold ? compute(Wenku8Parser.chapterContent, html) : Future.value(Wenku8Parser.chapterContent(html));

  /// 取页面并解析，带离线备份：
  /// - 联网且解析成功：返回结果并更新备份（解析失败的页面——登录页、错误页、结构变了——绝不写进备份）
  /// - 页面不对（[Wenku8UnexpectedPageException]）或请求被主动取消：直接抛出，不拿旧备份冒充
  /// - 网络问题（超时、断网、5xx、Cloudflare）：遇 Cloudflare 时同步触发 [onCloudflare]；有备份就用备份；[fresh] 时不用备份，直接抛出
  Future<T> _cached<T>(
    String url,
    FutureOr<T> Function(String html) parse, {
    bool private = false,
    String? referer,
    bool fresh = false,
    CancelToken? cancelToken,
  }) async {
    final key = private ? '$_scope|$url' : url;
    final String html;
    try {
      html = await _client.getPage(url, charsetParam: false, referer: referer, cancelToken: cancelToken);
    } on Wenku8UnexpectedPageException {
      rethrow;
    } catch (e) {
      if (e is DioException && e.type == DioExceptionType.cancel) rethrow;
      if (isCloudflare(e)) onCloudflare?.call();
      final saved = fresh ? null : await PageStore.get(key);
      if (saved == null) rethrow;
      return await parse(saved);
    }
    final result = await parse(html);
    await PageStore.put(key, html);
    return result;
  }

  /// 提交表单；返回"出现错误！"页（太频繁、没权限等）当失败处理，让界面保留用户输入。
  Future<void> _submit(String url, Object data) async {
    _checkAction(await _client.postForm(url, data));
  }

  void _checkAction(String html) {
    final doc = parse(html);
    if (Wenku8Parser.needsLoginDoc(doc)) {
      throw const Wenku8LoginRequiredException('登录已失效，请重新登录后再试');
    }
    if (Wenku8Parser.isErrorPageDoc(doc)) {
      final why = doc.getElementsByClassName('blockcontent').firstOrNull?.text.trim();
      throw Wenku8ActionRejectedException(why == null || why.isEmpty ? '提交失败，请稍后再试' : why);
    }
  }

  static String _enc(String value) => Wenku8Charset.percentEncode(value, CharsetType.gbk);

  PageResult _list(String html) {
    final doc = parse(html);
    if (Wenku8Parser.needsLoginDoc(doc)) {
      throw const Wenku8LoginRequiredException('排行榜、题材与完结列表需要登录轻小说文库账号后查看');
    }
    if (Wenku8Parser.isErrorPageDoc(doc)) {
      final why = doc.getElementsByClassName('blockcontent').firstOrNull?.text.trim();
      throw Wenku8UnexpectedPageException(why == null || why.isEmpty ? '暂时无法获取列表' : why);
    }
    return PageResult(Wenku8Parser.novelListDoc(doc, baseUrl: _base), Wenku8Parser.maxPageDoc(doc));
  }

  Future<PageResult> _cachedList(String url, {bool fresh = false, CancelToken? cancelToken}) async {
    if (!fresh) {
      final hit = _listCache.remove(url);
      if (hit != null && DateTime.now().difference(hit.$1) < _listCacheTtl) {
        _listCache[url] = hit;
        return hit.$2;
      }
    }
    final result = _list(await _client.getPage(url, charsetParam: false, cancelToken: cancelToken));
    _listCache.remove(url);
    _listCache[url] = (DateTime.now(), result);
    while (_listCache.length > _listCacheCap) {
      _listCache.remove(_listCache.keys.first);
    }
    return result;
  }

  Future<PageResult> ranking(String sort, int page, {CancelToken? cancelToken}) => fetchRanking(sort, page, cancelToken: cancelToken);

  /// 拉取排行榜列表，带 5 分钟内存 LRU 缓存（容量 20）；[fresh] 为 true 时强制刷新。
  Future<PageResult> fetchRanking(String sort, int page, {bool fresh = false, CancelToken? cancelToken}) =>
      _cachedList(_urls.ranking(sort, page), fresh: fresh, cancelToken: cancelToken);

  Future<PageResult> category(String tag, String sort, int page, {CancelToken? cancelToken}) => fetchCategory(tag, sort, page, cancelToken: cancelToken);

  /// 拉取分类列表，带 5 分钟内存 LRU 缓存（容量 20）；[fresh] 为 true 时强制刷新。
  Future<PageResult> fetchCategory(String tag, String sort, int page, {bool fresh = false, CancelToken? cancelToken}) =>
      _cachedList(_urls.category(tag, sort, page), fresh: fresh, cancelToken: cancelToken);

  Future<PageResult> completed(int page, {CancelToken? cancelToken}) => fetchCompleted(page, cancelToken: cancelToken);

  /// 拉取完结列表，带 5 分钟内存 LRU 缓存（容量 20）；[fresh] 为 true 时强制刷新。
  Future<PageResult> fetchCompleted(int page, {bool fresh = false, CancelToken? cancelToken}) =>
      _cachedList(_urls.completedNovels(page), fresh: fresh, cancelToken: cancelToken);

  DateTime _lastSearch = DateTime(0);
  Future<void> _searchLock = Future<void>.value();

  /// 当前是否处于文库 5 秒搜索冷却窗口内。
  bool get isSearchCoolingDown => DateTime.now().difference(_lastSearch) < const Duration(seconds: 5);

  static DioException _cancelError(CancelToken token, String path) =>
      token.cancelError ?? DioException.requestCancelled(requestOptions: RequestOptions(path: path), reason: 'cancelled');

  /// 网站限制搜索间隔 5 秒：连续搜索串行排队等待；等待或排队期间响应 [cancelToken] 立即退出且不推进冷却基准。
  /// Cloudflare 拦截、429 限流、取消、"没搜到结果"或页面结构异常（[lastFailedSearchHtml] 有值）不做二次等待重试。
  Future<PageResult> search(String keyword, {required bool byAuthor, required int page, CancelToken? cancelToken}) async {
    if (cancelToken?.isCancelled == true) throw _cancelError(cancelToken!, 'search');
    Future<PageResult> run() async {
      for (var attempt = 0;; attempt++) {
        if (cancelToken?.isCancelled == true) throw _cancelError(cancelToken!, 'search');
        final wait = const Duration(seconds: 5, milliseconds: 200) - DateTime.now().difference(_lastSearch);
        if (wait > Duration.zero) {
          if (cancelToken == null) {
            await Future<void>.delayed(wait);
          } else {
            DioException? cancelErr;
            await Future.any<void>([
              Future<void>.delayed(wait),
              cancelToken.whenCancel.then((e) {
                cancelErr = e;
              }),
            ]);
            if (cancelErr != null || cancelToken.isCancelled) {
              throw cancelErr ?? _cancelError(cancelToken, 'search');
            }
          }
        }
        _lastSearch = DateTime.now();
        _setFailedSearchHtml(null);
        try {
          return await _search(keyword, byAuthor: byAuthor, page: page, cancelToken: cancelToken);
        } on Wenku8LoginRequiredException {
          rethrow;
        } catch (e) {
          if (isCloudflare(e)) onCloudflare?.call();
          if (attempt > 0 ||
              _lastFailedSearchHtml != null ||
              isCloudflare(e) ||
              (e is Wenku8HttpException && e.status == 429) ||
              (e is DioException && e.type == DioExceptionType.cancel)) {
            rethrow;
          }
        }
      }
    }

    final prev = _searchLock;
    final Future<PageResult> future;
    if (cancelToken == null) {
      future = prev.then((_) => run());
    } else {
      future = () async {
        DioException? cancelErr;
        await Future.any<void>([
          prev,
          cancelToken.whenCancel.then((e) {
            cancelErr = e;
          }),
        ]);
        if (cancelErr != null || cancelToken.isCancelled) {
          throw cancelErr ?? _cancelError(cancelToken, 'search');
        }
        return run();
      }();
    }
    _searchLock = future.then((_) {}, onError: (_) {});
    return future;
  }

  Future<PageResult> _search(String keyword, {required bool byAuthor, required int page, CancelToken? cancelToken}) async {
    final html = await _client.getPage(byAuthor ? _urls.searchByAuthor(keyword, page) : _urls.searchByTitle(keyword, page), charsetParam: false, cancelToken: cancelToken);
    final doc = parse(html);
    _setFailedSearchHtml(null);
    if (Wenku8Parser.needsLoginDoc(doc)) {
      throw const Wenku8LoginRequiredException('搜索功能需要登录轻小说文库账号');
    }
    if (Wenku8Parser.isErrorPageDoc(doc)) {
      final why = doc.getElementsByClassName('blockcontent').firstOrNull?.text.trim();
      throw Wenku8UnexpectedPageException(why == null || why.isEmpty ? '搜索太频繁，请 5 秒后再试' : why);
    }
    final only = Wenku8Parser.singleSearchResultDoc(doc);
    if (only != null) return PageResult([only], 1);
    final result = PageResult(Wenku8Parser.novelListDoc(doc, baseUrl: _base), Wenku8Parser.maxPageDoc(doc));
    if (result.items.isEmpty && page == 1) {
      // 正常的搜索结果页有 #content，只是没有匹配的书：返回空结果让界面显示友好的空状态
      if (doc.getElementById('content') != null) return const PageResult([], 0);
      final title = doc.querySelector('title')?.text.trim() ?? '';
      final text = doc.body?.text.replaceAll(_wsRe, ' ').trim() ?? '';
      _setFailedSearchHtml(html);
      throw Wenku8UnexpectedPageException('搜索页面返回异常：$title ${text.length > 100 ? text.substring(0, 100) : text}');
    }
    return result;
  }

  Future<List<RecommendBlock>> recommend({CancelToken? cancelToken}) => _cached(_urls.home(), Wenku8Parser.recommend, cancelToken: cancelToken);

  /// 存过的详情和目录（不联网），没存过或解析失败为 null。详情页先显示它，再联网刷新。
  Future<NovelPage?> saved(String aid) async {
    final detail = await PageStore.get(_urls.novelDetail(aid));
    final cat = await PageStore.get(_urls.catalogue(aid));
    if (detail == null || cat == null) return null;
    try {
      return NovelPage(await _parseNovelDetail(detail), await _parseCatalogue(cat));
    } catch (_) {
      return null;
    }
  }

  bool hasDetail(String aid) => PageStore.has(_urls.novelDetail(aid));

  Future<Wenku8NovelDetail> detail(String aid, {CancelToken? cancelToken}) => _cached(_urls.novelDetail(aid), _parseNovelDetail, cancelToken: cancelToken);

  Future<NovelPage> novel(String aid, {CancelToken? cancelToken}) async => NovelPage(await detail(aid, cancelToken: cancelToken), await catalogue(aid, cancelToken: cancelToken));

  /// 只取目录（检查更新用，比 [novel] 少一次请求）。
  Future<List<CatVolume>> catalogue(String aid, {bool fresh = false, CancelToken? cancelToken}) =>
      _cached(_urls.catalogue(aid), _parseCatalogue, referer: '$_base/book/$aid.htm', fresh: fresh, cancelToken: cancelToken);

  Future<Content> chapter(String aid, String cid) => fetchChapter(aid, cid);

  /// 拉取单章正文并支持透传 [cancelToken]（保持 [chapter] 签名不变以兼容既有测试桩）。
  Future<Content> fetchChapter(String aid, String cid, {CancelToken? cancelToken}) async {
    final html = await _client.getPage(_urls.chapterContent(aid, cid), charsetParam: false, referer: _urls.catalogue(aid), cancelToken: cancelToken);
    final content = await _parseChapterContent(html);
    if (!isLockedContent(content) || !(unlock?.enabled ?? false)) return content;
    return unlock!.chapter(aid, cid, () => catalogue(aid, cancelToken: cancelToken), cancelToken: cancelToken);
  }

  Future<Bookshelf> bookshelf(int classId, {bool fresh = false}) =>
      _cached(_urls.bookshelf(classId), (html) => Wenku8Parser.bookshelf(html, classId), private: true, fresh: fresh);

  /// 加入默认书架。wenku8 返回"出现错误！"页时说明失败（例如书架满了）。
  Future<void> addToBookshelf(String aid) async {
    _checkAction(await _client.getPage(_urls.addToBookshelf(aid), charsetParam: false, retryTransient: false));
  }

  Future<void> removeFromBookshelf(String bid) async => _checkAction(await _client.getPage(_urls.removeFromBookshelf(bid), charsetParam: false, retryTransient: false));

  Future<String> vote(String aid) async {
    final html = await _client.getPage(_urls.vote(aid), charsetParam: false, retryTransient: false);
    final doc = parse(html);
    if (Wenku8Parser.needsLoginDoc(doc)) throw const Wenku8LoginRequiredException('登录后才能推荐投票');
    return Wenku8Parser.voteResultDoc(doc);
  }

  Future<List<CommentItem>> comments(String aid, int page, {CancelToken? cancelToken}) async =>
      Wenku8Parser.comments(await _client.getPage(_urls.comments(aid, page), charsetParam: false, cancelToken: cancelToken));

  Future<void> sendComment(String aid, String title, String content) =>
      _submit(_urls.sendComment(aid), 'ptitle=${_enc(title)}&pcontent=${_enc(content)}&Submit=${_urls.submitButtonValue()}');

  Future<void> sendReply(String aid, String rid, String content) => _submit(_urls.sendReply(aid, rid), 'pcontent=${_enc(content)}&Submit=${_urls.submitButtonValue()}');

  Future<List<ReplyItem>> replies(String rid, int page, {CancelToken? cancelToken}) async =>
      Wenku8Parser.replies(await _client.getPage(_urls.replies(rid, page), charsetParam: false, cancelToken: cancelToken));
}

final apiProvider = Provider<Api>((ref) {
  final node = ref.watch(nodeProvider);
  final scope = ref.watch(sessionProvider.select((s) => s is SessionLoggedIn ? s.user.uid : 'guest'));
  return Api(
    ref.watch(wenku8ClientProvider),
    ref.watch(wenku8UrlsProvider),
    siteBase(node),
    scope,
    unlock: ref.watch(unlockServiceProvider),
    onCloudflare: () => ref.read(sessionProvider.notifier).markNeedsVerify(),
  );
});
