import 'dart:io';

import  'package:multi_cloud_storage/cloud_storage_provider.dart';
import  'package:multi_cloud_storage/google_drive_provider.dart';
import  'package:multi_cloud_storage/google_drive_provider_desktop.dart';
import 'package:multi_cloud_storage/icloud_provider.dart';
import 'package:multi_cloud_storage/onedrive_provider.dart';

import 'package:multi_cloud_storage/dropbox_provider.dart';

enum CloudStorageType { dropbox, oneDrive, googleDrive, icloud }

class MultiCloudStorage {
  // M-01 fix: cloudAccess 使用公开字段，Google Drive Provider 在 connect 时动态读取最新值
  static CloudAccessType cloudAccess = CloudAccessType.appStorage;

  static Future<CloudStorageProvider?> connectToDropbox(
          {required String appKey,
          required String appSecret,
          required String redirectUri,
          bool forceInteractive = false,
          String? storageKeyPrefix}) =>
      DropboxProvider.connect(
          appKey: appKey,
          appSecret: appSecret,
          redirectUri: redirectUri,
          forceInteractive: forceInteractive,
          storageKeyPrefix: storageKeyPrefix);

  static Future<CloudStorageProvider?> connectToGoogleDrive(
          {bool forceInteractive = false,
          List<String>? scopes,
          String? serverClientId,
            String? clientSecret,
            int redirectPort = 0}) {
      if (Platform.isWindows || Platform.isLinux) {
        return GoogleDriveProviderDesktop.connect(
              forceInteractive: forceInteractive,
              scopes: scopes,
              serverClientId: serverClientId,
              clientSecret: clientSecret,
              redirectPort: redirectPort);
      } else {
        return GoogleDriveProvider.connect(
            forceInteractive: forceInteractive,
            scopes: scopes,
            serverClientId: serverClientId,
            clientSecret: clientSecret,
            redirectPort: redirectPort);
      }
  }

  static Future<CloudStorageProvider?> connectToIcloud(
          {required String containerId}) =>
      ICloudProvider.connect(containerId: containerId);

  static Future<CloudStorageProvider?> connectToOneDrive({
    required String clientId,
    required String redirectUri,
    String? scopes,
    String? storageKeyPrefix,
  }) =>
      OneDriveProvider.connect(
          clientId: clientId,
          redirectUri: redirectUri,
          scopes: scopes,
          storageKeyPrefix: storageKeyPrefix);

  static Future<CloudStorageProvider?> connectToDropboxWithToken({
    required String appKey,
    required String appSecret,
    required String redirectUri,
    required String accessToken,
    String? refreshToken,
    int? expiresIn,
    String? storageKeyPrefix,
  }) =>
      DropboxProvider.connectWithToken(
          appKey: appKey,
          appSecret: appSecret,
          redirectUri: redirectUri,
          accessToken: accessToken,
          refreshToken: refreshToken,
          expiresIn: expiresIn,
          storageKeyPrefix: storageKeyPrefix);

  static Future<CloudStorageProvider?> connectToOneDriveWithToken({
    required String clientId,
    required String redirectUri,
    required String accessToken,
    String? refreshToken,
    int? expiresIn,
    String? storageKeyPrefix,
  }) =>
      OneDriveProvider.connectWithToken(
          clientId: clientId,
          redirectUri: redirectUri,
          accessToken: accessToken,
          refreshToken: refreshToken,
          expiresIn: expiresIn,
          storageKeyPrefix: storageKeyPrefix);

  static Future<CloudStorageProvider?> loadFromStorage({
    required CloudStorageType type,
    required String storageKeyPrefix,
    String? appKey,
    String? appSecret,
    String? redirectUri,
    String? clientId,
    String? clientSecret,
  }) async {
    switch (type) {
      case CloudStorageType.dropbox:
        if (appKey == null || appSecret == null || redirectUri == null) return null;
        return DropboxProvider.loadFromStorage(
          appKey: appKey,
          appSecret: appSecret,
          redirectUri: redirectUri,
          storageKeyPrefix: storageKeyPrefix,
        );
      case CloudStorageType.oneDrive:
        if (clientId == null || redirectUri == null) return null;
        return OneDriveProvider.loadFromStorage(
          clientId: clientId,
          redirectUri: redirectUri,
          storageKeyPrefix: storageKeyPrefix,
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
