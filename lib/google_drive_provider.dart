import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/googleapis_auth.dart'
    show AccessDeniedException, AuthClient;
import 'package:http/retry.dart';
import 'package:multi_cloud_storage/exceptions/no_connection_exception.dart';
import 'package:path/path.dart' as p;
import 'cloud_storage_provider.dart';
import 'exceptions/not_found_exception.dart';
import 'multi_cloud_storage.dart';

class GoogleDriveProvider extends CloudStorageProvider {
  late drive.DriveApi driveApi;
  bool isAuthenticated = false;

  GoogleSignInAccount? _currentAccount;
  GoogleSignInClientAuthorization? _currentAuthorization;
  AuthClient? _authClient;
  static bool _initialized = false;
  static String? _initializedServerClientId;
  static List<String> scopes = [
    drive.DriveApi.driveAppdataScope,
  ];

  // M-07 fix: 动态获取默认 scopes，基于当前 cloudAccess 值而非类加载时的静态绑定
  static List<String> _defaultScopes() {
    return [
      MultiCloudStorage.cloudAccess == CloudAccessType.appStorage
          ? drive.DriveApi.driveAppdataScope
          : drive.DriveApi.driveScope,
    ];
  }

  GoogleDriveProvider.internal();

  static Future<GoogleDriveProvider?> connect({
    bool forceInteractive = false,
    List<String>? scopes,
    String? serverClientId,
    String? clientSecret,
    int redirectPort = 8000,
  }) async {
    debugPrint("connect Google Drive,  forceInteractive: $forceInteractive");
    // M-07 fix: 未指定 scopes 时动态获取默认值
    if (scopes != null) {
      GoogleDriveProvider.scopes = scopes;
    } else {
      GoogleDriveProvider.scopes = _defaultScopes();
    }
    try {
      if (!_initialized) {
        await GoogleSignIn.instance.initialize(serverClientId: serverClientId);
        _initialized = true;
        _initializedServerClientId = serverClientId;
      } else if (serverClientId != null && serverClientId != _initializedServerClientId) {
        debugPrint(
          'GoogleDriveProvider: GoogleSignIn already initialized with '
          'serverClientId=$_initializedServerClientId. Ignoring new '
          'serverClientId=$serverClientId. initialize() can only be called once.',
        );
      }
      GoogleSignInAccount? account;
      // 🎯 优化：永远先调 attemptLightweightAuthentication()，即使 forceInteractive=true
      // 静默登录成功则避免触发 authenticate() 导致的 "Account reauth failed" 错误
      final lightweightResult =
          GoogleSignIn.instance.attemptLightweightAuthentication();
      if (lightweightResult != null) {
        account = await lightweightResult;
      }
      if (account == null) {
        try {
          account = await GoogleSignIn.instance
              .authenticate(scopeHint: GoogleDriveProvider.scopes);
        } on GoogleSignInException catch (e) {
          debugPrint('Google Sign-In error: $e');
          if (e.code == GoogleSignInExceptionCode.canceled) {
            // 🎯 区分用户主动取消和系统 reauth 失败
            if (e.toString().contains('reauth')) {
              throw GoogleSignInReauthRequiredException(e);
            }
            return null;
          }
          rethrow;
        }
      }
      GoogleSignInClientAuthorization authorization;
      try {
        authorization = await account.authorizationClient
            .authorizeScopes(GoogleDriveProvider.scopes);
      } on GoogleSignInException catch (e) {
        debugPrint('Google Drive scope authorization error: $e');
        if (e.code == GoogleSignInExceptionCode.canceled) {
          return null;
        }
        rethrow;
      }
      final client =
          authorization.authClient(scopes: GoogleDriveProvider.scopes);
      final retryClient = RetryClient(
        client,
        retries: 3,
        when: (response) => {500, 502, 503, 504}.contains(response.statusCode),
        onRetry: (request, response, retryCount) => debugPrint(
            'Retrying request to ${request.url} (Retry #$retryCount)'),
      );
      final provider = GoogleDriveProvider.internal();
      provider._currentAccount = account;
      provider._currentAuthorization = authorization;
      provider._authClient = client;
      provider.driveApi = drive.DriveApi(retryClient);
      provider.isAuthenticated = true;
      debugPrint(
          'Google Drive user signed in: ID=${account.id}, Email=${account.email}');
      return provider;
    } on SocketException catch (e) {
      debugPrint('No internet connection during Google Drive sign-in.');
      throw NoConnectionException(e.message);
    } catch (error) {
      debugPrint(
        'Error occurred during the Google Drive connect process.',
      );
      if (error is PlatformException && error.code == 'network_error') {
        throw NoConnectionException(error.toString());
      }
      try {
        await GoogleSignIn.instance.disconnect();
        await GoogleSignIn.instance.signOut();
      } catch (_) {}
      rethrow;
    }
  }

