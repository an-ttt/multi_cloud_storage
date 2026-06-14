import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart' as google_sign_in;
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

  google_sign_in.GoogleSignInAccount? _currentAccount;
  google_sign_in.GoogleSignInAuthentication? _currentAuthentication;
  AuthClient? _authClient;
  // 🎯 认证失败标记：signInSilently() 失败后设为 true，不再尝试静默登录
  // 避免 Android 端反复弹出自动登录 UI，直到用户手动重新登录（connect()）后重置
  bool _authFailed = false;
  // 🎯 复用 GoogleSignIn 实例，避免重复创建导致状态丢失
  static google_sign_in.GoogleSignIn? _googleSignIn;
  static String? _initializedServerClientId;
  // 🎯 监听 onCurrentUserChanged 流感知 SDK 内部状态变更
  // 当用户在系统设置中撤销权限、SDK 内部因安全策略自动登出时，
  // 通过此流自动感知并更新 Provider 的认证状态
  static StreamSubscription<google_sign_in.GoogleSignInAccount?>? _currentUserSubscription;
  // 🎯 SDK 层面的登出事件标记：onCurrentUserChanged 流收到 null 时设为 true
  // 实例在 _checkAuth() 中检查此标记，如果为 true 则标记自身认证失效
  static bool _sdkSignOutDetected = false;
  static List<String> scopes = [
    drive.DriveApi.driveAppdataScope,
  ];

  // M-07 fix: 动态获取默认 scopes，基于当前 cloudAccess 值而非类加载时的静态绑定
  // 始终请求两个 scope，支持运行时切换 appStorage/fullDrive 而无需重新 OAuth
  static List<String> _defaultScopes() {
    return [
      drive.DriveApi.driveScope,
      drive.DriveApi.driveAppdataScope,
    ];
  }

  GoogleDriveProvider.internal();

  // 🎯 解析有效的 CloudAccessType：优先使用调用方传入的 cloudAccess，fallback 到全局配置
  CloudAccessType _effectiveCloudAccess(CloudAccessType? cloudAccess) {
    return cloudAccess ?? MultiCloudStorage.cloudAccess;
  }

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
      // 🎯 v6: 通过构造函数创建/复用 GoogleSignIn 实例，传入 scopes 和 clientId
      if (_googleSignIn == null || (serverClientId != null && serverClientId != _initializedServerClientId)) {
        _googleSignIn = google_sign_in.GoogleSignIn(
          scopes: GoogleDriveProvider.scopes,
          clientId: serverClientId,
        );
        _initializedServerClientId = serverClientId;
        // 🎯 监听 onCurrentUserChanged 流感知 SDK 内部状态变更
        // 感知场景：用户在 Android 系统设置中撤销应用权限、SDK 内部因安全策略自动登出、
        // 用户在其他设备上更改密码等。当收到 null 时，设置静态标记，
        // 所有 Provider 实例在 _checkAuth() 中检测到此标记后标记自身认证失效
        _currentUserSubscription?.cancel();
        _currentUserSubscription = _googleSignIn!.onCurrentUserChanged.listen((account) {
          if (account == null) {
            debugPrint('GoogleDriveProvider: onCurrentUserChanged received null - setting sdkSignOutDetected flag');
            _sdkSignOutDetected = true;
          } else {
            debugPrint('GoogleDriveProvider: onCurrentUserChanged received account (${account.email})');
            _sdkSignOutDetected = false;
          }
        });
      } else if (serverClientId != null && serverClientId != _initializedServerClientId) {
        debugPrint(
          'GoogleDriveProvider: GoogleSignIn already created with '
          'clientId=$_initializedServerClientId. Ignoring new '
          'clientId=$serverClientId.',
        );
      }
      google_sign_in.GoogleSignInAccount? account;
      // 🎯 先尝试 signInSilently() 获取已登录账户
      account = await _googleSignIn!.signInSilently();
      if (account == null) {
        // 🎯 silentOnly 模式：signInSilently 失败后指数退避重试
        // 应对安卓端 Google Play Services 初始化时序问题（应用重启后首次调用可能返回 null）
        // 退避策略：500ms → 1s → 2s，最多 3 次重试
        if (silentOnly) {
          const maxRetries = 3;
          const initialDelay = Duration(milliseconds: 500);
          for (var i = 0; i < maxRetries; i++) {
            final delay = initialDelay * (1 << i);
            debugPrint('Google Drive: silentOnly mode, retrying signInSilently after ${delay.inMilliseconds}ms (attempt ${i + 1}/$maxRetries)');
            await Future.delayed(delay);
            account = await _googleSignIn!.signInSilently();
            if (account != null) break;
          }
        }
      }
      if (account == null) {
        if (silentOnly) {
          // 🎯 silentOnly 模式：不调用 signIn()（避免弹出 UI），直接返回 null
          debugPrint('Google Drive: silentOnly mode, skipping signIn()');
          return null;
        }
      }
      debugPrint('Google Drive: signInSilently returned ${account != null ? 'account (${account.email})' : 'null'}');
      // 🎯 forceInteractive=true 时始终调用 signIn()，确保弹出 Google Sign-In UI
      // 修复：signOut() 后 signInSilently() 可能仍返回缓存账户，
      // 导致跳过 signIn() 而直接使用过期账户
      if (forceInteractive && !silentOnly) {
        try {
          debugPrint('Google Drive: calling signIn() to show Google Sign-In UI');
          // 🎯 signIn() 单步超时：防止 Google Play Services 异常导致 Future 永久挂起
          final signInResult = await _googleSignIn!.signIn()
              .timeout(const Duration(seconds: 60), onTimeout: () {
            debugPrint('Google Drive: signIn() timed out after 60s');
            throw TimeoutException('Google Sign-In signIn timed out');
          });
          if (signInResult != null) {
            account = signInResult;
            debugPrint('Google Drive: signIn() returned account (${signInResult.email})');
          } else {
            // 🎯 signIn() 返回 null：用户取消登录
            return null;
          }
        } on PlatformException catch (e) {
          debugPrint('Google Sign-In signIn error: $e');
          if (e.code == 'sign_in_canceled') {
            return null;
          }
          // 🎯 其他 signIn 异常：如果有 signInSilently 的 account 则回退
          if (account != null) {
            debugPrint('Google Drive: signIn failed, falling back to signInSilently account');
          } else {
            rethrow;
          }
        } on TimeoutException {
          // 🎯 signIn() 超时：如果有 signInSilently 的 account 则回退
          if (account != null) {
            debugPrint('Google Drive: signIn timed out, falling back to signInSilently account');
          } else {
            rethrow;
          }
        }
      }
      if (account == null) {
        return null;
      }
      // 🎯 v6: signIn() 已包含 scope 授权，直接获取 authentication 和 authenticatedClient
      final authentication = await account.authentication;
      final client = await _googleSignIn!.authenticatedClient();
      if (client == null) {
        debugPrint('Google Drive: authenticatedClient returned null');
        return null;
      }
      final retryClient = RetryClient(
        client,
        retries: 3,
        when: (response) => {500, 502, 503, 504}.contains(response.statusCode),
        onRetry: (request, response, retryCount) => debugPrint(
            'Retrying request to ${request.url} (Retry #$retryCount)'),
      );
      final provider = GoogleDriveProvider.internal();
      provider._currentAccount = account;
      provider._currentAuthentication = authentication;
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
        await _googleSignIn?.signOut();
      } catch (_) {}
      rethrow;
    }
  }

  @override
  Future<List<CloudFile>> listFiles(
      {String path = '', required bool isPath, bool recursive = false, CloudAccessType? cloudAccess}) {
    return _executeRequest(() async {
      final effectiveAccess = _effectiveCloudAccess(cloudAccess);
      final spaces = effectiveAccess == CloudAccessType.appStorage
          ? 'appDataFolder'
          : 'drive';
      debugPrint('GoogleDriveProvider.listFiles: path=$path, isPath=$isPath, recursive=$recursive, spaces=$spaces');
      final folder = await _getFolderByPath(path, isPath: isPath, cloudAccess: cloudAccess);
      if (folder == null || folder.id == null) {
        debugPrint('GoogleDriveProvider.listFiles: folder not found for path=$path');
        return [];
      }
      final List<CloudFile> cloudFiles = [];
      String? pageToken;
      do {
        final fileList = await driveApi.files.list(
          spaces: effectiveAccess == CloudAccessType.appStorage
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
            // 🎯 优先使用 file ID 作为 CloudFile 的 path，与 Google Drive ID 驱动的设计一致
            String currentItemPath = file.id ?? p.url.join(path, file.name ?? '');
            if ((path == '/' || path.isEmpty) && file.id == null) {
              currentItemPath = file.name ?? '';
            }
            cloudFiles.add(CloudFile(
              path: currentItemPath,
              name: file.name ?? 'Unnamed',
              size: file.size == null ? null : int.tryParse(file.size!),
              // 🎯 不使用 DateTime.now() 作为 fallback：当 modifiedTime 为 null 时保持 null，
              // 让上层（_collectFolderSnapshot）用 -1 作为哨兵值，避免每次调用产生不同时间戳导致误判"有更新"
              modifiedTime: file.modifiedTime,
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
            // 🎯 递归时使用 file ID 而非路径字符串，避免重复解析路径为 ID
            // 有 ID 时 isPath=false，无 ID 回退路径时 isPath=true
            subFolderFiles
                .addAll(await listFiles(path: cf.id ?? cf.path, isPath: cf.id == null, recursive: true, cloudAccess: cloudAccess));
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
    required bool isPath,
    CloudAccessType? cloudAccess,
  }) {
    return _executeRequest(() async {
      final fileId = await _resolveFileId(remotePath, isPath: isPath, cloudAccess: cloudAccess);
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
    required bool isPath,
    Map<String, dynamic>? metadata,
    CloudAccessType? cloudAccess,
  }) {
    return _executeRequest(() async {
      // 🎯 拆分路径为 parent + fileName，优先用 ID 定位父目录
      final fileName = p.basename(remotePath);
      final parentPart = p.dirname(remotePath) == '.' ? '' : p.dirname(remotePath);

      // 先检查文件是否已存在（用 _resolveFileId 解析完整路径）
      final existingFileId = await _resolveFileId(remotePath, isPath: isPath, cloudAccess: cloudAccess);
      if (existingFileId != null) {
        return uploadFileByShareToken(
          localPath: localPath,
          shareToken: existingFileId,
          metadata: metadata,
        );
      }

      // 文件不存在，创建新文件
      final driveFile = drive.File()
        ..name = fileName;

      if (parentPart.isEmpty) {
        final rootId = await _getRootFolderId(cloudAccess);
        driveFile.parents = [rootId];
      } else {
        // 🎯 用 _resolveFileId 解析 parentPart 为 folder ID，避免逐级路径遍历
        // parentPart 的 isPath 与 remotePath 的 isPath 一致
        final parentId = await _resolveFileId(parentPart, isPath: isPath, cloudAccess: cloudAccess);
        if (parentId != null) {
          driveFile.parents = [parentId];
        } else {
          // parent 不存在，创建父目录
          final folder = await _getOrCreateFolder(parentPart, isPath: isPath, cloudAccess: cloudAccess);
          driveFile.parents = [folder.id!];
        }
      }

      final file = File(localPath);
      final media = drive.Media(file.openRead(), await file.length());
      final uploadedFile = await driveApi.files
          .create(driveFile, uploadMedia: media, $fields: 'id, name');
      return uploadedFile.id!;
    });
  }

  // 🎯 直接用 parentId + fileName 上传文件，无需路径解析
  // Google Drive 的 parentId 就是 file ID，直接设置为 drive.File 的 parents
  @override
  Future<String> uploadFileToParent({
    required String localPath,
    required String parentId,
    required String fileName,
    Map<String, dynamic>? metadata,
    CloudAccessType? cloudAccess,
  }) {
    return _executeRequest(() async {
      final driveFile = drive.File()
        ..name = fileName
        ..parents = [parentId];
      final file = File(localPath);
      final media = drive.Media(file.openRead(), await file.length());
      final uploadedFile = await driveApi.files
          .create(driveFile, uploadMedia: media, $fields: 'id, name');
      return uploadedFile.id!;
    });
  }

  @override
  Future<void> deleteFile(String path, {required bool isPath, CloudAccessType? cloudAccess}) {
    return _executeRequest(() async {
      final fileId = await _resolveFileId(path, isPath: isPath, cloudAccess: cloudAccess);
      if (fileId != null) {
        await driveApi.files.delete(fileId);
      }
    });
  }

  @override
  Future<void> createDirectory(String path, {required bool isPath, CloudAccessType? cloudAccess}) {
    return _executeRequest(() async {
      // createDirectory 语义上只接受路径，isPath=false 时传入的是 file ID，语义矛盾
      if (!isPath) {
        throw ArgumentError('createDirectory requires isPath=true, got ID: $path');
      }
      await _getOrCreateFolder(path, isPath: isPath, cloudAccess: cloudAccess);
    });
  }

  @override
  Future<CloudFile> getFileMetadata(String path, {required bool isPath, CloudAccessType? cloudAccess}) {
    return _executeRequest(() async {
      final file = await _getFileByIdOrPath(path, isPath: isPath, cloudAccess: cloudAccess);
      if (file == null) {
        throw Exception('GoogleDriveProvider: File not found at $path');
      }
      return CloudFile(
        path: path,
        name: file.name ?? 'Unnamed',
        size: file.size == null ? null : int.tryParse(file.size!),
        // 🎯 不使用 DateTime.now() 作为 fallback：当 modifiedTime 为 null 时保持 null，
        // 让上层（_collectFolderSnapshot）用 -1 作为哨兵值，避免每次调用产生不同时间戳导致误判"有更新"
        modifiedTime: file.modifiedTime,
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
    required bool isPath,
    required int offset,
    required int length,
    CloudAccessType? cloudAccess,
  }) {
    return _executeRequest(() async {
      final fileId = await _resolveFileId(path, isPath: isPath, cloudAccess: cloudAccess);
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
  Future<String?> getDownloadUrl(String path, {required bool isPath, CloudAccessType? cloudAccess}) {
    return _executeRequest(() async {
      final fileId = await _resolveFileId(path, isPath: isPath, cloudAccess: cloudAccess);
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
      // _executeRequest 内部会先 _refreshAuthClient()（重新 signInSilently 获取最新 token）
      await _executeRequest(() async {
        await driveApi.about.get($fields: 'user');
      });
      return true;
    } catch (e) {
      debugPrint('Google Drive validateCredentials failed: $e');
      // 🎯 凭据验证失败：可能是 invalid_grant（refresh token 已失效）
      // signOut 清除 SDK 缓存的过期凭据，避免后续 signInSilently
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
  Future<Uri?> generateShareLink(String path, {required bool isPath, CloudAccessType? cloudAccess}) {
    return _executeRequest(() async {
      // 🎯 appStorage 模式不支持分享链接（appDataFolder 中的文件无法被其他用户访问）
      if (_effectiveCloudAccess(cloudAccess) == CloudAccessType.appStorage) {
        throw UnsupportedError('generateShareLink is not supported in appStorage mode');
      }
      final fileId = await _resolveFileId(path, isPath: isPath, cloudAccess: cloudAccess);
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
      await _googleSignIn?.signOut();
    } catch (error) {
      debugPrint('Failed to sign out from Google. $error');
    } finally {
      _authClient?.close();
      _authClient = null;
      _currentAccount = null;
      _currentAuthentication = null;
      isAuthenticated = false;
      debugPrint('User signed out from Google Drive.');
    }
  }

  // 🎯 静态登出方法：在 OAuth 前清理 SDK 缓存的登录状态，确保新用户可以登录
  static Future<void> signOutCurrent() async {
    try {
      await _googleSignIn?.signOut();
      await _currentUserSubscription?.cancel();
      _currentUserSubscription = null;
      _googleSignIn = null;
      _initializedServerClientId = null;
      debugPrint('Google Drive SDK signed out (static).');
    } catch (error) {
      debugPrint('Failed to sign out Google Drive SDK (static): $error');
    }
  }

  Future<T> _executeRequest<T>(Future<T> Function() request, {int authRetryCount = 0}) async {
    _checkAuth();
    // 🎯 不再每次请求前强制 refreshAuthClient()
    // authenticatedClient 内部封装了自动带上可用 token 的逻辑，原生 SDK 会自动刷新 access token
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
    // 🎯 检查 SDK 层面的登出事件
    // 如果 onCurrentUserChanged 流收到 null（如用户在系统设置中撤销权限），
    // 标记当前实例认证失效，后续请求会快速失败，引导用户重新登录
    if (_sdkSignOutDetected) {
      isAuthenticated = false;
      _authFailed = true;
      _currentAccount = null;
      _currentAuthentication = null;
      _authClient?.close();
      _authClient = null;
    }
    if (!isAuthenticated) {
      throw Exception(
          'GoogleDriveProvider: Not authenticated. Call connect() first.');
    }
  }

  // 🎯 通用方法：通过 signInSilently() 获取最新授权并重建 DriveApi
  // 提取自 refreshAuthClient/handleAuthErrorAndRetry/refreshAccessToken 三处重复逻辑
  // 返回 true 表示重建成功，false 表示失败
  // 非私有方法，允许桌面端子类重写以使用 signInOffline() 刷新凭据
  Future<bool> _rebuildDriveApi() async {
    if (_googleSignIn == null) return false;
    final account = await _googleSignIn!.signInSilently();
    if (account == null) return false;
    _currentAccount = account;
    _currentAuthentication = await account.authentication;
    final client = await _googleSignIn!.authenticatedClient();
    if (client == null) return false;
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

  // 🎯 通过 signInSilently() 获取最新令牌并重建 AuthClient，而非依赖持久化 token
  // 非私有方法，允许桌面端子类重写以使用 signInOffline() 刷新凭据
  Future<void> refreshAuthClient() async {
    if (_currentAccount == null) return;
    // 🎯 认证已失败，不再尝试 signInSilently()，避免弹出登录 UI
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
      // 🎯 标记认证失败，后续不再尝试 signInSilently()
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
      _currentAuthentication = null;
      throw error;
    }
    // 🎯 认证已失败，不再尝试 signInSilently()，避免弹出登录 UI
    if (_authFailed) {
      debugPrint('Google Drive: auth previously failed, skipping signInSilently() in auth retry');
      throw error;
    }
    try {
      await _rebuildDriveApi();
      isAuthenticated = true;
      debugPrint('Successfully reconnected. Retrying the original request.');
      return await _executeRequest<T>(request, authRetryCount: authRetryCount + 1);
    } catch (e) {
      debugPrint('Failed to reconnect after auth error: $e');
      // 🎯 标记认证失败，后续不再尝试 signInSilently()
      _authFailed = true;
    }
    throw error;
  }

  Future<String> _getRootFolderId([CloudAccessType? cloudAccess]) async {
    return _effectiveCloudAccess(cloudAccess) == CloudAccessType.appStorage
        ? 'appDataFolder'
        : 'root';
  }

  Future<drive.File?> _getFolderByPath(String folderPath, {required bool isPath, CloudAccessType? cloudAccess}) async {
    if (folderPath.isEmpty || folderPath == '.' || folderPath == '/') {
      return _getRootFolder(cloudAccess);
    }
    // 🎯 如果输入是 file ID（isPath=false），直接通过 API 获取文件夹对象
    if (!isPath) {
      try {
        final file = await driveApi.files.get(folderPath,
            $fields: 'id, name, size, modifiedTime, mimeType, parents') as drive.File;
        if (file.id != null) return file;
      } catch (e) {
        debugPrint('GoogleDriveProvider: _getFolderByPath direct ID lookup failed for "$folderPath": $e');
        return null;
      }
    }
    final parts = p.split(folderPath
        .replaceAll(RegExp(r'^/+'), '')
        .replaceAll(RegExp(r'/+$'), ''));
    if (parts.isEmpty || (parts.length == 1 && parts[0].isEmpty)) {
      return _getRootFolder(cloudAccess);
    }
    drive.File currentFolder = await _getRootFolder(cloudAccess);
    for (final part in parts) {
      if (part.isEmpty) continue;
      final folder = await _getFolderByName(currentFolder.id!, part, cloudAccess: cloudAccess);
      if (folder == null) return null;
      currentFolder = folder;
    }
    return currentFolder;
  }

  // 🎯 将输入解析为 Google Drive file ID
  // 如果输入是 file ID（isPath=false），直接返回，无需 API 调用
  // 如果输入是路径（isPath=true），通过 _getFileByPath 解析获取 file ID
  Future<String?> _resolveFileId(String input, {required bool isPath, CloudAccessType? cloudAccess}) async {
    if (!isPath) return input;
    final file = await _getFileByPath(input, cloudAccess: cloudAccess);
    return file?.id;
  }

  // 🎯 优先用 file ID 直接获取完整文件对象，fallback 到路径查找
  // 仅用于需要完整 drive.File 对象的场景（如 getFileMetadata）
  // 只需 file ID 的场景应使用 _resolveFileId，避免多余的 API 调用
  Future<drive.File?> _getFileByIdOrPath(String str, {required bool isPath, CloudAccessType? cloudAccess}) async {
    if (!isPath) {
      try {
        final file = await driveApi.files.get(str, $fields: 'id, name, size, modifiedTime, mimeType, parents') as drive.File;
        if (file.id != null) return file;
      } catch (e) {
        debugPrint('GoogleDriveProvider: direct ID lookup failed for "$str", falling back to path lookup: $e');
      }
    }
    return _getFileByPath(str, cloudAccess: cloudAccess);
  }

  Future<drive.File?> _getFileByPath(String filePath, {CloudAccessType? cloudAccess}) async {
    if (filePath.isEmpty || filePath == '.' || filePath == '/') {
      return (filePath == '/' || filePath == '.') ? _getRootFolder(cloudAccess) : null;
    }

    final normalizedPath =
        filePath.replaceAll(RegExp(r'^/+'), '').replaceAll(RegExp(r'/+$'), '');
    if (normalizedPath.isEmpty) {
      return _getRootFolder(cloudAccess);
    }
    final parts = p.split(normalizedPath);
    drive.File currentFolder = await _getRootFolder(cloudAccess);
    for (var i = 0; i < parts.length - 1; i++) {
      final folderName = parts[i];
      if (folderName.isEmpty) continue;
      final folder = await _getFolderByName(currentFolder.id!, folderName, cloudAccess: cloudAccess);
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
      spaces: _effectiveCloudAccess(cloudAccess) == CloudAccessType.appStorage
          ? 'appDataFolder'
          : 'drive',
      q: query,
      $fields: 'files(id, name, size, modifiedTime, mimeType, parents)',
      pageSize: 1000,
    );
    return fileList.files?.isNotEmpty == true ? fileList.files!.first : null;
  }

  Future<drive.File> _getOrCreateFolder(String folderPath, {required bool isPath, CloudAccessType? cloudAccess}) async {
    if (folderPath.isEmpty || folderPath == '.' || folderPath == '/') {
      return _getRootFolder(cloudAccess);
    }
    // 🎯 如果输入是 file ID（isPath=false），直接通过 API 获取文件夹对象
    if (!isPath) {
      try {
        final file = await driveApi.files.get(folderPath,
            $fields: 'id, name, size, modifiedTime, mimeType, parents') as drive.File;
        if (file.id != null && file.mimeType == 'application/vnd.google-apps.folder') return file;
      } catch (e) {
        debugPrint('GoogleDriveProvider: _getOrCreateFolder direct ID lookup failed for "$folderPath": $e');
        rethrow;
      }
    }
    final normalizedPath = folderPath
        .replaceAll(RegExp(r'^/+'), '')
        .replaceAll(RegExp(r'/+$'), '');
    if (normalizedPath.isEmpty) return _getRootFolder(cloudAccess);
    final parts = p.split(normalizedPath);
    drive.File currentFolder = await _getRootFolder(cloudAccess);
    for (final part in parts) {
      if (part.isEmpty) continue;
      var folder = await _getFolderByName(currentFolder.id!, part, cloudAccess: cloudAccess);
      folder ??= await _createFolder(currentFolder.id!, part);
      currentFolder = folder;
    }
    return currentFolder;
  }

  Future<drive.File> _getRootFolder([CloudAccessType? cloudAccess]) async {
    return drive.File()..id = await _getRootFolderId(cloudAccess);
  }

  Future<drive.File?> _getFolderByName(String parentId, String name, {CloudAccessType? cloudAccess}) async {
    final query =
        "'$parentId' in parents and name = '${_sanitizeQueryString(name)}' and mimeType = 'application/vnd.google-apps.folder' and trashed = false";
    final fileList = await driveApi.files.list(
      spaces: _effectiveCloudAccess(cloudAccess) == CloudAccessType.appStorage
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
    // 🎯 返回 _currentAuthentication 中的 accessToken，该值在以下时机更新：
    // 1. connect() 中首次 signIn()
    // 2. refreshAuthClient() / refreshAccessToken() 中重新 signInSilently()
    // 3. handleAuthErrorAndRetry() 中 401/403 后重新 signInSilently()
    // 调用方应确保在需要最新 token 时先调用 refreshAccessToken()
    return _currentAuthentication?.accessToken;
  }

  @override
  Future<String?> getRefreshToken() async => null;

  @override
  Future<DateTime?> getTokenExpiry() async => null;

  @override
  Future<bool> refreshAccessToken() async {
    if (_currentAccount != null && _currentAuthentication != null) {
      // 🎯 认证已失败，不再尝试 signInSilently()，避免弹出登录 UI
      if (_authFailed) {
        debugPrint('Google Drive: auth previously failed, skipping token refresh');
        return false;
      }
      try {
        return await _rebuildDriveApi();
      } catch (e) {
        debugPrint('Google Drive SDK token refresh failed: $e');
        // 🎯 标记认证失败，后续不再尝试 signInSilently()
        _authFailed = true;
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
