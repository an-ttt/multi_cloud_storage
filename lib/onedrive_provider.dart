import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'cloud_storage_provider.dart';
import 'exceptions/no_connection_exception.dart';
import 'multi_cloud_storage.dart';

class OneDriveProvider extends CloudStorageProvider {
  final String clientId;
  final String redirectUri;
  bool _isAuthenticated = false;
  String? _accessToken;
  String? _refreshToken;
  DateTime? _tokenExpiry;
  late Dio _dio;
  late final FlutterSecureStorage _secureStorage;
  String? _storageKeyPrefix;
  String? _pkceCodeVerifier;
  String? _state;

  OneDriveProvider._({
    required this.clientId,
    required this.redirectUri,
    String sharedPreferencesName = 'musicgather_secure_storage',
  }) {
    _secureStorage = FlutterSecureStorage(
      aOptions: AndroidOptions(
        encryptedSharedPreferences: false,
        sharedPreferencesName: sharedPreferencesName,
      ),
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
      ),
    );
    _initializeDio();
  }

  static Future<OneDriveProvider?> connect({
    required String clientId,
    required String redirectUri,
    String? scopes,
    String? storageKeyPrefix,
    String sharedPreferencesName = 'musicgather_secure_storage',
  }) async {
    if (clientId.trim().isEmpty) {
      throw ArgumentError(
          'App registration required: https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade');
    }
    if (redirectUri.isEmpty) {
      redirectUri = 'https://login.microsoftonline.com/common/oauth2/nativeclient';
    }
    try {
      final provider = OneDriveProvider._(
        clientId: clientId,
        redirectUri: redirectUri,
        sharedPreferencesName: sharedPreferencesName,
      );
      provider._storageKeyPrefix = storageKeyPrefix;
      final effectiveScopes = scopes ??
          "${MultiCloudStorage.cloudAccess == CloudAccessType.appStorage ? 'Files.ReadWrite.AppFolder' : 'Files.ReadWrite.All'} offline_access User.Read Sites.ReadWrite.All";
      await provider._authenticate(effectiveScopes);
      provider._isAuthenticated = true;
      return provider;
    } on SocketException catch (e) {
      debugPrint('No connection detected.');
      throw NoConnectionException(e.message);
    } catch (e) {
      debugPrint('Exception ${e.toString()}');
      rethrow;
    }
  }

  static Future<OneDriveProvider?> connectWithToken({
    required String clientId,
    required String redirectUri,
    required String accessToken,
    String? refreshToken,
    int? expiresIn,
    String? storageKeyPrefix,
    String sharedPreferencesName = 'musicgather_secure_storage',
  }) async {
    if (clientId.trim().isEmpty) {
      throw ArgumentError(
          'App registration required: https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade');
    }
    if (redirectUri.isEmpty) {
      redirectUri = 'https://login.microsoftonline.com/common/oauth2/nativeclient';
    }
    try {
      final provider = OneDriveProvider._(
        clientId: clientId,
        redirectUri: redirectUri,
        sharedPreferencesName: sharedPreferencesName,
      );
      provider._storageKeyPrefix = storageKeyPrefix;
      provider._accessToken = accessToken;
      provider._refreshToken = refreshToken;
      provider._tokenExpiry = expiresIn != null && expiresIn > 0
          ? DateTime.now().add(Duration(seconds: expiresIn))
          : DateTime.now().add(const Duration(hours: 1));
      provider._isAuthenticated = true;
      await provider._saveTokens();
      debugPrint('OneDrive connectWithToken successful');
      return provider;
    } catch (e) {
      debugPrint('OneDrive connectWithToken exception: ${e.toString()}');
      rethrow;
    }
  }

  static Future<OneDriveProvider?> loadFromStorage({
    required String clientId,
    required String redirectUri,
    required String storageKeyPrefix,
    String sharedPreferencesName = 'musicgather_secure_storage',
  }) async {
    try {
      final provider = OneDriveProvider._(
        clientId: clientId,
        redirectUri: redirectUri,
        sharedPreferencesName: sharedPreferencesName,
      );
      provider._storageKeyPrefix = storageKeyPrefix;
      final accessTokenKey = '${storageKeyPrefix}access_token';
      final refreshTokenKey = '${storageKeyPrefix}refresh_token';
      final tokenExpiryKey = '${storageKeyPrefix}token_expiry';
      final storedAccessToken = await provider._secureStorage.read(key: accessTokenKey);
      final storedRefreshToken = await provider._secureStorage.read(key: refreshTokenKey);
      final storedExpiry = await provider._secureStorage.read(key: tokenExpiryKey);
      if (storedAccessToken == null) return null;
      provider._accessToken = storedAccessToken;
      provider._refreshToken = storedRefreshToken;
      provider._tokenExpiry = storedExpiry != null ? DateTime.tryParse(storedExpiry) : null;
      // expiry 解析失败时，视为 token 已过期，确保后续逻辑能尝试刷新
      if (provider._tokenExpiry == null && storedExpiry != null) {
        debugPrint('OneDrive loadFromStorage: token expiry parse failed, treating as expired.');
        provider._tokenExpiry = DateTime.fromMillisecondsSinceEpoch(0);
      }
      if (provider._tokenExpiry != null && provider._tokenExpiry!.isBefore(DateTime.now())) {
        if (provider._refreshToken != null) {
          try {
            await provider._refreshAccessToken();
          } catch (e) {
            debugPrint('OneDrive loadFromStorage: token refresh failed: $e');
            return null;
          }
        } else {
          debugPrint('OneDrive loadFromStorage: token expired and no refresh token available.');
          return null;
        }
      }
      provider._isAuthenticated = true;
      debugPrint('OneDrive loadFromStorage successful');
      return provider;
    } catch (e) {
      debugPrint('OneDrive loadFromStorage failed: $e');
      return null;
    }
  }

  Future<void> _authenticate(String scopes) async {
    final accessTokenKey = _storageKeyPrefix != null ? '${_storageKeyPrefix}access_token' : 'onedrive_access_token';
    final refreshTokenKey = _storageKeyPrefix != null ? '${_storageKeyPrefix}refresh_token' : 'onedrive_refresh_token';
    final tokenExpiryKey = _storageKeyPrefix != null ? '${_storageKeyPrefix}token_expiry' : 'onedrive_token_expiry';
    _accessToken = await _secureStorage.read(key: accessTokenKey);
    _refreshToken = await _secureStorage.read(key: refreshTokenKey);
    final expiryString = await _secureStorage.read(key: tokenExpiryKey);
    if (expiryString != null) {
      _tokenExpiry = DateTime.parse(expiryString);
    }
    if (_accessToken != null &&
        _tokenExpiry != null &&
        _tokenExpiry!.isAfter(DateTime.now())) {
      debugPrint('OneDriveProvider: Using cached token');
      return;
    }
    if (_refreshToken != null) {
      debugPrint('OneDriveProvider: Refreshing token');
      try {
        await _refreshAccessToken();
        return;
      } catch (e) {
        debugPrint('Token refresh failed, falling back to interactive login');
      }
    }
    debugPrint('OneDriveProvider: Starting interactive login');
    await _performOAuthLogin(scopes);
  }

  Future<void> _performOAuthLogin(String scopes) async {
    final isWindows = Platform.isWindows;
    final isAndroid = Platform.isAndroid;

    // 生成 PKCE 和 state 参数
    _pkceCodeVerifier = _generateCodeVerifier();
    _state = _generateState();

    // 🎯 Android 端使用自定义 Scheme 回调（msal{clientId}://auth），
    //    避免 Auth Tab 的 https 回调拦截不可靠问题
    // 自定义 Scheme 通过 Android Intent 系统路由到 CallbackActivity，
    // 不依赖 Auth Tab 的 ActivityResultLauncher 连接
    String effectiveRedirectUri;
    String callbackScheme;
    if (isAndroid) {
      effectiveRedirectUri = 'msal$clientId://auth';
      callbackScheme = 'msal$clientId';
    } else {
      effectiveRedirectUri = redirectUri;
      callbackScheme = effectiveRedirectUri.split('://')[0];
    }
    
    final authUrl = Uri.https('login.microsoftonline.com', 'common/oauth2/v2.0/authorize', {
      'client_id': clientId,
      'redirect_uri': effectiveRedirectUri,
      'response_type': 'code',
      'scope': scopes,
      'prompt': 'select_account',
      'response_mode': 'query',
      'state': _state,
      'code_challenge_method': 'S256',
      'code_challenge': _generateCodeChallengeS256(_pkceCodeVerifier!),
    });
    FlutterWebAuth2Options options;
    if (isWindows) {
      final redirectUriParsed = Uri.parse(redirectUri);
      if (redirectUriParsed.scheme == 'https' || redirectUriParsed.scheme == 'http') {
        options = FlutterWebAuth2Options(
          useWebview: true,
          httpsHost: redirectUriParsed.host,
          httpsPath: redirectUriParsed.path.isEmpty ? '/' : redirectUriParsed.path,
        );
      } else {
        options = FlutterWebAuth2Options(
          useWebview: true,
        );
      }
    } else if (isAndroid) {
      // 🎯 Android: 自定义 Scheme 回调
      // 使用自定义 Scheme 回调通过 CallbackActivity 拦截，比 https 回调更可靠
      // 注意：MFA 页面自动触发 WebAuthn Conditional UI 可能因 Chrome Android Bug 卡住，
      // 用户需手动点击验证选项（如"人脸、指纹、PIN或安全密钥"）来触发
      options = FlutterWebAuth2Options(
        // 🎯 preferEphemeral: false → 允许共享浏览器会话，使第三方登录
        //    能识别已登录的账号，避免每次重新输入
        // 🎯 customTabsPackageOrder → 优先使用 Chrome，避免 Edge AuthTabIntent 问题
        preferEphemeral: false,
        customTabsPackageOrder: ['com.android.chrome'],
      );
    } else if (callbackScheme == 'https' || callbackScheme == 'http') {
      // iOS: https 回调
      final redirectUriParsed = Uri.parse(effectiveRedirectUri);
      options = FlutterWebAuth2Options(
        preferEphemeral: false,
        httpsHost: redirectUriParsed.host,
        httpsPath: redirectUriParsed.path.isEmpty ? '/' : redirectUriParsed.path,
      );
    } else {
      // iOS: 自定义 Scheme 回调
      options = FlutterWebAuth2Options(
        preferEphemeral: false,
      );
    }
    // 添加超时保护：AuthTabIntent 在部分设备上无法正确拦截回调，
    // 导致 FlutterWebAuth2.authenticate() 的 Future 永远不会 resolve。
    final result = await FlutterWebAuth2.authenticate(
      url: authUrl.toString(),
      callbackUrlScheme: callbackScheme,
      options: options,
    ).timeout(
      const Duration(minutes: 2),
      onTimeout: () {
        debugPrint('OneDrive interactive auth timed out after 2 minutes.');
        throw TimeoutException('OneDrive OAuth authentication timed out');
      },
    );
    final resultUri = Uri.parse(result);
    // 验证 state 参数防止 CSRF 攻击
    final returnedState = resultUri.queryParameters['state'];
    if (returnedState != _state) {
      throw Exception('OAuth state mismatch - possible CSRF attack');
    }
    final code = resultUri.queryParameters['code'];
    if (code == null) {
      throw Exception('Authorization code not found');
    }
    await _exchangeCodeForToken(code, scopes, effectiveRedirectUri);
    _pkceCodeVerifier = null;
    _state = null;
  }

  // M-21 fix: 使用 Dio 替代 http 包，统一超时配置
  Future<void> _exchangeCodeForToken(String code, String scopes, [String? effectiveRedirectUri]) async {
    final dioForToken = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      sendTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
    ));
    final data = {
      'client_id': clientId,
      'redirect_uri': effectiveRedirectUri ?? redirectUri,
      'grant_type': 'authorization_code',
      'code': code,
      'scope': scopes,
    };
    if (_pkceCodeVerifier != null) {
      data['code_verifier'] = _pkceCodeVerifier!;
    }
    final response = await dioForToken.post(
      'https://login.microsoftonline.com/common/oauth2/v2.0/token',
      data: data,
      options: Options(contentType: 'application/x-www-form-urlencoded'),
    );
    if (response.statusCode != 200) {
      throw Exception('Token exchange failed: ${response.data}');
    }
    final json = response.data;
    _accessToken = json['access_token'] as String;
    _refreshToken = json['refresh_token'] as String?;
    _tokenExpiry = DateTime.now().add(Duration(seconds: json['expires_in'] as int));
    await _saveTokens();
  }

  // M-21 fix: 使用 Dio 替代 http 包，统一超时配置
  Future<void> _refreshAccessToken() async {
    if (_refreshToken == null) {
      throw Exception('No refresh token available');
    }
    final dioForToken = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      sendTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
    ));
    final response = await dioForToken.post(
      'https://login.microsoftonline.com/common/oauth2/v2.0/token',
      data: {
        'client_id': clientId,
        'grant_type': 'refresh_token',
        'refresh_token': _refreshToken,
      },
      options: Options(contentType: 'application/x-www-form-urlencoded'),
    );
    if (response.statusCode != 200) {
      throw Exception('Token refresh failed: ${response.data}');
    }
    final json = response.data;
    _accessToken = json['access_token'] as String;
    _refreshToken = json['refresh_token'] as String? ?? _refreshToken;
    _tokenExpiry = DateTime.now().add(Duration(seconds: json['expires_in'] as int));
    await _saveTokens();
  }

  void _initializeDio() {
    _dio = Dio(BaseOptions(
      sendTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
    ));
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        if (_accessToken != null) {
          options.headers['Authorization'] = 'Bearer $_accessToken';
        }
        return handler.next(options);
      },
      onError: (e, handler) async {
        if (e.response?.statusCode == 401 && _refreshToken != null) {
          // S-06 fix: 添加重试计数限制，防止无限循环
          final retryCount = e.requestOptions.extra['onedrive_refresh_retry'] as int? ?? 0;
          if (retryCount >= 1) {
            debugPrint('OneDrive: 401 after refresh attempt, giving up.');
            _isAuthenticated = false;
            return handler.reject(e);
          }
          debugPrint('OneDrive token expired (401). Attempting to refresh token.');
          try {
            await _refreshAccessToken();
            debugPrint('OneDrive token refreshed successfully. Retrying original request.');
            final newHeaders = Map<String, dynamic>.from(e.requestOptions.headers);
            newHeaders['Authorization'] = 'Bearer $_accessToken';
            final response = await _dio.request(
              e.requestOptions.path,
              options: Options(
                method: e.requestOptions.method,
                headers: newHeaders,
                extra: {'onedrive_refresh_retry': retryCount + 1},
              ),
              data: e.requestOptions.data,
              queryParameters: e.requestOptions.queryParameters,
            );
            return handler.resolve(response);
          } catch (refreshError) {
            debugPrint('Failed to refresh OneDrive token: $refreshError');
            _isAuthenticated = false;
            return handler.reject(e);
          }
        }
        return handler.next(e);
      },
    ));
  }

  Future<void> _saveTokens() async {
    final accessTokenKey = _storageKeyPrefix != null ? '${_storageKeyPrefix}access_token' : 'onedrive_access_token';
    final refreshTokenKey = _storageKeyPrefix != null ? '${_storageKeyPrefix}refresh_token' : 'onedrive_refresh_token';
    final tokenExpiryKey = _storageKeyPrefix != null ? '${_storageKeyPrefix}token_expiry' : 'onedrive_token_expiry';
    if (_accessToken != null) {
      await _secureStorage.write(key: accessTokenKey, value: _accessToken!);
    }
    if (_refreshToken != null) {
      await _secureStorage.write(key: refreshTokenKey, value: _refreshToken!);
    }
    if (_tokenExpiry != null) {
      await _secureStorage.write(
          key: tokenExpiryKey, value: _tokenExpiry!.toIso8601String());
    }
  }

  Future<void> _clearTokens() async {
    final accessTokenKey = _storageKeyPrefix != null ? '${_storageKeyPrefix}access_token' : 'onedrive_access_token';
    final refreshTokenKey = _storageKeyPrefix != null ? '${_storageKeyPrefix}refresh_token' : 'onedrive_refresh_token';
    final tokenExpiryKey = _storageKeyPrefix != null ? '${_storageKeyPrefix}token_expiry' : 'onedrive_token_expiry';
    await _secureStorage.delete(key: accessTokenKey);
    await _secureStorage.delete(key: refreshTokenKey);
    await _secureStorage.delete(key: tokenExpiryKey);
    _accessToken = null;
    _refreshToken = null;
    _tokenExpiry = null;
  }

  @override
  Future<List<CloudFile>> listFiles({
    String path = '',
    bool recursive = false,
  }) {
    return _executeRequest(
      () async {
        final effectivePath = path.isEmpty ? '/' : path;
        final encodedPath = _encodePath(effectivePath);
        // S-07 fix: 添加分页逻辑，跟随 @odata.nextLink 获取所有文件
        final List<CloudFile> cloudFiles = [];
        String? nextLink;
        do {
          final url = nextLink ??
              'https://graph.microsoft.com/v1.0/me/drive/root:/$encodedPath/children?\$select=id,name,size,lastModifiedDateTime,folder,file,mimeType';
          final response = await _dio.get(url);
          final List<dynamic> items = response.data['value'];
          cloudFiles.addAll(items.map((item) => _mapToCloudFile(item)));
          nextLink = response.data['@odata.nextLink'] as String?;
        } while (nextLink != null);
        if (recursive) {
          final List<CloudFile> subFolderFiles = [];
          for (final cf in cloudFiles) {
            if (cf.isDirectory) {
              subFolderFiles.addAll(await listFiles(path: cf.path, recursive: true));
            }
          }
          cloudFiles.addAll(subFolderFiles);
        }
        return cloudFiles;
      },
      operation: 'listFiles at $path',
    );
  }

  CloudFile _mapToCloudFile(Map<String, dynamic> item) {
    final isDirectory = item['folder'] != null;
    final path = item['parentReference']?['path'] ?? '';
    final name = item['name'] as String;
    final fullPath = path.isEmpty ? '/$name' : '$path/$name';
    return CloudFile(
      path: fullPath,
      name: name,
      size: item['size'] as int?,
      modifiedTime: item['lastModifiedDateTime'] != null
          ? DateTime.tryParse(item['lastModifiedDateTime'])
          : null,
      isDirectory: isDirectory,
      id: item['id'] as String?,
      mimeType: item['mimeType'] as String?,
    );
  }

  @override
  Future<String> downloadFile({
    required String remotePath,
    required String localPath,
  }) {
    return _executeRequest(
      () async {
        final encodedPath = _encodePath(remotePath);
        final url = 'https://graph.microsoft.com/v1.0/me/drive/root:/$encodedPath:/content';
        await _dio.download(
          url,
          localPath,
        );
        return localPath;
      },
      operation: 'downloadFile from $remotePath',
    );
  }

  // M-19/M-20 fix: 大文件使用上传会话（resumable upload），小文件使用简单上传
  static const _simpleUploadMaxBytes = 4 * 1024 * 1024; // 4MB
  // 每个 chunk 必须是 320 KiB 的倍数（Microsoft Graph API 要求）
  static const _uploadChunkSize = 320 * 1024 * 10; // 3,276,800 bytes = 3.125 MiB

  @override
  Future<String> uploadFile({
    required String localPath,
    required String remotePath,
    Map<String, dynamic>? metadata,
  }) {
    return _executeRequest(
      () async {
        final file = File(localPath);
        final fileSize = await file.length();
        final encodedPath = _encodePath(remotePath);
        if (fileSize <= _simpleUploadMaxBytes) {
          // 小文件：简单上传
          final bytes = await file.readAsBytes();
          final url = 'https://graph.microsoft.com/v1.0/me/drive/root:/$encodedPath:/content';
          await _dio.put(
            url,
            data: bytes,
            options: Options(
              headers: {
                'Content-Type': 'application/octet-stream',
              },
            ),
          );
        } else {
          // 大文件：创建上传会话，分块上传
          // 每个 chunk 大小必须是 320 KiB 的倍数（Microsoft Graph API 要求）
          final createSessionUrl = 'https://graph.microsoft.com/v1.0/me/drive/root:/$encodedPath:/createUploadSession';
          final sessionResponse = await _dio.post(
            createSessionUrl,
            data: {'item': {'@microsoft.graph.conflictBehavior': 'replace'}},
            options: Options(contentType: 'application/json'),
          );
          final uploadUrl = sessionResponse.data['uploadUrl'] as String;
          final chunkDio = Dio(BaseOptions(
            sendTimeout: const Duration(minutes: 5),
            receiveTimeout: const Duration(minutes: 5),
          ));

          int bytesUploaded = 0;
          final stream = file.openRead();
          final buffer = BytesBuilder();

          await for (final chunk in stream) {
            buffer.add(chunk);
            while (buffer.length >= _uploadChunkSize) {
              final bufferedBytes = buffer.takeBytes();
              final uploadChunk = Uint8List.sublistView(
                Uint8List.fromList(bufferedBytes), 0, _uploadChunkSize,
              );
              if (bufferedBytes.length > _uploadChunkSize) {
                buffer.add(Uint8List.sublistView(
                  Uint8List.fromList(bufferedBytes), _uploadChunkSize,
                ));
              }

              final start = bytesUploaded;
              final end = bytesUploaded + uploadChunk.length - 1;
              await chunkDio.put(
                uploadUrl,
                data: Stream.fromIterable([uploadChunk]),
                options: Options(
                  headers: {
                    'Content-Length': uploadChunk.length,
                    'Content-Range': 'bytes $start-$end/$fileSize',
                  },
                ),
              );
              bytesUploaded += uploadChunk.length;
            }
          }

          // 发送剩余数据（最后一块允许小于 320 KiB 的倍数）
          if (buffer.length > 0) {
            final remainingBytes = buffer.takeBytes();
            final uploadChunk = Uint8List.fromList(remainingBytes);
            final start = bytesUploaded;
            final end = bytesUploaded + uploadChunk.length - 1;
            await chunkDio.put(
              uploadUrl,
              data: Stream.fromIterable([uploadChunk]),
              options: Options(
                headers: {
                  'Content-Length': uploadChunk.length,
                  'Content-Range': 'bytes $start-$end/$fileSize',
                },
              ),
            );
            bytesUploaded += uploadChunk.length;
          }
        }
        return remotePath;
      },
      operation: 'uploadFile to $remotePath',
    );
  }

  @override
  Future<void> deleteFile(String path) {
    return _executeRequest(
      () async {
        final encodedPath = _encodePath(path);
        final url = 'https://graph.microsoft.com/v1.0/me/drive/root:/$encodedPath';
        await _dio.delete(
          url,
        );
      },
      operation: 'deleteFile at $path',
    );
  }

  @override
  Future<void> createDirectory(String path) {
    return _executeRequest(
      () async {
        final parentPath = path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';
        final dirName = path.split('/').last;
        String url;
        if (parentPath.isEmpty) {
          url = 'https://graph.microsoft.com/v1.0/me/drive/root/children';
        } else {
          final encodedParentPath = _encodePath(parentPath);
          url = 'https://graph.microsoft.com/v1.0/me/drive/root:/$encodedParentPath/children';
        }
        await _dio.post(
          url,
          data: {
            'name': dirName,
            'folder': {},
            // M-23 fix: 使用 'rename' 而非 'fail'，与其他 Provider 保持幂等创建语义
            '@microsoft.graph.conflictBehavior': 'rename',
          },
        );
      },
      operation: 'createDirectory at $path',
    );
  }

  @override
  Future<CloudFile> getFileMetadata(String path) {
    return _executeRequest(
      () async {
        final encodedPath = _encodePath(path);
        final url = 'https://graph.microsoft.com/v1.0/me/drive/root:/$encodedPath?\$select=id,name,size,lastModifiedDateTime,folder,file,mimeType';
        final response = await _dio.get(
          url,
        );
        return _mapToCloudFile(response.data);
      },
      operation: 'getFileMetadata for $path',
    );
  }

  @override
  Future<String?> loggedInUserDisplayName() {
    return _executeRequest(
      () async {
        final response = await _dio.get(
          'https://graph.microsoft.com/v1.0/me',
        );
        String? name = response.data['displayName'] as String?;
        if (name?.trim().isEmpty ?? true) {
          name = response.data['userPrincipalName'] as String?;
        }
        return name;
      },
      operation: 'loggedInUserDisplayName',
    );
  }

  @override
  Future<Uint8List> getFileRange({
    required String path,
    required int offset,
    required int length,
  }) {
    return _executeRequest(() async {
      final encodedPath = _encodePath(path);
      final url = 'https://graph.microsoft.com/v1.0/me/drive/root:/$encodedPath:/content';
      final response = await _dio.get(
        url,
        options: Options(
          headers: {
            'Range': 'bytes=$offset-${offset + length - 1}',
          },
          responseType: ResponseType.bytes,
        ),
      );
      return Uint8List.fromList(response.data);
    }, operation: 'getFileRange at $path');
  }

  @override
  Future<String?> getDownloadUrl(String path) {
    return _executeRequest(() async {
      final encodedPath = _encodePath(path);
      final url = 'https://graph.microsoft.com/v1.0/me/drive/root:/$encodedPath?\$select=@content.downloadUrl';
      final response = await _dio.get(
        url,
      );
      return response.data['@content.downloadUrl'] as String?;
    }, operation: 'getDownloadUrl for $path');
  }

  @override
  Future<String?> getAccessToken() async {
    if (_accessToken == null ||
        (_tokenExpiry != null && _tokenExpiry!.isBefore(DateTime.now()))) {
      if (_refreshToken != null) {
        try {
          await _refreshAccessToken();
        } catch (e) {
          debugPrint('OneDrive getAccessToken: token refresh failed: $e');
        }
      }
    }
    return _accessToken;
  }

  @override
  Future<String?> getRefreshToken() async => _refreshToken;

  @override
  Future<DateTime?> getTokenExpiry() async => _tokenExpiry;

  @override
  Future<String?> loggedInUserEmail() {
    return _executeRequest(() async {
      final response = await _dio.get(
        'https://graph.microsoft.com/v1.0/me',
      );
      return response.data['mail'] as String? ?? response.data['userPrincipalName'] as String?;
    }, operation: 'loggedInUserEmail');
  }

  @override
  Future<String?> loggedInUserId() {
    return _executeRequest(() async {
      final response = await _dio.get(
        'https://graph.microsoft.com/v1.0/me',
      );
      return response.data['id'] as String?;
    }, operation: 'loggedInUserId');
  }

  @override
  Future<bool> refreshAccessToken() async {
    if (_refreshToken == null) return false;
    try {
      await _refreshAccessToken();
      return true;
    } catch (e) {
      debugPrint('OneDrive refreshAccessToken failed: $e');
      return false;
    }
  }

  @override
  Future<void> saveToStorage(String storageKeyPrefix) async {
    final oldPrefix = _storageKeyPrefix;
    _storageKeyPrefix = storageKeyPrefix;
    await _saveTokens();
    // Clear old keys if they differ from the new prefix
    if (oldPrefix != null && oldPrefix != storageKeyPrefix) {
      final oldAccessTokenKey = '${oldPrefix}access_token';
      final oldRefreshTokenKey = '${oldPrefix}refresh_token';
      final oldTokenExpiryKey = '${oldPrefix}token_expiry';
      await _secureStorage.delete(key: oldAccessTokenKey);
      await _secureStorage.delete(key: oldRefreshTokenKey);
      await _secureStorage.delete(key: oldTokenExpiryKey);
    } else if (oldPrefix == null) {
      // Clear default keys used during initial OAuth
      await _secureStorage.delete(key: 'onedrive_access_token');
      await _secureStorage.delete(key: 'onedrive_refresh_token');
      await _secureStorage.delete(key: 'onedrive_token_expiry');
    }
    debugPrint('OneDrive token saved to storage with prefix: $storageKeyPrefix');
  }

  @override
  Future<bool> tokenExpired() async {
    if (!_isAuthenticated) return true;
    if (_tokenExpiry != null && _tokenExpiry!.isBefore(DateTime.now())) {
      return true;
    }
    try {
      final response = await _dio.get(
        'https://graph.microsoft.com/v1.0/me/drive/root/children?\$select=id&\$top=1',
        options: Options(validateStatus: (status) => status != null && status < 500),
      );
      // M-24 fix: 仅 401/403 表示 token 过期，其他错误不应误判
      if (response.statusCode == 401 || response.statusCode == 403) {
        return true;
      }
      return false;
    } on DioException catch (e) {
      // M-24 fix: 网络错误不应误判为 token 过期
      if (e.error is SocketException) {
        return false;
      }
      if (e.response?.statusCode == 401 || e.response?.statusCode == 403) {
        return true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<bool> logout() async {
    debugPrint("Logging out from OneDrive...");
    try {
      await _clearTokens();
      _isAuthenticated = false;
      return true;
    } catch (error) {
      debugPrint("Error during OneDrive logout: $error");
      return false;
    }
  }

  @override
  Future<Uri?> generateShareLink(String path) {
    return _executeRequest(
      () async {
        final encodedPath = Uri.encodeComponent(path.startsWith('/') ? path.substring(1) : path);
        final url = 'https://graph.microsoft.com/v1.0/me/drive/root:/$encodedPath:/createLink';
        final response = await _dio.post(
          url,
          data: {"type": "edit", "scope": "anonymous"},
        );
        final link = response.data['link']?['webUrl'] as String?;
        return link != null ? Uri.parse(link) : null;
      },
      operation: 'generateShareLink for $path',
    );
  }

  @override
  Future<String?> getShareTokenFromShareLink(Uri shareLink) async {
    return shareLink.toString();
  }

  @override
  Future<String> downloadFileByShareToken({
    required String shareToken,
    required String localPath,
  }) {
    return _executeRequest(
      () async {
        // 通过 Graph API shares 端点解析共享链接，获取 driveId 和 itemId
        // 使用已认证的 Dio 客户端下载，确保需要认证的共享链接也能正常工作
        final resolvedInfo = await _resolveShareUrlForUpload(shareToken);
        if (resolvedInfo == null) {
          throw Exception('Could not resolve the provided sharing URL for download.');
        }
        final downloadUrl = 'https://graph.microsoft.com/v1.0/drives/${resolvedInfo.driveId}/items/${resolvedInfo.itemId}/content';
        await _dio.download(
          downloadUrl,
          localPath,
        );
        return localPath;
      },
      operation: 'downloadFileByShareToken',
    );
  }

  @override
  Future<String> uploadFileByShareToken({
    required String localPath,
    required String shareToken,
    Map<String, dynamic>? metadata,
  }) {
    return _executeRequest(
      () async {
        final fileBytes = await File(localPath).readAsBytes();
        final resolvedInfo = await _resolveShareUrlForUpload(shareToken);
        if (resolvedInfo == null) {
          throw Exception('Could not resolve the provided sharing URL for upload.');
        }
        final uploadUri = Uri.parse(
            'https://graph.microsoft.com/v1.0/drives/${resolvedInfo.driveId}/items/${resolvedInfo.itemId}/content');
        await _dio.put(
          uploadUri.toString(),
          data: fileBytes,
          options: Options(
            headers: {
              'Content-Type': 'application/octet-stream',
            },
          ),
        );
        return shareToken;
      },
      operation: 'uploadToSharedUrl: $shareToken',
    );
  }

  Future<T> _executeRequest<T>(
    Future<T> Function() request, {
    required String operation,
  }) async {
    _checkAuth();
    try {
      debugPrint('Executing OneDrive operation: $operation');
      return await request();
    } on SocketException catch (e) {
      debugPrint('No connection detected.');
      throw NoConnectionException(e.message);
    } on DioException catch (e) {
      if (e.error is SocketException) {
        throw NoConnectionException(e.message ?? e.toString());
      }
      if (e.response?.statusCode == 401) {
        _isAuthenticated = false;
        debugPrint('OneDrive token appears to be expired after refresh attempt. User re-authentication is required.');
      }
      rethrow;
    } catch (e) {
      debugPrint('Error during OneDrive operation: $operation: $e');
      rethrow;
    }
  }

  void _checkAuth() {
    if (!_isAuthenticated) {
      throw Exception('OneDriveProvider: Not authenticated. Call connect() first.');
    }
  }

  Future<_ResolvedShareInfo?> _resolveShareUrlForUpload(String shareUrl) async {
    final encodedUrl = _encodeShareUrlForGraphAPI(shareUrl);
    final url = 'https://graph.microsoft.com/v1.0/shares/$encodedUrl/driveItem?\$select=id,driveId,parentReference,remoteItem';
    final response = await _dio.get(
      url,
      options: Options(
        headers: {
          'Prefer': 'redeemSharingLink',
        },
      ),
    );
    final json = response.data;
    final remoteItem = json['remoteItem'];
    if (remoteItem != null && remoteItem['id'] != null && remoteItem['driveId'] != null) {
      return _ResolvedShareInfo(driveId: remoteItem['driveId'], itemId: remoteItem['id']);
    }
    final itemId = json['id'] as String?;
    final driveId = json['parentReference']?['driveId'] as String?;
    if (itemId != null && driveId != null) {
      return _ResolvedShareInfo(driveId: driveId, itemId: itemId);
    }
    return null;
  }

  String _encodeShareUrlForGraphAPI(String url) {
    // M-22 fix: 去除 base64url 填充字符 '='，Graph API 要求无填充的 base64url 编码
    final base64UrlString = base64Url.encode(utf8.encode(url)).replaceAll('=', '');
    return 'u!$base64UrlString';
  }

  String _encodePath(String path) {
    final cleanPath = path.startsWith('/') ? path.substring(1) : path;
    if (cleanPath.isEmpty) return '';
    return cleanPath.split('/').map(Uri.encodeComponent).join('/');
  }

  // PKCE code_verifier 生成：128 字符，使用 cryptographically secure 随机数
  // 符合 RFC 7636 §4.1（43-128 字符，unreserved 字符集 [A-Za-z0-9-._~]）
  String _generateCodeVerifier() {
    const charset = 'AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwXxYyZz0123456789-._~';
    final random = Random.secure();
    return List.generate(128, (_) => charset[random.nextInt(charset.length)]).join();
  }

  // PKCE code_challenge 计算：BASE64URL(SHA256(code_verifier))，去除 '=' 填充
  // 符合 RFC 7636 §4.2
  String _generateCodeChallengeS256(String codeVerifier) {
    final bytes = utf8.encode(codeVerifier);
    final digest = sha256.convert(bytes);
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }

  // 生成随机 state 参数，防止 CSRF 攻击
  String _generateState() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}

class _ResolvedShareInfo {
  final String driveId;
  final String itemId;

  _ResolvedShareInfo({required this.driveId, required this.itemId});
}