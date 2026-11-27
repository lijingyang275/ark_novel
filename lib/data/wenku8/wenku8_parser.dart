import 'package:html/dom.dart';
import 'package:html/parser.dart';

import '../../common/image_url_helper.dart';
import '../../models/bookshelf.dart';
import '../../models/cat_chapter.dart';
import '../../models/cat_volume.dart';
import '../../models/comment_item.dart';
import '../../models/content.dart';
import '../../models/novel_cover.dart';
import '../../models/recommend_block.dart';
import '../../models/reply_item.dart';
import '../../models/user_info.dart';
import 'wenku8_exceptions.dart';

/// 书籍详情页解析出的原始数据，未做本地化（文案拼接、相对时间）处理。
class Wenku8NovelDetail {
  const Wenku8NovelDetail({
    required this.title,
    required this.author,
    required this.status,
    required this.lastUpdate,
    required this.imgUrl,
    required this.introduce,
    required this.tags,
    required this.heat,
    required this.trending,
    required this.isAnimated,
  });

  final String title;
  final String author;
  final String status;

  /// 最后更新日期（如 `2024-01-01`）；为 null 表示书籍已下架
  final String? lastUpdate;
  final String imgUrl;
  final String introduce;
  final List<String> tags;

  /// 热度数值；下架时为 null
  final String? heat;

  /// 上升率数值；下架时为 null
  final String? trending;
  final bool isAnimated;

  bool get isDelisted => lastUpdate == null;
}

/// wenku8 页面解析。纯函数：输入 HTML 字符串，输出数据模型；
/// 不读取本地存储、不做多语言翻译，日期保持网页原样。
///
/// 解析规则沿用原 `Parser`，后续网站结构变化时只需要改这里并更新测试样本。
class Wenku8Parser {
  const Wenku8Parser._();

  static final _bookHtmRe = RegExp(r'/book/(\d+)\.htm');
  static final _articleInfoIdRe = RegExp(r'articleinfo\.php\?id=(\d+)');
  static final _heatRe = RegExp(r'[热熱]度[：:]\s*([^，,\s]+)');
  static final _trendingRe = RegExp(r'指[数數][^：:]*[：:]\s*([^，,\s]+)');
  static final _bookIdRe = RegExp(r'book/(\d+)');
  static final _ridRe = RegExp(r'rid=(\d+)');
  static final _uidRe = RegExp(r'uid=(\d+)');
  static final _digitsRe = RegExp(r'^\d+$');
  static final _trimEdgesRe = RegExp(r'^[\n\s]*|[\n\s]*$');
  static final _paraSplitRe = RegExp(r'\n\s*\n');

  /// 排行、分类、搜索等列表页。[baseUrl] 用于补全详情页和缺省封面地址。
  static List<NovelCover> novelList(String html, {required String baseUrl}) => novelListDoc(parse(html), baseUrl: baseUrl);

  static List<NovelCover> novelListDoc(Document doc, {required String baseUrl}) {
    final origin = baseUrl.startsWith('http://') || baseUrl.startsWith('https://') ? baseUrl : 'https://$baseUrl';
    final List<NovelCover> result = [];
    final Element? contentElement = doc.getElementById("content");
    if (contentElement == null) return result;

    const String targetStyle = "width:373px;height:136px;float:left;margin:5px 0px 5px 5px;";
    for (final Element novelItem in contentElement.querySelectorAll('[style="$targetStyle"]')) {
      final String rawImg = novelItem.querySelector("img")?.attributes['src'] ?? '';
      final String title = novelItem.querySelector("a")?.attributes['title'] ?? "";
      final String href = novelItem.querySelector("div")?.querySelector("a")?.attributes['href'] ?? '';
      if (href.isEmpty) continue;
      final String detailUrl = href.startsWith('http') ? href : "$origin$href";

      final String img = (rawImg == "/images/noimg.jpg" || rawImg.isEmpty)
          ? "$origin/modules/article/images/nocover.jpg"
          : ImageUrlHelper.normalize(rawImg);

      String aid = "";
      final bookIndex = detailUrl.indexOf("book/");
      final htmIndex = detailUrl.indexOf(".htm");
      if (bookIndex != -1 && htmIndex != -1 && htmIndex > bookIndex + 5) {
        aid = detailUrl.substring(bookIndex + 5, htmIndex);
      } else {
        final aidIndex = detailUrl.indexOf("aid=");
        final bidIndex = detailUrl.indexOf("&bid=");
        if (aidIndex != -1 && bidIndex != -1 && bidIndex > aidIndex + 4) {
          aid = detailUrl.substring(aidIndex + 4, bidIndex);
        }
      }

      if (title.isNotEmpty) result.add(NovelCover(title, img, aid));
    }
    return result.isNotEmpty ? result : _novelListFallback(contentElement);
  }

