import 'package:flutter_test/flutter_test.dart';
import 'package:ark_novel/models/common/wenku8_node.dart';
import 'package:ark_novel/next/pages/login_webview_page.dart';
import 'package:ark_novel/next/web_fetch.dart';

void main() {
  test('自动填表只认同一站点和它的子域名，不认只是后缀相同的域名', () {
    expect(isSameSite('wenku8.net', 'wenku8.net'), true);
    expect(isSameSite('www.wenku8.net', 'wenku8.net'), true);
    expect(isSameSite('evilwenku8.net', 'wenku8.net'), false);
    expect(isSameSite('wenku8.net.evil.com', 'wenku8.net'), false);
    expect(isSameSite('xwenku8.net', 'wenku8.net'), false);
    expect(isTrustedLoginHost('www.wenku8.net', 'www.wenku8.cc'), true);
    expect(isTrustedLoginHost('evilwenku8.net', 'www.wenku8.cc'), false);
  });

  test('upgradeMainSiteHttp 仅升级文库主站明文 HTTP，保留图床与 HTTPS 链接', () {
    expect(
      upgradeMainSiteHttp(Uri.parse('http://www.wenku8.net/login.php?jumpurl=abc')),
      Uri.parse('https://www.wenku8.net/login.php?jumpurl=abc'),
    );
    expect(
      upgradeMainSiteHttp(Uri.parse('http://www.wenku8.cc/index.php')),
      Uri.parse('https://www.wenku8.cc/index.php'),
    );
    expect(upgradeMainSiteHttp(Uri.parse('https://www.wenku8.net/login.php')), isNull);
    expect(upgradeMainSiteHttp(Uri.parse('http://img.wenku8.com/image/1/1.jpg')), isNull);
    expect(upgradeMainSiteHttp(Uri.parse('http://evilwenku8.net/login.php')), isNull);
  });

  test('resolveVerifyTargetUri 主站镜像间跳转跟随实际过盾域名，外部域名跳转锚定原验证域名', () {
    final initial = Uri.parse('https://www.wenku8.cc/login.php');
    // wenku8.cc 301 到 wenku8.net（CF 实际在 wenku8.net 签发 cf_clearance）：跟随 wenku8.net 并升级 https
    expect(
      resolveVerifyTargetUri(initial, Uri.parse('http://www.wenku8.net/login.php')),
      Uri.parse('https://www.wenku8.net/login.php'),
    );
    // 跳到无关外部域名则锚定原验证域名
    expect(
      resolveVerifyTargetUri(initial, Uri.parse('https://evil.example.com/login')),
      initial,
    );
    // 同域内跳转则保留当前地址但升级 https
    expect(
      resolveVerifyTargetUri(initial, Uri.parse('http://www.wenku8.cc/index.php')),
      Uri.parse('https://www.wenku8.cc/index.php'),
    );
    expect(resolveVerifyTargetUri(initial, null), initial);
  });

  test('defaultVerifyUrl 主站默认走当前线路 index.php，图床走根路径，显式 http 主站自动升 https', () {
    expect(defaultVerifyUrl(url: null, host: null, node: Wenku8Node.wwwWenku8Cc), 'https://www.wenku8.cc/index.php');
    expect(defaultVerifyUrl(url: null, host: null, node: Wenku8Node.wwwWenku8Net), 'https://www.wenku8.net/index.php');
    expect(defaultVerifyUrl(url: null, host: 'www.wenku8.cc', node: Wenku8Node.wwwWenku8Net), 'https://www.wenku8.cc/index.php');
    expect(defaultVerifyUrl(url: null, host: 'pic.wenku8.com', node: Wenku8Node.wwwWenku8Cc), 'https://pic.wenku8.com/');
    expect(
      defaultVerifyUrl(url: 'http://www.wenku8.cc/book/123.htm', host: null, node: Wenku8Node.wwwWenku8Cc),
      'https://www.wenku8.cc/book/123.htm',
    );
  });

  test('isEmptyShellHtml 识别取消跳转后的空白 HTML 壳，不误伤正常页面', () {
    expect(isEmptyShellHtml(''), isTrue);
    expect(isEmptyShellHtml('<html><head></head><body></body></html>'), isTrue);
    expect(isEmptyShellHtml('<html><head><!-- comment --></head><body>   </body></html>'), isTrue);
    expect(isEmptyShellHtml('<html><head><title>轻小说文库</title></head><body>内容</body></html>'), isFalse);
    expect(isEmptyShellHtml('<html><body><form action="/login.php"></form></body></html>'), isFalse);
  });
}
