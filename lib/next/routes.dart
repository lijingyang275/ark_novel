/// 应用路由路径常量与拼装方法（不依赖页面实现，避免与 router.dart 循环导入）。
class Routes {
  const Routes._();

  static const splash = '/splash';
  static const login = '/login';
  static const verify = '/verify';
  static const discover = '/discover';
  static const bookshelf = '/bookshelf';
  static const updates = '/updates';
  static const stats = '/stats';
  static String yearlyReport([int? year]) => year == null ? '/stats/yearly' : '/stats/yearly?y=$year';
  static const bookmarks = '/bookmarks';
  static String report(String aid, {int? vol}) => '/report/$aid${vol == null ? '' : '?v=$vol'}';
  static const wall = '/wall';
  static const rules = '/rules';
  static const categories = '/categories';
  static const sync = '/sync';
  static const profile = '/profile';
  static const search = '/search';
  static const settings = '/settings';
  static String settingsSection(String name, {String? highlight}) =>
      highlight == null || highlight.isEmpty ? '/settings/$name' : '/settings/$name?q=${Uri.encodeQueryComponent(highlight)}';
  static const history = '/history';
  static const cache = '/cache';
  static const storage = '/storage';

  static String searchAuthor(String author) => '/search?author=${Uri.encodeQueryComponent(author)}';
  static String cacheBook(String aid) => '/cache/$aid';
  static String novel(String aid) => '/novel/$aid';
  static String volumes(String aid) => '/volumes/$aid';
  static String comments(String aid) => '/novel/$aid/comments';
  static String characters(String aid) => '/novel/$aid/characters';
  static String replies(String aid, String rid) => '/novel/$aid/comments/$rid';
  static String reader(String aid, String cid, {int? offset}) => offset == null ? '/reader/$aid/$cid' : '/reader/$aid/$cid?offset=$offset';
}