  /// 结构和预期不一致时的兜底：收集页面里所有指向书籍详情的链接（`/book/123.htm` 或 `articleinfo.php?id=123`），按书号去重。
  static List<NovelCover> _novelListFallback(Element content) {
    final seen = <String>{};
    final out = <NovelCover>[];
    for (final a in content.querySelectorAll('a')) {
      final href = a.attributes['href'] ?? '';
      final aid = _bookHtmRe.firstMatch(href)?.group(1) ?? _articleInfoIdRe.firstMatch(href)?.group(1);
      if (aid == null) continue;
      final title = (a.attributes['title'] ?? a.text).trim();
      if (title.isEmpty || !seen.add(aid)) continue;
      out.add(NovelCover(title, null, aid));
    }
    return out;
  }

  static Never _throwUnexpected(Document doc, String fallback) {
    if (needsLoginDoc(doc)) throw const Wenku8LoginRequiredException();
    if (isErrorPageDoc(doc)) {
      final why = doc.getElementsByClassName('blockcontent').firstOrNull?.text.trim();
      throw Wenku8UnexpectedPageException(why == null || why.isEmpty ? fallback : why);
    }
    throw Wenku8UnexpectedPageException(fallback);
  }

  static Wenku8NovelDetail novelDetail(String html) {
    final doc = parse(html);
    final Element? t1 = doc.getElementById('content');
    if (t1 == null) _throwUnexpected(doc, '未获取到书籍详情（可能书籍不存在或页面结构变化）');
    final tables = t1.getElementsByTagName('table');
    // 结构不对就不是详情页：报错，不能当成功，否则会用空数据覆盖缓存里的好页面
    if (tables.length < 3) _throwUnexpected(doc, '书籍详情页面结构不完整');
    final Element t2 = tables[0];
    final String title = t2.querySelector('span > b')?.text.trim() ?? '';
    final trs = t2.getElementsByTagName('tr');
    final tds = trs.length > 2 ? trs[2].getElementsByTagName('td') : <Element>[];
    if (tds.length < 3) _throwUnexpected(doc, '书籍作者与状态信息缺失');
    final authorText = tds[1].text.trim();
    final String author = authorText.length >= 5 ? authorText.substring(5) : authorText;
    final statusText = tds[2].text.trim();
    final String status = statusText.length >= 5 ? statusText.substring(5) : statusText;
    String? lastUpdate;
    if (tds.length > 3) {
      final t = tds[3].text.trim();
      lastUpdate = t.length >= 5 ? t.substring(5) : null;
    }

    final imgs = t1.getElementsByTagName('img');
    if (imgs.isEmpty) _throwUnexpected(doc, '书籍封面信息缺失');
    final String imgUrl = ImageUrlHelper.normalize(imgs[0].attributes['src'] ?? '');
    final table2Tds = tables[2].getElementsByTagName('td');
    final spans = table2Tds.length > 1 ? table2Tds[1].getElementsByTagName('span') : <Element>[];
    if (spans.length < 2) _throwUnexpected(doc, '书籍标签信息缺失');
    String introduce = spans.length > 5 ? spans[5].innerHtml.replaceAll("<br>", "\n") : "";
    final String tag = spans[0].text;
    final String tempHeat = spans[1].text;
    final firstTdSpans = table2Tds[0].getElementsByTagName('span');
    final bool isAnimated = firstTdSpans.isNotEmpty;

    String? heat;
    String? trending;
    if (lastUpdate == null) {
      introduce = tempHeat; // 下架书籍的简介在这个位置
    } else if (tempHeat.length >= 19) {
      // 「作品热度：A级，当前热度上升指数为：B级」：按冒号后面取，SSS级这种多于一个字母的也完整
      heat = _heatRe.firstMatch(tempHeat)?[1];
      trending = _trendingRe.firstMatch(tempHeat)?[1];
    }

    final tags = (tag.length >= 7 ? tag.substring(7) : tag).split(" ").where((t) => t.isNotEmpty).toList();

    return Wenku8NovelDetail(
      title: title,
      author: author,
      status: status,
      lastUpdate: lastUpdate,
      imgUrl: imgUrl,
      introduce: introduce,
      tags: tags,
      heat: heat,
      trending: trending,
      isAnimated: isAnimated,
    );
  }