  @override
  Future<List<CloudFile>> listFiles(
      {String path = '', bool recursive = false}) {
    return _executeRequest(() async {
      final folder = await _getFolderByPath(path);
      if (folder == null || folder.id == null) {
        return [];
      }
      final List<CloudFile> cloudFiles = [];
      String? pageToken;
      do {
        final fileList = await driveApi.files.list(
          spaces: MultiCloudStorage.cloudAccess == CloudAccessType.appStorage
              ? 'appDataFolder'
              : 'drive',
          q: "'${folder.id}' in parents and trashed = false",
          $fields:
              'nextPageToken, files(id, name, size, modifiedTime, mimeType, parents)',
          pageToken: pageToken,
        );
        if (fileList.files != null) {
          for (final file in fileList.files!) {
            // S-02 fix: 使用 p.url.join 确保始终使用正斜杠，避免 Windows 平台使用反斜杠
            String currentItemPath = p.url.join(path, file.name ?? '');
            if (path == '/' || path.isEmpty) currentItemPath = file.name ?? '';
            cloudFiles.add(CloudFile(
              path: currentItemPath,
              name: file.name ?? 'Unnamed',
              size: file.size == null ? null : int.tryParse(file.size!),
              modifiedTime: file.modifiedTime ?? DateTime.now(),
              isDirectory:
                  file.mimeType == 'application/vnd.google-apps.folder',
              id: file.id,
              mimeType: file.mimeType,
              metadata: {
                'id': file.id,
                'mimeType': file.mimeType,
                'parents': file.parents
              },
            ));
          }
        }
        pageToken = fileList.nextPageToken;
      } while (pageToken != null);
      if (recursive) {
        final List<CloudFile> subFolderFiles = [];
        for (final cf in cloudFiles) {
          if (cf.isDirectory) {
            subFolderFiles
                .addAll(await listFiles(path: cf.path, recursive: true));
          }
        }
        cloudFiles.addAll(subFolderFiles);
      }
      return cloudFiles;
    });
  }

  @override
  Future<String> downloadFile({
    required String remotePath,
    required String localPath,
  }) {
    return _executeRequest(() async {
      final file = await _getFileByPath(remotePath);
      if (file == null || file.id == null) {
        throw Exception('GoogleDriveProvider: File not found at $remotePath');
      }
      final output = File(localPath);
      final sink = output.openWrite();
      try {
        final media = await driveApi.files.get(file.id!,
            downloadOptions: drive.DownloadOptions.fullMedia) as drive.Media;
        await media.stream.pipe(sink);
      } catch (e) {
        await sink.close();
        if (await output.exists()) {
          await output.delete();
        }
        rethrow;
      }
      await sink.close();
      return localPath;
    });
  }

  @override
  Future<String> uploadFile({
    required String localPath,
    required String remotePath,
    Map<String, dynamic>? metadata,
  }) {
    return _executeRequest(() async {
      final existingFile = await _getFileByPath(remotePath);
      if (existingFile != null && existingFile.id != null) {
        return uploadFileByShareToken(
          localPath: localPath,
          shareToken: existingFile.id!,
          metadata: metadata,
        );
      } else {
        final file = File(localPath);
        final fileName = p.basename(remotePath);
        final remoteDir = p.dirname(remotePath) == '.' ? '' : p.dirname(remotePath);
        final folder = await _getOrCreateFolder(remoteDir);
        final driveFile = drive.File()
          ..name = fileName
          ..parents = [folder.id!];
        final media = drive.Media(file.openRead(), await file.length());
        final uploadedFile = await driveApi.files
            .create(driveFile, uploadMedia: media, $fields: 'id, name');
        return uploadedFile.id!;
      }
    });
  }

  @override
  Future<void> deleteFile(String path) {
    return _executeRequest(() async {
      final file = await _getFileByPath(path);
      if (file != null && file.id != null) {
        await driveApi.files.delete(file.id!);
      }
    });
  }

