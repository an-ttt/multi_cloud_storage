import 'dart:io';

import 'package:flutter/foundation.dart';
import  'package:multi_cloud_storage/cloud_storage_provider.dart';
import  'package:multi_cloud_storage/google_drive_provider.dart';
import  'package:multi_cloud_storage/google_drive_provider_desktop.dart';
import 'package:multi_cloud_storage/icloud_provider.dart';
import 'package:multi_cloud_storage/onedrive_provider.dart';

import 'package:multi_cloud_storage/dropbox_provider.dart';

enum CloudStorageType { dropbox, oneDrive, googleDrive, icloud }

class MultiCloudStorage {
  // M-01 fix: cloudAccess 使用公开字段，Google Drive Provider 在 connect 时动态读取最新值
  static CloudAccessType cloudAccess = CloudAccessType.fullAccess;

  static Future<CloudStorageProvider?> connectToDropbox(
          {required String appKey,
          required String redirectUri,
          bool forceInteractive = false,
          String? storageKeyPrefix,
          String sharedPreferencesName = 'musicgather_secure_storage',
          Duration connectTimeout = const Duration(seconds: 30),
          Duration sendTimeout = const Duration(seconds: 30),
          Duration receiveTimeout = const Duration(seconds: 30)}) =>
      DropboxProvider.connect(
          appKey: appKey,
          redirectUri: redirectUri,
          forceInteractive: forceInteractive,
          storageKeyPrefix: storageKeyPrefix,
          sharedPreferencesName: sharedPreferencesName,
          connectTimeout: connectTimeout,
          sendTimeout: sendTimeout,
          receiveTimeout: receiveTimeout);

  static Future<CloudStorageProvider?> connectToGoogleDrive(
          {bool forceInteractive = false,
          bool silentOnly = false,
          List<String>? scopes,
          String? serverClientId,
            String? clientSecret,
            int redirectPort = 0}) {
      if (Platform.isWindows || Platform.isLinux) {
        return GoogleDriveProviderDesktop.connect(
              forceInteractive: forceInteractive,
              silentOnly: silentOnly,
              scopes: scopes,
              serverClientId: serverClientId,
              clientSecret: clientSecret,
              redirectPort: redirectPort);
      } else {
        return GoogleDriveProvider.connect(
            forceInteractive: forceInteractive,
            silentOnly: silentOnly,
            scopes: scopes,
            serverClientId: serverClientId,
            clientSecret: clientSecret,
            redirectPort: redirectPort);
      }
  }

  // 🎯 Google Drive SDK 静态登出：清理 SDK 缓存的登录状态
  /// Google Drive 凭据验证：使用 connectToGoogleDrive(silentOnly: true) 恢复凭据
  /// silentOnly 模式下：先尝试 attemptLightweightAuthentication()（含重试），
  /// 失败则返回 null 而非弹出 authenticate() UI
  ///
  /// 移除了原有的 verifySilentLogin() 预检查，因为：
  /// 1. connect() 内部已包含 attemptLightweightAuthentication() 调用，预检查冗余
  /// 2. 预检查失败后直接放弃，导致安卓端重启后无法恢复（attemptLightweightAuthentication
  ///    在应用进程重启后可能返回 null，但 connect() 内部的重试逻辑可能成功）
  /// 3. 预检查和 connect() 分别调用 attemptLightweightAuthentication()，
  ///    两次调用之间可能存在时序差异导致结果不同
  static Future<CloudStorageProvider?> validateGoogleDriveCredentials({
    String? serverClientId,
    String? clientSecret,
    List<String>? scopes,
  }) async {
    try {
      cloudAccess = CloudAccessType.fullAccess;
      final provider = await connectToGoogleDrive(
        serverClientId: serverClientId,
        clientSecret: clientSecret,
        scopes: scopes,
        silentOnly: true,
      );
      if (provider == null) {
        debugPrint('Google Drive: connectToGoogleDrive(silentOnly: true) returned null during validation');
        return null;
      }

      final valid = await provider.validateCredentials();
      if (valid) return provider;

      debugPrint('Google Drive: credentials validation failed (token may be expired or revoked)');
      return null;
    } catch (e) {
      debugPrint('Google Drive credentials validation failed: $e');
      return null;
    }
  }

  static Future<void> signOutGoogleDrive() async {
    if (Platform.isWindows || Platform.isLinux) {
      await GoogleDriveProviderDesktop.signOutCurrent();
    } else {
      await GoogleDriveProvider.signOutCurrent();
    }
  }

  // 🎯 Dropbox 清除默认 key 下的残留 token，确保新建账户时走交互式 OAuth 流程
  static Future<void> clearDropboxDefaultToken({String sharedPreferencesName = 'musicgather_secure_storage'}) async {
    await DropboxProvider.clearDefaultToken(sharedPreferencesName: sharedPreferencesName);
  }

  static Future<void> clearOneDriveDefaultToken({String sharedPreferencesName = 'musicgather_secure_storage'}) async {
    await OneDriveProvider.clearDefaultToken(sharedPreferencesName: sharedPreferencesName);
  }