  /// 列表页的总页数，找不到时返回 0。
  static int maxPage(String html) => maxPageDoc(parse(html));

  static int maxPageDoc(Document doc) {
    int pageCount = 0;
    for (final element in doc.getElementsByClassName("last")) {
      final int? parsed = int.tryParse(element.text.trim());
      if (parsed != null) pageCount = parsed;
    }
    return pageCount;
  }

  static const _coverStyle = "div[style='float: left;text-align:center;width: 95px; height:155px;overflow:hidden;']";

  static NovelCover? _recommendCover(Element e) {
    final anchors = e.getElementsByTagName("a");
    final imgs = e.getElementsByTagName("img");
    if (anchors.length < 2 || imgs.isEmpty) return null;
    final String url = anchors[0].attributes["href"] ?? "";
    // 链接格式不对（没有 .htm、带参数）时只是这本没有书号，不能让整个首页推荐失败
    final String aid = _bookIdRe.firstMatch(url)?[1] ?? "";
    return NovelCover(anchors[1].text, ImageUrlHelper.normalize(imgs[0].attributes["src"] ?? ""), aid);
  }

  /// 首页推荐区块。
  static List<RecommendBlock> recommend(String html) {
    final Document document = parse(html);
    if (needsLoginDoc(document)) {
      throw const Wenku8LoginRequiredException('推荐页面需要登录轻小说文库账号后查看');
    }
    final Element? centers = document.getElementById("centers");
    final List<RecommendBlock> blocks = [];

    final centerBlocks = centers?.getElementsByClassName("block") ?? const <Element>[];
    for (int i = 1; i <= 3 && i < centerBlocks.length; i++) {
      final block = centerBlocks[i];
      String title = block.getElementsByClassName("blocktitle").firstOrNull?.text ?? "";
      if (i == 1) title = title.split("(")[0];
      blocks.add(RecommendBlock(title, block.querySelectorAll(_coverStyle).map(_recommendCover).nonNulls.toList()));
    }

    final mains = document.querySelectorAll("div.main");
    for (int i = 2; i <= 3 && i < mains.length; i++) {
      final main = mains[i];
      String title = main.querySelector("div.blocktitle")?.text ?? "";
      if (i == 3) title = title.split("(")[0];
      blocks.add(RecommendBlock(title, main.querySelectorAll(_coverStyle).map(_recommendCover).nonNulls.toList()));
    }
    return blocks;
  }