  @override
  Future<void> createDirectory(String path) {
    return _executeRequest(() async {
      await _getOrCreateFolder(path);
    });
  }

  @override
  Future<CloudFile> getFileMetadata(String path) {
    return _executeRequest(() async {
      final file = await _getFileByPath(path);
      if (file == null) {
        throw Exception('GoogleDriveProvider: File not found at $path');
      }
      return CloudFile(
        path: path,
        name: file.name ?? 'Unnamed',
        size: file.size == null ? null : int.tryParse(file.size!),
        modifiedTime: file.modifiedTime ?? DateTime.now(),
        isDirectory: file.mimeType == 'application/vnd.google-apps.folder',
        id: file.id,
        mimeType: file.mimeType,
        metadata: {
          'id': file.id,
          'mimeType': file.mimeType,
          'parents': file.parents
        },
      );
    });
  }

  @override
  Future<String?> loggedInUserDisplayName() async {
    return _currentAccount?.displayName;
  }

  @override
  Future<Uint8List> getFileRange({
    required String path,
    required int offset,
    required int length,
  }) {
    return _executeRequest(() async {
      final file = await _getFileByPath(path);
      if (file == null || file.id == null) {
        throw Exception('GoogleDriveProvider: File not found at $path');
      }
      final end = offset + length - 1;
      final media = await driveApi.files.get(
        file.id!,
        downloadOptions: drive.PartialDownloadOptions(drive.ByteRange(offset, end)),
      ) as drive.Media;
      final bytes = await media.stream.fold<BytesBuilder>(
        BytesBuilder(), (b, d) => b..add(d),
      );
      return bytes.toBytes();
    });
  }

  @override
  Future<String?> getDownloadUrl(String path) {
    return _executeRequest(() async {
      final file = await _getFileByPath(path);
      if (file == null || file.id == null) return null;
      final metadata = await driveApi.files
          .get(file.id!, $fields: 'id,webContentLink') as drive.File;
      return metadata.webContentLink;
    });
  }

  @override
  Future<String?> loggedInUserEmail() async => _currentAccount?.email;

  @override
  Future<String?> loggedInUserId() async => _currentAccount?.id;

  @override
  Future<bool> tokenExpired() {
    return _executeRequest(() async {
      await driveApi.about.get($fields: 'user');
      return false;
    })
        .then((_) => false)
        .catchError((_) => true);
  }

  @override
  Future<bool> logout() async {
    if (isAuthenticated) {
      try {
        await signOut();
        isAuthenticated = false;
        return true;
      } catch (e) {
        debugPrint('Error during Google Drive logout: $e');
        return false;
      }
    }
    return true;
  }

  @override
  Future<Uri?> generateShareLink(String path) {
    return _executeRequest(() async {
      final drive.File? file = await _getFileByPath(path);
      if (file == null || file.id == null) {
        return null;
      }
      final permission = drive.Permission()
        ..type = 'anyone'
        ..role = 'writer';
      await driveApi.permissions.create(permission, file.id!, $fields: 'id');
      final fileMetadata = await driveApi.files
          .get(file.id!, $fields: 'id, name, webViewLink') as drive.File;
      if (fileMetadata.webViewLink == null) {
        return null;
      }
      return Uri.parse(fileMetadata.webViewLink!);
    });
  }

  @override
  Future<String?> getShareTokenFromShareLink(Uri shareLink) async {
    final linkStr = shareLink.toString();
    // M-10 fix: 支持多种 Google Drive URL 格式
    // 格式1: /d/FILE_ID/...
    var match = RegExp(r'/d/([a-zA-Z0-9_-]+)').firstMatch(linkStr);
    if (match != null) return match.group(1);
    // 格式2: open?id=FILE_ID
    match = RegExp(r'[?&]id=([a-zA-Z0-9_-]+)').firstMatch(linkStr);
    if (match != null) return match.group(1);
    // 格式3: file/d/FILE_ID/...
    match = RegExp(r'file/d/([a-zA-Z0-9_-]+)').firstMatch(linkStr);
    if (match != null) return match.group(1);
    return null;
  }

