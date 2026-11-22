import 'package:dio/dio.dart';

const cloudflareChallengeExceptionMessage = "Cloudflare Challenge Detected";
const cloudflare403ExceptionMessage = "You have been blocked by Cloudflare";

class CloudflareChallengeException extends DioException {
  CloudflareChallengeException({required super.requestOptions, super.message = cloudflareChallengeExceptionMessage});

  @override
  String toString() => '被网站验证拦截，请点「去验证」完成一次浏览器验证';
}

class Cloudflare403Exception extends DioException {
  Cloudflare403Exception({required super.requestOptions, super.message = cloudflare403ExceptionMessage});

  @override
  String toString() => '被网站防火墙拦截（HTTP 403），请尝试验证或切换站点线路';
}