  /// 章节目录。
  static List<CatVolume> catalogue(String html) {
    final doc = parse(html);
    final table = doc.querySelector('table.css');
    if (table == null) _throwUnexpected(doc, '未找到章节目录（可能作品尚未收录章节或页面异常）');

    final List<CatVolume> volumes = [];
    String? currentVolumeTitle;
    List<CatChapter> currentChapters = [];

    for (final row in table.querySelectorAll('tr')) {
      final volTd = row.querySelector('td.vcss');
      if (volTd != null) {
        if (currentVolumeTitle != null) {
          volumes.add(CatVolume(title: currentVolumeTitle, chapters: currentChapters));
          currentChapters = [];
        }
        currentVolumeTitle = volTd.text.trim();
        continue;
      }

      for (final td in row.querySelectorAll('td.ccss')) {
        final linkEl = td.querySelector('a');
        if (linkEl == null) continue;
        final title = linkEl.text.trim();
        final href = linkEl.attributes['href']?.trim() ?? '';
        if (title.isEmpty || href.isEmpty) continue;
        final parts = href.split('&cid=');
        currentChapters.add(CatChapter(title: title, cid: parts.length > 1 ? parts.last : ''));
      }
    }

    if (currentVolumeTitle != null) {
      volumes.add(CatVolume(title: currentVolumeTitle, chapters: currentChapters));
    }
    return volumes;
  }

  /// 书评列表。[CommentItem.time] 为网页原始时间字符串。
  static List<CommentItem> comments(String html) {
    final doc = parse(html);
    final contentEl = doc.getElementById('content');
    if (contentEl == null) _throwUnexpected(doc, '无法读取书评列表');
    final tables = contentEl.getElementsByTagName('table');
    if (tables.length < 3) _throwUnexpected(doc, '书评页面结构异常');

    final comments = <CommentItem>[];
    for (final row in tables[2].getElementsByTagName('tr')) {
      if (row.attributes.containsKey('align')) continue;
      final tds = row.getElementsByTagName('td');
      if (tds.length < 4) continue;
      final a0 = tds[0].querySelector('a');
      final href0 = a0?.attributes['href'] ?? '';
      final rid = _ridRe.firstMatch(href0)?.group(1) ?? href0;
      final viewAndReply = tds[1].text.trim();
      final idx = viewAndReply.indexOf('/');
      final a2 = tds[2].querySelector('a');
      final href2 = a2?.attributes['href'] ?? '';

      comments.add(
        CommentItem(
          rid: rid,
          content: a0?.text.trim() ?? '',
          replyCount: idx > 0 ? viewAndReply.substring(0, idx) : '',
          viewCount: (idx >= 0 && idx + 1 < viewAndReply.length) ? viewAndReply.substring(idx + 1) : '',
          userName: a2?.text.trim() ?? '',
          uid: href2.contains('uid=') ? href2.split('uid=').last : '',
          time: tds[3].text.trim(),
        ),
      );
    }
    return comments;
  }

  /// 书评的回复列表。[ReplyItem.time] 为网页原始时间字符串。
  static List<ReplyItem> replies(String html) {
    final Element? content = parse(html).getElementById("content");
    if (content == null) return [];
    final List<Element> tables = content.getElementsByTagName("table");
    final List<ReplyItem> result = [];
    // 前 3 个 table 是书评标题/操作区，最后 2 个是分页和回复框，中间每个 table 是一条回复
    for (int i = 3; i < tables.length - 2; i++) {
      final List<Element> tds = tables[i].querySelectorAll("td");
      if (tds.length < 2) continue;
      final Element? userLink = tds[0].querySelector("a");
      final String? href = userLink?.attributes["href"];
      final String uid = href == null ? "" : _uidRe.firstMatch(href)?[1] ?? "";

      final List<Element> divs = tds[1].querySelectorAll("div");
      String rawTime = "";
      if (divs.length > 1) {
        rawTime = divs[1].text;
        final int pipeIndex = rawTime.indexOf("|");
        if (pipeIndex > 0) rawTime = rawTime.substring(0, pipeIndex - 1);
      }
      result.add(ReplyItem(content: divs.length > 2 ? divs[2].text : "", userName: userLink?.text ?? "", uid: uid, time: rawTime.trim()));
    }
    return result;
  }

