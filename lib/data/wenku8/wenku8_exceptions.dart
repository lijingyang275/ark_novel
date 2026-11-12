/// 数据层抛出的异常。界面层负责把它们翻译成给用户看的文字。
sealed class Wenku8Exception implements Exception {
  const Wenku8Exception(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 拿到的页面不是预期的结构：通常是未登录被跳到登录页、会话过期、
/// Cloudflare 验证页或节点不可用。
class Wenku8UnexpectedPageException extends Wenku8Exception {
  const Wenku8UnexpectedPageException(super.message);
}

/// 网站明确返回业务错误页（例如书架已满）；和登录失效、结构变化区分，调用方才能决定是否放弃操作。
class Wenku8ActionRejectedException extends Wenku8UnexpectedPageException {
  const Wenku8ActionRejectedException(super.message);
}

/// 服务端返回了 4xx/5xx（例如 Cloudflare 的 52x 源站超时、503 维护页）。内容不是我们要的页面，
/// 调用方应当按"网络问题"处理：用离线备份，不要写缓存，也不要当成登录失效。
class Wenku8HttpException extends Wenku8Exception {
  const Wenku8HttpException(this.status) : super(status == 429 ? '请求太频繁了（HTTP 429），请等一会儿再试' : '网站暂时不可用（HTTP $status）');

  final int status;
}
