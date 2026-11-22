import '../../models/common/charset_type.dart';
import 'wenku8_charset.dart';

/// wenku8 各页面的地址。纯函数，不发请求，方便单独测试。
///
/// - [base] 节点地址，例如 `https://www.wenku8.net`
/// - [charset] 中文查询参数（分类、搜索词）使用的编码
class Wenku8Urls {
  const Wenku8Urls(this.base, this.charset);

  final String base;
  final CharsetType charset;

  String _encode(String value) => Wenku8Charset.percentEncode(value, charset).trim();

  String ranking(String ranking, int page) => "$base/modules/article/toplist.php?sort=$ranking&page=$page";

  String category(String category, String sort, int page) => "$base/modules/article/tags.php?t=${_encode(category)}&v=$sort&page=$page";

  String novelDetail(String aid) => "$base/modules/article/articleinfo.php?id=$aid";

  String catalogue(String aid) => "$base/modules/article/reader.php?aid=$aid";

  String chapterContent(String aid, String cid) => "$base/modules/article/reader.php?aid=$aid&cid=$cid";

  String addToBookshelf(String aid) => "$base/modules/article/addbookcase.php?bid=$aid";

  String removeFromBookshelf(String bid) => "$base/modules/article/bookcase.php?delid=$bid";

  String bookshelf(int classId) => "$base/modules/article/bookcase.php?classid=$classId";

  String comments(String aid, int page) => "$base/modules/article/reviews.php?aid=$aid&page=$page";

  String replies(String rid, int page) => "$base/modules/article/reviewshow.php?rid=$rid&page=$page";

  String sendComment(String aid) => "$base/modules/article/reviews.php?aid=$aid";

  String sendReply(String aid, String rid) => "$base/modules/article/reviewshow.php?rid=$rid&aid=$aid";

  String home() => "$base/index.php";

  String vote(String aid) => "$base/modules/article/uservote.php?id=$aid";

  String searchByTitle(String title, int page) => "$base/modules/article/search.php?searchtype=articlename&searchkey=${_encode(title)}&page=$page";

  String searchByAuthor(String author, int page) => "$base/modules/article/search.php?searchtype=author&searchkey=${_encode(author)}&page=$page";

  String userInfo() => "$base/userdetail.php";

  String completedNovels(int page) => "$base/modules/article/articlelist.php?fullflag=1&page=$page";

  String login() => "$base/login.php";

  /// 账号密码登录提交地址（杰奇 CMS 的登录表单）
  String loginSubmit() => "$base/login.php?do=submit";

  /// 账号密码登录的表单内容。[keepSeconds] 为登录有效期（秒），wenku8 不接受"临时登录"。
  String loginForm(String username, String password, {int keepSeconds = 315360000}) =>
      "username=${Wenku8Charset.percentEncode(username, charset)}"
      "&password=${Wenku8Charset.percentEncode(password, charset)}"
      "&usecookie=$keepSeconds&action=login";

  /// 发表书评、回复时表单里 `Submit` 字段的值（按钮文字，带 `+` 表示的空格）
  String submitButtonValue() =>
      "+${_encode(switch (charset) {
        CharsetType.gbk => "发表书评",
        CharsetType.big5Hkscs => "發表書評",
      })}+";
}