  /// 自己的书架（bookcase.php）。
  static Bookshelf bookshelf(String html, int classId) {
    final doc = parse(html);
    final content = doc.getElementById('content');
    if (content == null) _throwUnexpected(doc, '无法读取网站书架页面');

    final List<BookshelfNovelInfo> novels = [];
    for (final row in content.getElementsByTagName('tr')) {
      if (row.attributes.containsKey('align')) continue;
      final tds = row.getElementsByTagName('td');
      if (tds.length < 2 || tds[0].classes.contains('foot')) continue;

      final bid = tds[0].querySelector('input')?.attributes['value'] ?? '';
      final linkEl = tds[1].querySelector('a');
      final bookUrl = linkEl?.attributes['href'] ?? '';
      final title = linkEl?.text.trim() ?? '';

      final aidStart = bookUrl.indexOf('aid=') + 4;
      final aidEnd = bookUrl.indexOf('&', aidStart);
      final aid = aidStart >= 4 && aidEnd > aidStart ? bookUrl.substring(aidStart, aidEnd) : '';

      novels.add(BookshelfNovelInfo(bid: bid, aid: aid, url: bookUrl, title: title, img: coverUrl(aid)));
    }
    return Bookshelf(list: novels, classId: classId.toString());
  }

  /// 根据书号拼出官方封面图地址（书架页没有封面，只能按规则拼）。
  /// 目录按书号除以 1000 分（4 位书号就是第一位）；没有书号返回空串。
  static String coverUrl(String aid) {
    final n = int.tryParse(aid);
    return n == null ? '' : 'https://img.wenku8.com/image/${n ~/ 1000}/$aid/${aid}s.jpg';
  }

  /// 投票后的提示文字。
  static String voteResult(String html) => voteResultDoc(parse(html));

  /// 从已解析的投票结果 [Document] 提取提示文字，避免重复 DOM 解析。
  static String voteResultDoc(Document doc) {
    final blockContent = doc.getElementsByClassName("blockcontent");
    if (blockContent.isEmpty) return "";
    return blockContent[0].querySelector("div[style='padding:10px']")?.text ?? "";
  }

  /// 用户详情页。拿到的不是详情页（未登录、会话过期、Cloudflare 等）时抛出 [Wenku8UnexpectedPageException]。
  static UserInfo userInfo(String html) {
    final doc = parse(html);
    if (needsLoginDoc(doc)) throw const Wenku8LoginRequiredException();
    final Element? tbody = doc.getElementById('content')?.querySelector('tbody');
    if (tbody == null) throw const Wenku8UnexpectedPageException("user info: not a user detail page");
    final List<Element> rows = tbody.querySelectorAll('tr');

    String cell(int row, int col) {
      if (row >= rows.length) return "";
      final tds = rows[row].querySelectorAll('td');
      if (col >= tds.length) return "";
      return tds[col].text.trim();
    }

    final uid = cell(0, 1);
    if (uid.isEmpty || !_digitsRe.hasMatch(uid)) {
      throw const Wenku8UnexpectedPageException("user info: not a user detail page");
    }

    String avatar = "";
    if (rows.isNotEmpty) {
      final tds = rows[0].querySelectorAll('td');
      if (tds.length > 2) {
        avatar = (tds[2].querySelector('img')?.attributes['src'] ?? "").replaceAll("https", "http");
      }
    }
    // 用户未公开/未设置邮箱时没有 <a> 标签，退回到单元格文本
    final String email = rows.length > 7 ? (rows[7].querySelector('a')?.text.trim() ?? cell(7, 1)) : "";

    return UserInfo(
      avatar: avatar,
      uid: uid,
      username: cell(2, 1),
      userLevel: cell(4, 1),
      email: email,
      registerDate: cell(12, 1),
      contribution: cell(13, 1),
      experience: cell(14, 1),
      point: cell(15, 1),
      maxBookshelfNum: cell(18, 1),
      maxRecommendNum: cell(19, 1),
    );
  }