  @override
  Future<String> downloadFileByShareToken(
      {required String shareToken, required String localPath}) {
    return _executeRequest(() async {
      final output = File(localPath);
      final sink = output.openWrite();
      try {
        final media = await driveApi.files.get(shareToken,
            downloadOptions: drive.DownloadOptions.fullMedia) as drive.Media;
        await media.stream.pipe(sink);
      } catch (e) {
        // S-03 fix: 流异常时清理部分下载的文件，与 downloadFile 保持一致
        await sink.close();
        if (await output.exists()) {
          await output.delete();
        }
        rethrow;
      }
      await sink.close();
      return localPath;
    });
  }

  @override
  Future<String> uploadFileByShareToken({
    required String localPath,
    required String shareToken,
    Map<String, dynamic>? metadata,
  }) {
    return _executeRequest(() async {
      final file = File(localPath);
      final driveFile = drive.File();
      final media = drive.Media(file.openRead(), await file.length());
      final updatedFile = await driveApi.files
          .update(driveFile, shareToken, uploadMedia: media, $fields: 'id');
      return updatedFile.id!;
    });
  }

  Future<void> signOut() async {
    try {
      await GoogleSignIn.instance.disconnect();
      await GoogleSignIn.instance.signOut();
    } catch (error) {
      debugPrint('Failed to sign out or disconnect from Google. $error');
    } finally {
      _authClient?.close();
      _authClient = null;
      _currentAccount = null;
      _currentAuthorization = null;
      isAuthenticated = false;
      debugPrint('User signed out from Google Drive.');
    }
  }

  // 🎯 静态登出方法：在 OAuth 前清理 SDK 缓存的登录状态，确保新用户可以登录
  static Future<void> signOutCurrent() async {
    try {
      await GoogleSignIn.instance.disconnect();
      await GoogleSignIn.instance.signOut();
      debugPrint('Google Drive SDK signed out (static).');
    } catch (error) {
      debugPrint('Failed to sign out Google Drive SDK (static): $error');
    }
  }

  // 🎯 静默登录验证：检查 SDK 缓存的凭据是否仍然有效，不弹出 UI
  static Future<bool> verifySilentLogin({
    String? serverClientId,
  }) async {
    try {
      if (!_initialized && serverClientId != null) {
        await GoogleSignIn.instance.initialize(serverClientId: serverClientId);
        _initialized = true;
        _initializedServerClientId = serverClientId;
      }
      final lightweightResult =
          GoogleSignIn.instance.attemptLightweightAuthentication();
      if (lightweightResult != null) {
        final account = await lightweightResult;
        if (account != null) {
          debugPrint('Google Drive silent login verified: ${account.email}');
          return true;
        }
      }
      debugPrint('Google Drive silent login failed: no cached account');
      return false;
    } catch (e) {
      debugPrint('Google Drive silent login verification failed: $e');
      return false;
    }
  }

  Future<T> _executeRequest<T>(Future<T> Function() request, {int authRetryCount = 0}) async {
    _checkAuth();
    // 🎯 优化：每次 API 请求前刷新授权，通过 authorizeScopes() 获取最新令牌
    // 而非依赖持久化的 AuthClient 中的过期 token
    if (authRetryCount == 0) {
      await _refreshAuthClient();
    }
    try {
      return await request();
    } on drive.DetailedApiRequestError catch (e, stackTrace) {
      if (e.status == 401 || e.status == 403) {
        return handleAuthErrorAndRetry(request, e, stackTrace, authRetryCount: authRetryCount);
      } else if (e.status == 404) {
        throw NotFoundException(e.message ?? '');
      } else {
        rethrow;
      }
    } on AccessDeniedException catch (e, stackTrace) {
      return handleAuthErrorAndRetry(request, e, stackTrace, authRetryCount: authRetryCount);
    } on SocketException catch (e) {
      debugPrint('No connection detected.');
      throw NoConnectionException(e.message);
    } on Exception catch (e) {
      if (e.toString().contains('File not found')) {
        throw NotFoundException(e.toString());
      }
      rethrow;
    }
  }

  void _checkAuth() {
    if (!isAuthenticated) {
      throw Exception(
          'GoogleDriveProvider: Not authenticated. Call connect() first.');
    }
  }