  static Future<CloudStorageProvider?> connectToIcloud(
          {required String containerId}) =>
      ICloudProvider.connect(containerId: containerId);

  static Future<CloudStorageProvider?> connectToOneDrive({
    required String clientId,
    required String redirectUri,
    String? scopes,
    String? storageKeyPrefix,
    String sharedPreferencesName = 'musicgather_secure_storage',
    Duration connectTimeout = const Duration(seconds: 10),
    Duration sendTimeout = const Duration(seconds: 30),
    Duration receiveTimeout = const Duration(seconds: 30),
  }) =>
      OneDriveProvider.connect(
          clientId: clientId,
          redirectUri: redirectUri,
          scopes: scopes,
          storageKeyPrefix: storageKeyPrefix,
          sharedPreferencesName: sharedPreferencesName,
          connectTimeout: connectTimeout,
          sendTimeout: sendTimeout,
          receiveTimeout: receiveTimeout);

  static Future<CloudStorageProvider?> connectToDropboxWithToken({
    required String appKey,
    required String redirectUri,
    required String accessToken,
    String? refreshToken,
    int? expiresIn,
    String? storageKeyPrefix,
    String sharedPreferencesName = 'musicgather_secure_storage',
    Duration connectTimeout = const Duration(seconds: 30),
    Duration sendTimeout = const Duration(seconds: 30),
    Duration receiveTimeout = const Duration(seconds: 30),
  }) =>
      DropboxProvider.connectWithToken(
          appKey: appKey,
          redirectUri: redirectUri,
          accessToken: accessToken,
          refreshToken: refreshToken,
          expiresIn: expiresIn,
          storageKeyPrefix: storageKeyPrefix,
          sharedPreferencesName: sharedPreferencesName,
          connectTimeout: connectTimeout,
          sendTimeout: sendTimeout,
          receiveTimeout: receiveTimeout);

  static Future<CloudStorageProvider?> connectToOneDriveWithToken({
    required String clientId,
    required String redirectUri,
    required String accessToken,
    String? refreshToken,
    int? expiresIn,
    String? storageKeyPrefix,
    String sharedPreferencesName = 'musicgather_secure_storage',
    Duration connectTimeout = const Duration(seconds: 10),
    Duration sendTimeout = const Duration(seconds: 30),
    Duration receiveTimeout = const Duration(seconds: 30),
  }) =>
      OneDriveProvider.connectWithToken(
          clientId: clientId,
          redirectUri: redirectUri,
          accessToken: accessToken,
          refreshToken: refreshToken,
          expiresIn: expiresIn,
          storageKeyPrefix: storageKeyPrefix,
          sharedPreferencesName: sharedPreferencesName,
          connectTimeout: connectTimeout,
          sendTimeout: sendTimeout,
          receiveTimeout: receiveTimeout);

  static Future<CloudStorageProvider?> loadFromStorage({
    required CloudStorageType type,
    required String storageKeyPrefix,
    String? appKey,
    String? redirectUri,
    String? clientId,
    String? clientSecret,
    String sharedPreferencesName = 'musicgather_secure_storage',
    Duration dropboxConnectTimeout = const Duration(seconds: 30),
    Duration dropboxSendTimeout = const Duration(seconds: 30),
    Duration dropboxReceiveTimeout = const Duration(seconds: 30),
    Duration onedriveConnectTimeout = const Duration(seconds: 10),
    Duration onedriveSendTimeout = const Duration(seconds: 30),
    Duration onedriveReceiveTimeout = const Duration(seconds: 30),
  }) async {
    switch (type) {
      case CloudStorageType.dropbox:
        if (appKey == null || redirectUri == null) return null;
        return DropboxProvider.loadFromStorage(
          appKey: appKey,
          redirectUri: redirectUri,
          storageKeyPrefix: storageKeyPrefix,
          sharedPreferencesName: sharedPreferencesName,
          connectTimeout: dropboxConnectTimeout,
          sendTimeout: dropboxSendTimeout,
          receiveTimeout: dropboxReceiveTimeout,
        );
      case CloudStorageType.oneDrive:
        if (clientId == null || redirectUri == null) return null;
        return OneDriveProvider.loadFromStorage(
          clientId: clientId,
          redirectUri: redirectUri,
          storageKeyPrefix: storageKeyPrefix,
          sharedPreferencesName: sharedPreferencesName,
          connectTimeout: onedriveConnectTimeout,
          sendTimeout: onedriveSendTimeout,
          receiveTimeout: onedriveReceiveTimeout,
        );
      case CloudStorageType.googleDrive:
        // M-02 fix: Google Drive 依赖 SDK 静默登录，不支持 loadFromStorage，抛出 UnsupportedError
        throw UnsupportedError(
            'Google Drive does not support loadFromStorage. Use connectToGoogleDrive instead.');
      case CloudStorageType.icloud:
        // M-02 fix: iCloud 使用系统级认证，不支持 loadFromStorage，抛出 UnsupportedError
        throw UnsupportedError(
            'iCloud does not support loadFromStorage. Use connectToIcloud instead.');
    }
  }
}

enum CloudAccessType { appStorage, fullAccess }