  /// 是否是要求登录的页面：跳到了登录页（有密码框），或者"出现错误！"提示页里说要先登录。
  /// 用来区分"登录过期"和维护页、验证页这类偶发的意外页面。
  static bool needsLogin(String html) => needsLoginDoc(parse(html));

  static bool needsLoginDoc(Document doc) {
    if (doc.querySelector('input[name=password]') != null) return true;
    final title = doc.getElementsByClassName('blocktitle').firstOrNull?.text;
    if (title != '出现错误！' && title != '出現錯誤！') return false;
    final message = doc.getElementsByClassName('blockcontent').firstOrNull?.text ?? '';
    return ['登录', '登錄', '登入'].any(message.contains);
  }

  /// 是否是网站因版权下架返回的单句提示正文（未导入扩展包时也能识别）。
  static bool isCopyrightLockedText(String text) {
    final t = text.trim();
    if (t.length > 120) return false;
    return (t.contains('因版权问题') || t.contains('因版權問題')) && (t.contains('不再提供') || t.contains('文库') || t.contains('文庫'));
  }

  /// 是否是 wenku8 的"出现错误！"提示页。
  static bool isErrorPage(String html) => isErrorPageDoc(parse(html));

  static bool isErrorPageDoc(Document doc) {
    final t = doc.getElementsByClassName('blocktitle').firstOrNull?.text;
    return t == '出现错误！' || t == '出現錯誤！';
  }

  /// 搜索结果只有一本时 wenku8 会直接显示详情页，这里识别并返回那本书；否则返回 null。
  static NovelCover? singleSearchResult(String html) => singleSearchResultDoc(parse(html));

  static NovelCover? singleSearchResultDoc(Document doc) {
    try {
      final Element? content = doc.getElementById('content');
      if (content == null) return null;
      final List<Element> divs = content.getElementsByTagName('div')[0].querySelectorAll('div[style="margin:0px auto;overflow:hidden;"]');
      if (divs.isEmpty) return null;
      final List<Element> spans = divs[0].getElementsByTagName('span');
      if (spans.length < 2) return null;
      final String? bookHref = spans[1].querySelector('a')?.attributes['href'];
      if (bookHref == null) return null;
      final List<Element> tables = content.getElementsByTagName('table');
      if (tables.isEmpty) return null;
      final String title = tables[0].querySelectorAll('span').first.querySelector('b')?.text.trim() ?? '';
      final String imgUrl = ImageUrlHelper.normalize(content.querySelectorAll('img').first.attributes['src']?.trim() ?? '');
      final int idx = bookHref.indexOf('bid=');
      if (idx == -1) return null;
      return NovelCover(title, imgUrl, bookHref.substring(idx + 4));
    } catch (_) {
      return null;
    }
  }

  /// 章节正文：文本（段落首行缩进）+ 插图地址列表。
  static Content chapterContent(String html) {
    final doc = parse(html);
    final Element? contentElement = doc.getElementById('content');
    if (contentElement == null) _throwUnexpected(doc, '未获取到章节正文（可能登录失效或页面被拦截）');

    final List<String> images = [];
    for (final img in contentElement.querySelectorAll('img')) {
      final String? src = img.attributes['src'];
      if (src != null && src.isNotEmpty) images.add(ImageUrlHelper.normalize(src));
    }

    contentElement.querySelectorAll('ul#contentdp').forEach((e) => e.remove());

    final String trimmed = contentElement.text.replaceAll(_trimEdgesRe, '');
    final paragraphs = trimmed.split(_paraSplitRe).map((paragraph) {
      if (paragraph.trim().isEmpty) return '';
      final lines = paragraph.split('\n');
      lines[0] = '   ${lines[0]}'; // 仅首行加 3 个空格缩进
      return lines.join('\n');
    });

    String text = paragraphs.join('\n\n').trim();
    for (final src in images) {
      text = text.replaceAll(src, '');
    }
    if (text.isEmpty && images.isEmpty) throw const Wenku8UnexpectedPageException('chapter: empty content');
    return Content(text: text, images: images);
  }
}