  // 🎯 通过 authorizeScopes() 获取最新令牌并重建 AuthClient，而非依赖持久化 token
  Future<void> _refreshAuthClient() async {
    if (_currentAccount == null) return;
    try {
      final newAuthorization = await _currentAccount!.authorizationClient
          .authorizeScopes(GoogleDriveProvider.scopes);
      _currentAuthorization = newAuthorization;
      final client = newAuthorization.authClient(scopes: GoogleDriveProvider.scopes);
      _authClient?.close();
      _authClient = client;
      final retryClient = RetryClient(
        client,
        retries: 3,
        when: (response) => {500, 502, 503, 504}.contains(response.statusCode),
        onRetry: (request, response, retryCount) => debugPrint(
            'Retrying request to ${request.url} (Retry #$retryCount)'),
      );
      driveApi = drive.DriveApi(retryClient);
    } catch (e) {
      debugPrint('Google Drive _refreshAuthClient failed: $e');
    }
  }

  Future<T> handleAuthErrorAndRetry<T>(
      Future<T> Function() request, Object error, StackTrace stackTrace, {int authRetryCount = 0}) async {
    if (authRetryCount >= 1) {
      debugPrint('Auth retry limit reached. Throwing original error.');
      throw error;
    }
    debugPrint('Authentication error occurred. Attempting to reconnect...');
    isAuthenticated = false;
    // M-08 fix: _currentAccount 为 null 时清理资源并抛出错误
    if (_currentAccount == null) {
      _authClient?.close();
      _authClient = null;
      _currentAuthorization = null;
      throw error;
    }
    try {
      final newAuthorization = await _currentAccount!.authorizationClient
          .authorizeScopes(GoogleDriveProvider.scopes);
      _currentAuthorization = newAuthorization;
      final client = newAuthorization.authClient(scopes: GoogleDriveProvider.scopes);
      _authClient?.close();
      _authClient = client;
      final retryClient = RetryClient(
        client,
        retries: 3,
        when: (response) => {500, 502, 503, 504}.contains(response.statusCode),
        onRetry: (request, response, retryCount) => debugPrint(
            'Retrying request to ${request.url} (Retry #$retryCount)'),
      );
      driveApi = drive.DriveApi(retryClient);
      isAuthenticated = true;
      debugPrint('Successfully reconnected. Retrying the original request.');
      return await _executeRequest<T>(request, authRetryCount: authRetryCount + 1);
    } catch (e) {
      debugPrint('Failed to reconnect after auth error: $e');
    }
    throw error;
  }

  Future<String> _getRootFolderId() async {
    return MultiCloudStorage.cloudAccess == CloudAccessType.appStorage
        ? 'appDataFolder'
        : 'root';
  }

  Future<drive.File?> _getFolderByPath(String folderPath) async {
    if (folderPath.isEmpty || folderPath == '.' || folderPath == '/') {
      return _getRootFolder();
    }
    final parts = p.split(folderPath
        .replaceAll(RegExp(r'^/+'), '')
        .replaceAll(RegExp(r'/+$'), ''));
    if (parts.isEmpty || (parts.length == 1 && parts[0].isEmpty)) {
      return _getRootFolder();
    }
    drive.File currentFolder = await _getRootFolder();
    for (final part in parts) {
      if (part.isEmpty) continue;
      final folder = await _getFolderByName(currentFolder.id!, part);
      if (folder == null) return null;
      currentFolder = folder;
    }
    return currentFolder;
  }

  Future<drive.File?> _getFileByPath(String filePath) async {
    if (filePath.isEmpty || filePath == '.' || filePath == '/') {
      return (filePath == '/' || filePath == '.') ? _getRootFolder() : null;
    }

    final normalizedPath =
        filePath.replaceAll(RegExp(r'^/+'), '').replaceAll(RegExp(r'/+$'), '');
    if (normalizedPath.isEmpty) {
      return _getRootFolder();
    }
    final parts = p.split(normalizedPath);
    drive.File currentFolder = await _getRootFolder();
    for (var i = 0; i < parts.length - 1; i++) {
      final folderName = parts[i];
      if (folderName.isEmpty) continue;
      final folder = await _getFolderByName(currentFolder.id!, folderName);
      if (folder == null) {
        return null;
      }
      currentFolder = folder;
    }
    final fileName = parts.last;
    if (fileName.isEmpty) return currentFolder;
    final query =
        "'${currentFolder.id}' in parents and name = '${_sanitizeQueryString(fileName)}' and trashed = false";
    final fileList = await driveApi.files.list(
      spaces: MultiCloudStorage.cloudAccess == CloudAccessType.appStorage
          ? 'appDataFolder'
          : 'drive',
      q: query,
      $fields: 'files(id, name, size, modifiedTime, mimeType, parents)',
    );
    return fileList.files?.isNotEmpty == true ? fileList.files!.first : null;
  }

