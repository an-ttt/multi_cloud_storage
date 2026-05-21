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
  // 🎯 认证失败标记：authorizeScopes() 失败后设为 true，不再尝试 authorizeScopes()
  // 避免 Android 端反复弹出自动登录 UI，直到用户手动重新登录（connect()）后重置
  bool _authFailed = false;
  static bool _initialized = false;
  static String? _initializedServerClientId;
  // 🎯 v7+ 最佳实践：监听 authenticationEvents 流感知 SDK 内部状态变更
  // 当用户在系统设置中撤销权限、SDK 内部因安全策略自动登出时，
  // 通过此流自动感知并更新 Provider 的认证状态
  static StreamSubscription<GoogleSignInAuthenticationEvent>? _authEventsSubscription;
  // 🎯 SDK 层面的登出事件标记：authenticationEvents 流收到 SignOut 事件时设为 true
  // 实例在 _checkAuth() 中检查此标记，如果为 true 则标记自身认证失效
  static bool _sdkSignOutDetected = false;
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
    bool silentOnly = false,
    List<String>? scopes,
    String? serverClientId,
    String? clientSecret,
    int redirectPort = 8000,
  }) async {
    debugPrint("connect Google Drive, forceInteractive: $forceInteractive, silentOnly: $silentOnly");
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
        // 🎯 v7+ 最佳实践：监听 authenticationEvents 流感知 SDK 内部状态变更
        // 感知场景：用户在 Android 系统设置中撤销应用权限、SDK 内部因安全策略自动登出、
        // 用户在其他设备上更改密码等。当收到 SignOut 事件时，设置静态标记，
        // 所有 Provider 实例在 _checkAuth() 中检测到此标记后标记自身认证失效
        _authEventsSubscription?.cancel();
        _authEventsSubscription = GoogleSignIn.instance.authenticationEvents.listen((event) {
          if (event is GoogleSignInAuthenticationEventSignOut) {
            debugPrint('GoogleDriveProvider: authenticationEvents received SignOut event - setting sdkSignOutDetected flag');
            _sdkSignOutDetected = true;
          } else if (event is GoogleSignInAuthenticationEventSignIn) {
            debugPrint('GoogleDriveProvider: authenticationEvents received SignIn event for ${event.user.email}');
            _sdkSignOutDetected = false;
          }
        });
      } else if (serverClientId != null && serverClientId != _initializedServerClientId) {
        debugPrint(
          'GoogleDriveProvider: GoogleSignIn already initialized with '
          'serverClientId=$_initializedServerClientId. Ignoring new '
          'serverClientId=$serverClientId. initialize() can only be called once.',
        );
      }
      GoogleSignInAccount? account;
      GoogleSignInAccount? lightweightAccount;
      // 🎯 先尝试 attemptLightweightAuthentication() 获取已登录账户
      final lightweightResult =
          GoogleSignIn.instance.attemptLightweightAuthentication();
      if (lightweightResult != null) {
        lightweightAccount = await lightweightResult;
      }
      if (lightweightAccount == null) {
        // 🎯 silentOnly 模式：attemptLightweightAuthentication 失败后指数退避重试
        // 应对安卓端 Google Play Services 初始化时序问题（应用重启后首次调用可能返回 null）
        // 退避策略：500ms → 1s → 2s，最多 3 次重试
        if (silentOnly) {
          const maxRetries = 3;
          const initialDelay = Duration(milliseconds: 500);
          for (var i = 0; i < maxRetries; i++) {
            final delay = initialDelay * (1 << i);
            debugPrint('Google Drive: silentOnly mode, retrying attemptLightweightAuthentication after ${delay.inMilliseconds}ms (attempt ${i + 1}/$maxRetries)');
            await Future.delayed(delay);
            final retryResult =
                GoogleSignIn.instance.attemptLightweightAuthentication();
            if (retryResult != null) {
              lightweightAccount = await retryResult;
              if (lightweightAccount != null) break;
            }
          }
        }
      }
      if (lightweightAccount == null) {
        if (silentOnly) {
          // 🎯 silentOnly 模式：不调用 authenticate()（避免弹出 UI），直接返回 null
          debugPrint('Google Drive: silentOnly mode, skipping authenticate()');
          return null;
        }
      }
      // 🎯 v7+ 优化：attemptLightweightAuthentication() 成功时直接使用返回的 account，
      // 跳过 authenticate()，避免 Android 上两次 UI 闪烁（轻量级提示 + 完整登录界面）
      // lightweightAccount 已通过 SDK 验证，后续 authorizeScopes() 会确保 scope 授权
      // 仅在 lightweightAccount 为 null（无缓存账户）时才调用 authenticate()
      // 前置检查 supportsAuthenticate()：v7+ 推荐先确认平台支持 authenticate()
      // 不支持时（如 Web 端）回退到 lightweightAccount + authorizeScopes()
      if (lightweightAccount == null && forceInteractive && !silentOnly && GoogleSignIn.instance.supportsAuthenticate()) {
        try {
          account = await GoogleSignIn.instance
              .authenticate(scopeHint: GoogleDriveProvider.scopes);
        } on GoogleSignInException catch (e) {
          debugPrint('Google Sign-In authenticate error: $e');
          if (e.code == GoogleSignInExceptionCode.canceled) {
            // 🎯 区分用户主动取消和系统 reauth 失败
            if (e.toString().contains('reauth')) {
              // 🎯 reauth 失败：回退到 lightweightAccount + authorizeScopes()
              if (lightweightAccount != null) {
                debugPrint('Google Drive: authenticate reauth failed, falling back to lightweightAccount + authorizeScopes()');
                account = lightweightAccount;
              } else {
                throw GoogleSignInReauthRequiredException(e);
              }
            } else {
              return null;
            }
          } else {
            // 🎯 其他 authenticate 异常：如果有 lightweightAccount 则回退
            if (lightweightAccount != null) {
              debugPrint('Google Drive: authenticate failed, falling back to lightweightAccount + authorizeScopes()');
              account = lightweightAccount;
            } else {
              rethrow;
            }
          }
        }
      } else {
        // 🎯 非 forceInteractive 模式，或平台不支持 authenticate()：
        // 使用 lightweightAccount，后续通过 authorizeScopes() 获取授权
        account = lightweightAccount;
      }
      if (account == null) {
        return null;
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
      provider._authFailed = false; // 🎯 新连接成功，清除认证失败标记
      _sdkSignOutDetected = false; // 🎯 新连接成功，清除 SDK 登出检测标记
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
        // 🎯 连接失败时仅 signOut 清理状态，不 disconnect（不撤销权限）
        await GoogleSignIn.instance.signOut();
      } catch (_) {}
      rethrow;
    }
  }

  @override
  Future<List<CloudFile>> listFiles(
      {String path = '', bool recursive = false}) {
    return _executeRequest(() async {
      final spaces = MultiCloudStorage.cloudAccess == CloudAccessType.appStorage
          ? 'appDataFolder'
          : 'drive';
      debugPrint('GoogleDriveProvider.listFiles: path=$path, recursive=$recursive, spaces=$spaces');
      final folder = await _getFolderByPath(path);
      if (folder == null || folder.id == null) {
        debugPrint('GoogleDriveProvider.listFiles: folder not found for path=$path');
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
          pageSize: 1000,
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
      debugPrint('GoogleDriveProvider.listFiles: found ${cloudFiles.length} files in path=$path');
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
      final fileId = await _resolveFileId(remotePath);
      if (fileId == null) {
        throw Exception('GoogleDriveProvider: File not found at $remotePath');
      }
      final output = File(localPath);
      final sink = output.openWrite();
      try {
        final media = await driveApi.files.get(fileId,
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
      final existingFileId = await _resolveFileId(remotePath);
      if (existingFileId != null) {
        return uploadFileByShareToken(
          localPath: localPath,
          shareToken: existingFileId,
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
      final fileId = await _resolveFileId(path);
      if (fileId != null) {
        await driveApi.files.delete(fileId);
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
      final file = await _getFileByIdOrPath(path);
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
      final fileId = await _resolveFileId(path);
      if (fileId == null) {
        throw Exception('GoogleDriveProvider: File not found at $path');
      }
      final end = offset + length - 1;
      final media = await driveApi.files.get(
        fileId,
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
      final fileId = await _resolveFileId(path);
      if (fileId == null) return null;
      final metadata = await driveApi.files
          .get(fileId, $fields: 'id,webContentLink') as drive.File;
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
    }).catchError((e) {
      // 🎯 仅在 401/403 时视为 Token 过期，网络错误等不视为过期
      if (e is drive.DetailedApiRequestError &&
          (e.status == 401 || e.status == 403)) {
        return true;
      }
      return false;
    });
  }

  @override
  Future<bool> validateCredentials() async {
    if (!isAuthenticated || _currentAccount == null) return false;
    try {
      // 🎯 通过 driveApi.about.get() 发起实际 API 请求验证凭据有效性
      // _executeRequest 内部会先 _refreshAuthClient()（重新 authorizeScopes 获取最新 token）
      await _executeRequest(() async {
        await driveApi.about.get($fields: 'user');
      });
      return true;
    } catch (e) {
      debugPrint('Google Drive validateCredentials failed: $e');
      // 🎯 凭据验证失败：可能是 invalid_grant（refresh token 已失效）
      // signOut 清除 SDK 缓存的过期凭据，避免后续 attemptLightweightAuthentication
      // 继续返回过期账户导致循环重试
      final errorStr = e.toString();
      if (errorStr.contains('invalid_grant') || errorStr.contains('401') || errorStr.contains('403')) {
        debugPrint('Google Drive validateCredentials: auth error detected, signing out to clear stale credentials');
        await signOut();
      }
      return false;
    }
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
      final fileId = await _resolveFileId(path);
      if (fileId == null) {
        return null;
      }
      final permission = drive.Permission()
        ..type = 'anyone'
        ..role = 'reader';
      await driveApi.permissions.create(permission, fileId, $fields: 'id');
      final fileMetadata = await driveApi.files
          .get(fileId, $fields: 'id, name, webViewLink') as drive.File;
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
      // 🎯 仅调用 signOut()，不调用 disconnect()
      // disconnect() 会撤销应用对用户账户的访问权限（revoke grants），
      // 导致重新 OAuth 时必须从头授权所有 scope
      await GoogleSignIn.instance.signOut();
    } catch (error) {
      debugPrint('Failed to sign out from Google. $error');
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
      // 🎯 仅调用 signOut()，不调用 disconnect()
      // disconnect() 会撤销应用对用户账户的访问权限（revoke grants），
      // 导致重新 OAuth 时必须从头授权所有 scope，对重新登录场景过于激进
      await GoogleSignIn.instance.signOut();
      debugPrint('Google Drive SDK signed out (static).');
    } catch (error) {
      debugPrint('Failed to sign out Google Drive SDK (static): $error');
    }
  }

  Future<T> _executeRequest<T>(Future<T> Function() request, {int authRetryCount = 0}) async {
    _checkAuth();
    // 🎯 v7+ 最佳实践：不再每次请求前强制 refreshAuthClient()
    // authClient 内部封装了自动带上可用 token 的逻辑，原生 SDK 会自动刷新 access token
    // 仅在 401/403 错误时通过 handleAuthErrorAndRetry() 刷新凭据
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
    // 🎯 v7+ 最佳实践：检查 SDK 层面的登出事件
    // 如果 authenticationEvents 流收到 SignOut 事件（如用户在系统设置中撤销权限），
    // 标记当前实例认证失效，后续请求会快速失败，引导用户重新登录
    if (_sdkSignOutDetected) {
      isAuthenticated = false;
      _authFailed = true;
      _currentAccount = null;
      _currentAuthorization = null;
      _authClient?.close();
      _authClient = null;
    }
    if (!isAuthenticated) {
      throw Exception(
          'GoogleDriveProvider: Not authenticated. Call connect() first.');
    }
  }

  // 🎯 通用方法：通过 authorizeScopes() 获取最新授权并重建 DriveApi
  // 提取自 refreshAuthClient/handleAuthErrorAndRetry/refreshAccessToken 三处重复逻辑
  // 返回 true 表示重建成功，false 表示失败
  // 非私有方法，允许桌面端子类重写以使用 silentSignIn() 刷新凭据
  Future<bool> _rebuildDriveApi() async {
    if (_currentAccount == null) return false;
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
  }

  // 🎯 通过 authorizeScopes() 获取最新令牌并重建 AuthClient，而非依赖持久化 token
  // 非私有方法，允许桌面端子类重写以使用 silentSignIn() 刷新凭据
  Future<void> refreshAuthClient() async {
    if (_currentAccount == null) return;
    // 🎯 认证已失败，不再尝试 authorizeScopes()，避免弹出登录 UI
    if (_authFailed) {
      isAuthenticated = false;
      return;
    }
    try {
      await _rebuildDriveApi();
    } catch (e) {
      // 🎯 刷新失败时标记认证状态为无效，阻止后续请求使用过期凭据
      // 避免调用方误以为 Token 已更新，后续请求会因 _checkAuth() 失败而快速失败
      isAuthenticated = false;
      debugPrint('Google Drive _refreshAuthClient failed: $e');
      // 🎯 标记认证失败，后续不再尝试 authorizeScopes()
      _authFailed = true;
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
    // 🎯 认证已失败，不再尝试 authorizeScopes()，避免弹出登录 UI
    if (_authFailed) {
      debugPrint('Google Drive: auth previously failed, skipping authorizeScopes() in auth retry');
      throw error;
    }
    try {
      await _rebuildDriveApi();
      isAuthenticated = true;
      debugPrint('Successfully reconnected. Retrying the original request.');
      return await _executeRequest<T>(request, authRetryCount: authRetryCount + 1);
    } catch (e) {
      debugPrint('Failed to reconnect after auth error: $e');
      // 🎯 标记认证失败，后续不再尝试 authorizeScopes()
      _authFailed = true;
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

  // 🎯 判断字符串是否像 Google Drive file ID
  // Google Drive file ID 是 Base64url 编码的字符串，特征：
  // - 仅含字母、数字、_ 和 -（Base64url 字符集）
  // - 长度通常 28-68 字符，最小阈值 15 以排除常见文件夹名
  // - 不含 / 和 \
  static bool _isFileId(String str) {
    if (str.isEmpty || str == 'root' || str == 'appDataFolder') return false;
    if (str.contains('/') || str.contains('\\')) return false;
    if (str.length < 15) return false;
    return RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(str);
  }

  // 🎯 将输入解析为 Google Drive file ID
  // 如果输入已经是 file ID，直接返回，无需 API 调用
  // 如果输入是路径，通过 _getFileByPath 解析获取 file ID
  Future<String?> _resolveFileId(String input) async {
    if (_isFileId(input)) return input;
    final file = await _getFileByPath(input);
    return file?.id;
  }

  // 🎯 优先用 file ID 直接获取完整文件对象，fallback 到路径查找
  // 仅用于需要完整 drive.File 对象的场景（如 getFileMetadata）
  // 只需 file ID 的场景应使用 _resolveFileId，避免多余的 API 调用
  Future<drive.File?> _getFileByIdOrPath(String str) async {
    if (_isFileId(str)) {
      try {
        final file = await driveApi.files.get(str, $fields: 'id, name, size, modifiedTime, mimeType, parents') as drive.File;
        if (file.id != null) return file;
      } catch (e) {
        debugPrint('GoogleDriveProvider: direct ID lookup failed for "$str", falling back to path lookup: $e');
      }
    }
    return _getFileByPath(str);
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
      pageSize: 1000,
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
      pageSize: 1000,
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
    // 🎯 v7+ 最佳实践：不要长期缓存 accessToken 字符串
    // 此处返回 _currentAuthorization 中的 accessToken，该值在以下时机更新：
    // 1. connect() 中首次 authorizeScopes()
    // 2. refreshAuthClient() / refreshAccessToken() 中重新 authorizeScopes()
    // 3. handleAuthErrorAndRetry() 中 401/403 后重新 authorizeScopes()
    // 调用方应确保在需要最新 token 时先调用 refreshAccessToken()
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
      // 🎯 认证已失败，不再尝试 authorizeScopes()，避免弹出登录 UI
      if (_authFailed) {
        debugPrint('Google Drive: auth previously failed, skipping token refresh');
        return false;
      }
      try {
        return await _rebuildDriveApi();
      } catch (e) {
        debugPrint('Google Drive SDK token refresh failed: $e');
        // 🎯 标记认证失败，后续不再尝试 authorizeScopes()
        _authFailed = true;
        return false;
      }
    }
    return false;
  }

  // Google Drive uses SDK-managed tokens, no storage migration needed
  @override
  Future<void> saveToStorage(String storageKeyPrefix) async {}

  // 🎯 Google Drive 的 file ID 不需要路径规范化，原样传递
  // GoogleDriveProvider 内部的 _getFileByIdOrPath 会自动判断是 file ID 还是路径
  @override
  String normalizePath(String path) {
    if (path.isEmpty) return '/';
    if (path == 'root') return '/';
    return path;
  }
}

Future<GoogleDriveProvider?> connectToGoogleDrive(
    {bool forceInteractive = false,
      bool silentOnly = false,
      List<String>? scopes,
      String? serverClientId,
      String? clientSecret,
      int redirectPort = 8000}) =>
    GoogleDriveProvider.connect(
        forceInteractive: forceInteractive,
        silentOnly: silentOnly,
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
