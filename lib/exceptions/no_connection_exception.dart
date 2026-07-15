import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

class NoConnectionException implements Exception {
  final String message;
  final String? resourceId;

  NoConnectionException(this.message, {this.resourceId});

  @override
  String toString() =>
      'NoConnectionException: $message (resourceId: $resourceId)';
}

/// 判断异常是否为网络错误（SocketException/TimeoutException/DioException 连接类错误）
/// 网络错误应向上抛出由调用方处理，不应被吞掉返回 null
bool isNetworkException(Object e) {
  if (e is SocketException || e is TimeoutException) return true;
  if (e is DioException) {
    return e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.connectionError;
  }
  return false;
}