  Future<drive.File> _getOrCreateFolder(String folderPath) async {
    if (folderPath.isEmpty || folderPath == '.' || folderPath == '/') {
      return _getRootFolder();
    }
    final normalizedPath = folderPath
        .replaceAll(RegExp(r'^/+'), '')
        .replaceAll(RegExp(r'/+$'), '');
    if (normalizedPath.isEmpty) return _getRootFolder();
    final parts = p.split(normalizedPath);
    drive.File currentFolder = await _getRootFolder();
    for (final part in parts) {
      if (part.isEmpty) continue;
      var folder = await _getFolderByName(currentFolder.id!, part);
      folder ??= await _createFolder(currentFolder.id!, part);
      currentFolder = folder;
    }
    return currentFolder;
  }

  Future<drive.File> _getRootFolder() async {
    return drive.File()..id = await _getRootFolderId();
  }

  Future<drive.File?> _getFolderByName(String parentId, String name) async {
    final query =
        "'$parentId' in parents and name = '${_sanitizeQueryString(name)}' and mimeType = 'application/vnd.google-apps.folder' and trashed = false";
    final fileList = await driveApi.files.list(
      spaces: MultiCloudStorage.cloudAccess == CloudAccessType.appStorage
          ? 'appDataFolder'
          : 'drive',
      q: query,
      $fields: 'files(id, name, mimeType, parents)',
    );
    return fileList.files?.isNotEmpty == true ? fileList.files!.first : null;
  }

  Future<drive.File> _createFolder(String parentId, String name) async {
    final folder = drive.File()
      ..name = name
      ..mimeType = 'application/vnd.google-apps.folder'
      ..parents = [parentId];
    return await driveApi.files
        .create(folder, $fields: 'id, name, mimeType, parents');
  }

  // M-09 fix: 更全面的转义，覆盖 Google Drive API 查询语法中的特殊字符
  String _sanitizeQueryString(String value) =>
      value.replaceAll('\\', '\\\\')
           .replaceAll("'", "\\'")
           .replaceAll('"', '\\"')
           .replaceAll('\n', '\\n')
           .replaceAll('\r', '\\r');

  @override
  Future<String?> getAccessToken() async {
    if (_currentAuthorization != null) {
      return _currentAuthorization!.accessToken;
    }
    return null;
  }

  @override
  Future<String?> getRefreshToken() async => null;

  @override
  Future<DateTime?> getTokenExpiry() async => null;

  @override
  Future<bool> refreshAccessToken() async {
    if (_currentAccount != null && _currentAuthorization != null) {
      try {
        final newAuthorization = await _currentAccount!.authorizationClient
            .authorizeScopes(GoogleDriveProvider.scopes);
        _currentAuthorization = newAuthorization;
        final client = newAuthorization.authClient(scopes: GoogleDriveProvider.scopes);
        _authClient?.close();
        _authClient = client;
        final retryClient = RetryClient(
          client,
          retries: 3,
          when: (response) => {500, 502, 503, 504}.contains(response.statusCode),
          onRetry: (request, response, retryCount) => debugPrint(
              'Retrying request to ${request.url} (Retry #$retryCount)'),
        );
        driveApi = drive.DriveApi(retryClient);
        return true;
      } catch (e) {
        debugPrint('Google Drive SDK token refresh failed: $e');
        return false;
      }
    }
    return false;
  }

  // Google Drive uses SDK-managed tokens, no storage migration needed
  @override
  Future<void> saveToStorage(String storageKeyPrefix) async {}
}

Future<GoogleDriveProvider?> connectToGoogleDrive(
    {bool forceInteractive = false,
      List<String>? scopes,
      String? serverClientId,
      String? clientSecret,
      int redirectPort = 8000}) =>
    GoogleDriveProvider.connect(
        forceInteractive: forceInteractive,
        scopes: scopes,
        serverClientId: serverClientId,
        clientSecret: clientSecret,
        redirectPort: redirectPort);

// 🎯 Google Sign-In reauth 失败专用异常，区分用户主动取消和系统 reauth 失败
class GoogleSignInReauthRequiredException implements Exception {
  GoogleSignInReauthRequiredException(this.originalError);
  final Object originalError;

  @override
  String toString() => 'GoogleSignInReauthRequiredException: $originalError';
}
