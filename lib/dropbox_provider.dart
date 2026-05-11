import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:path/path.dart' as p;

import 'cloud_storage_provider.dart';
import 'exceptions/no_connection_exception.dart';
import 'exceptions/not_found_exception.dart';

class DropboxProvider extends CloudStorageProvider {
  // --- Configuration Properties ---
  final String _appKey;
  final String _appSecret;
  final String _redirectUri;

  // --- Token storage ---
  final _secureStorage = const FlutterSecureStorage();
  static const _kDropboxTokenKey = 'dropbox_token';
  String? _storageKeyPrefix;

  late Dio _dio;
  DropboxToken? _token;
  DropboxAccount? _account;
  String? _pkceCodeVerifier;

  bool _isAuthenticated = false;

  /// Private constructor used by the static `connect` method.
  DropboxProvider._create({
    required String appKey,
    required String appSecret,
    required String redirectUri,
  })  : _appKey = appKey,
        _appSecret = appSecret,
        _redirectUri = redirectUri {
    _initializeDio();
  }

  /// Creates and authenticates a [DropboxProvider] instance.
  /// Handles both silent sign-in and interactive user login.
  static Future<DropboxProvider?> connect({
    required String appKey,
    required String appSecret,
    required String redirectUri,
    bool forceInteractive = false,
    String? storageKeyPrefix,
  }) async {
    debugPrint('connect Dropbox, forceInteractive: $forceInteractive');
    if (appKey.isEmpty || redirectUri.isEmpty) {
      debugPrint(
          'Dropbox connection failed: App Key or Redirect URI is missing.');
      return null;
    }
    try {
      final provider = DropboxProvider._create(
          appKey: appKey, appSecret: appSecret, redirectUri: redirectUri);
      provider._storageKeyPrefix = storageKeyPrefix;
      // If interactive login is forced, clear any existing credentials.
      if (forceInteractive) {
        debugPrint('Forcing interactive login, clearing existing token.');
        await provider._clearToken();
      }
      // Attempt to sign in silently with a stored token.
      DropboxToken? storedToken = await provider._getToken();
      if (storedToken != null) {
        provider._token = storedToken;
        if (provider._token!.isExpired) {
          debugPrint('Stored Dropbox token is expired, attempting refresh.');
          // M-06 fix: 刷新失败时清除 token 并返回 null，避免状态不一致
          try {
            await provider._refreshToken();
            await provider._saveToken(provider._token);
          } catch (e) {
            debugPrint('Dropbox connect: stored token refresh failed: $e');
            provider._token = null;
            return null;
          }
        }
        await provider._fetchCurrentUserAccount();
        provider._isAuthenticated = true;
        debugPrint(
            'Dropbox silent sign-in successful for ${provider._account?.email}');
        return provider;
      }
      // If no token exists, start the interactive login flow.
      debugPrint('No valid token found. Starting interactive Dropbox login.');
      final authCode = await provider._getAuthCodeViaInteractiveFlow();
      if (authCode == null) {
        debugPrint('Interactive Dropbox login cancelled by user.');
        provider._pkceCodeVerifier = null;
        return null;
      }
      await provider._completeConnection(authCode);
      await provider._saveToken(provider._token);
      debugPrint(
          'Interactive Dropbox login successful for ${provider._account?.email}');
      return provider;
    } on SocketException catch (e) {
      debugPrint('No connection detected.');
      throw NoConnectionException(e.message);
    } catch (error) {
      debugPrint(
          'Error occurred during the Dropbox connect process. Clearing credentials.');
      rethrow;
    }
  }

  static Future<DropboxProvider?> connectWithToken({
    required String appKey,
    required String appSecret,
    required String redirectUri,
    required String accessToken,
    String? refreshToken,
    int? expiresIn,
    String? storageKeyPrefix,
  }) async {
    if (appKey.isEmpty || redirectUri.isEmpty) {
      debugPrint(
          'Dropbox connectWithToken failed: App Key or Redirect URI is missing.');
      return null;
    }
    try {
      final provider = DropboxProvider._create(
          appKey: appKey, appSecret: appSecret, redirectUri: redirectUri);
      provider._storageKeyPrefix = storageKeyPrefix;
      provider._token = DropboxToken(
        accessToken: accessToken,
        refreshToken: refreshToken,
        tokenType: 'bearer',
        expiresIn: expiresIn != null && expiresIn > 0
            ? DateTime.now().add(Duration(seconds: expiresIn))
            : DateTime.now().add(const Duration(hours: 4)),
      );
      provider._isAuthenticated = true;
      await provider._saveToken(provider._token);
      try {
        await provider._fetchCurrentUserAccount();
      } catch (e) {
        debugPrint('Dropbox connectWithToken: failed to fetch user account: $e');
      }
      debugPrint('Dropbox connectWithToken successful for ${provider._account?.email}');
      return provider;
    } catch (error) {
      debugPrint('Error occurred during Dropbox connectWithToken: $error');
      rethrow;
    }
  }

  static Future<DropboxProvider?> loadFromStorage({
    required String appKey,
    required String appSecret,
    required String redirectUri,
    required String storageKeyPrefix,
  }) async {
    try {
      final provider = DropboxProvider._create(
          appKey: appKey, appSecret: appSecret, redirectUri: redirectUri);
      provider._storageKeyPrefix = storageKeyPrefix;
      final token = await provider._getToken();
      if (token == null) return null;
      provider._token = token;
      // S-01 fix: token 过期且无 refreshToken 时应返回 null，而非返回不可用的 provider
      if (token.isExpired) {
        if (token.refreshToken == null) {
          debugPrint('Dropbox loadFromStorage: token expired and no refresh token available.');
          return null;
        }
        try {
          await provider._refreshToken();
          await provider._saveToken(provider._token);
        } catch (e) {
          debugPrint('Dropbox loadFromStorage: token refresh failed: $e');
          return null;
        }
      }
      try {
        await provider._fetchCurrentUserAccount();
      } catch (e) {
        debugPrint('Dropbox loadFromStorage: fetch user account failed: $e');
      }
      provider._isAuthenticated = true;
      debugPrint('Dropbox loadFromStorage successful for ${provider._account?.email}');
      return provider;
    } catch (e) {
      debugPrint('Dropbox loadFromStorage failed: $e');
      return null;
    }
  }

  /// Lists all files and directories at the specified [path].
  @override
  Future<List<CloudFile>> listFiles(
      {String path = '', bool recursive = false}) {
    return _executeRequest(() async {
      final List<CloudFile> allFiles = [];
      String? cursor;
      bool hasMore = true;
      String initialPath = path == '/' ? '' : _normalizePath(path);
      debugPrint(
          'Listing files in Dropbox path: "$initialPath", recursive: $recursive');
      // Paginate through results using the cursor until all files are fetched.
      while (hasMore) {
        Response response;
        if (cursor == null) {
          // First request.
          response = await _dio.post(
            'https://api.dropboxapi.com/2/files/list_folder',
            data: jsonEncode(
                {'path': initialPath, 'recursive': recursive, 'limit': 1000}),
            options: Options(contentType: 'application/json'),
          );
        } else {
          // Subsequent paged requests.
          debugPrint('Fetching next page of files with cursor...');
          response = await _dio.post(
            'https://api.dropboxapi.com/2/files/list_folder/continue',
            data: jsonEncode({'cursor': cursor}),
            options: Options(contentType: 'application/json'),
          );
        }
        final entries = response.data['entries'] as List;
        allFiles.addAll(
            entries.map((e) => _mapToCloudFile(e as Map<String, dynamic>)));
        hasMore = response.data['has_more'] as bool;
        cursor = response.data['cursor'] as String?;
      }
      debugPrint('Found ${allFiles.length} files/folders in "$initialPath".');
      return allFiles;
    });
  }

  /// Downloads a file from a [remotePath] to a [localPath] on the device.
  @override
  Future<String> downloadFile(
      {required String remotePath, required String localPath}) {
    return _executeRequest(() async {
      final normalizedPath = _normalizePath(remotePath);
      debugPrint(
          'Downloading from Dropbox path: $normalizedPath to $localPath');
      final response = await _dio.post(
        'https://content.dropboxapi.com/2/files/download',
        options: Options(
          headers: {
            'Dropbox-API-Arg': jsonEncode({'path': normalizedPath})
          },
          responseType: ResponseType.stream, // Download as a stream.
        ),
      );
      final file = File(localPath);
      final sink = file.openWrite();
      final Stream<Uint8List> stream = response.data.stream;
      await stream.cast<List<int>>().pipe(sink); // Pipe stream to file.
      debugPrint('Successfully downloaded file to $localPath');
      return localPath;
    });
  }

  /// Uploads a file from a [localPath] to a [remotePath] in the dropbox.
  @override
  Future<String> uploadFile(
      {required String localPath,
      required String remotePath,
      Map<String, dynamic>? metadata}) {
    return _executeRequest(() async {
      final file = File(localPath);
      final fileSize = await file.length();
      final normalizedPath = _normalizePath(remotePath);
      debugPrint('Uploading $localPath to Dropbox at $normalizedPath');
      final response = await _dio.post(
        'https://content.dropboxapi.com/2/files/upload',
        data: file.openRead(),
        options: Options(
          headers: {
            // Dropbox API arguments are passed in a JSON header.
            'Dropbox-API-Arg': jsonEncode({
              'path': normalizedPath,
              'mode': 'overwrite',
              'autorename': false,
            }),
            'Content-Type': 'application/octet-stream',
            'Content-Length': fileSize,
          },
        ),
      );
      debugPrint(
          'Successfully uploaded file to Dropbox, ID: ${response.data['id']}');
      return response.data['id'];
    });
  }

  /// Deletes the file or directory at the specified [path].
  @override
  Future<void> deleteFile(String path) {
    return _executeRequest(() async {
      final normalizedPath = _normalizePath(path);
      debugPrint('Attempting to delete Dropbox path: $normalizedPath');
      try {
        await _dio.post(
          'https://api.dropboxapi.com/2/files/delete_v2',
          data: jsonEncode({'path': normalizedPath}),
          options: Options(contentType: 'application/json'),
        );
        debugPrint('Successfully deleted path: $normalizedPath');
      } on DioException catch (e) {
        // If the file doesn't exist, treat it as a successful deletion.
        if (e.response?.data?['error_summary']
                ?.contains('path_lookup/not_found') ==
            true) {
          debugPrint(
              'Path not found during deletion, considering it a success: $normalizedPath');
        } else {
          rethrow;
        }
      }
    });
  }

  /// Creates a new directory at the specified [path].
  @override
  Future<void> createDirectory(String path) {
    return _executeRequest(() async {
      final normalizedPath = _normalizePath(path);
      debugPrint('Creating Dropbox directory: $normalizedPath');
      try {
        await _dio.post(
          'https://api.dropboxapi.com/2/files/create_folder_v2',
          data: jsonEncode({'path': normalizedPath, 'autorename': false}),
          options: Options(contentType: 'application/json'),
        );
        debugPrint('Successfully created directory: $normalizedPath');
      } on DioException catch (e) {
        // If the directory already exists, treat it as a success.
        if (e.response?.data?['error_summary']
                ?.contains('path/conflict/folder') ==
            true) {
          debugPrint(
              'Directory already exists, ignoring creation: $normalizedPath');
        } else {
          rethrow;
        }
      }
    });
  }

  /// Retrieves metadata for the file or directory at the specified [path].
  @override
  Future<CloudFile> getFileMetadata(String path) {
    return _executeRequest(() async {
      final normalizedPath = _normalizePath(path);
      debugPrint('Getting metadata for Dropbox path: $normalizedPath');
      final response = await _dio.post(
        'https://api.dropboxapi.com/2/files/get_metadata',
        data: jsonEncode({'path': normalizedPath}),
        options: Options(contentType: 'application/json'),
      );
      return _mapToCloudFile(response.data);
    });
  }

  /// Retrieves the display name of the currently logged-in user.
  @override
  Future<String?> loggedInUserDisplayName() async => _account?.displayName;

  @override
  Future<Uint8List> getFileRange({
    required String path,
    required int offset,
    required int length,
  }) {
    return _executeRequest(() async {
      final normalizedPath = _normalizePath(path);
      final response = await _dio.post(
        'https://content.dropboxapi.com/2/files/download',
        options: Options(
          headers: {
            'Dropbox-API-Arg': jsonEncode({'path': normalizedPath}),
            'Range': 'bytes=$offset-${offset + length - 1}',
          },
          responseType: ResponseType.bytes,
        ),
      );
      return Uint8List.fromList(response.data);
    });
  }

  @override
  Future<String?> getDownloadUrl(String path) {
    return _executeRequest(() async {
      final normalizedPath = _normalizePath(path);
      final response = await _dio.post(
        'https://api.dropboxapi.com/2/files/get_temporary_link',
        data: jsonEncode({'path': normalizedPath}),
        options: Options(contentType: 'application/json'),
      );
      return response.data['link'] as String?;
    });
  }

  @override
  Future<String?> getAccessToken() async {
    if (_token == null) return null;
    // M-04 fix: 捕获刷新失败异常，返回 null 而非传播异常
    if (_token!.isExpired && _token!.refreshToken != null) {
      try {
        await _refreshToken();
        await _saveToken(_token);
      } catch (e) {
        debugPrint('Dropbox getAccessToken: token refresh failed: $e');
        return null;
      }
    }
    return _token!.accessToken;
  }

  @override
  Future<String?> getRefreshToken() async => _token?.refreshToken;

  @override
  Future<DateTime?> getTokenExpiry() async => _token?.expiresIn;

  @override
  Future<String?> loggedInUserEmail() async => _account?.email;

  @override
  Future<String?> loggedInUserId() async => _account?.accountId;

  @override
  Future<bool> refreshAccessToken() async {
    if (_token?.refreshToken == null) return false;
    try {
      await _refreshToken();
      await _saveToken(_token);
      return true;
    } catch (e) {
      debugPrint('Dropbox refreshAccessToken failed: $e');
      return false;
    }
  }

  /// Checks if the current user's authentication token is expired.
  @override
  Future<bool> tokenExpired() async => _token?.isExpired ?? true;

  /// Logs out the current user from dropbox.
  @override
  Future<bool> logout() async {
    debugPrint('Logging out from Dropbox.');
    if (_isAuthenticated && _token != null) {
      try {
        // Attempt to revoke the token on Dropbox's servers.
        await _dio.post('https://api.dropboxapi.com/2/auth/token/revoke');
        debugPrint('Successfully revoked Dropbox token via API.');
      } catch (e) {
        debugPrint(
            'Failed to revoke Dropbox token via API, but logging out locally anyway.');
      }
    }
    // Clear local state regardless of API call success.
    await _clearToken();
    _token = null;
    _account = null;
    _isAuthenticated = false;
    return true;
  }

  /// Generates a shareable link for the file or directory at the [path].
  @override
  Future<Uri?> generateShareLink(String path) {
    return _executeRequest(() async {
      final normalizedPath = _normalizePath(path);
      debugPrint('Generating sharable link for Dropbox path: $normalizedPath');
      try {
        // Attempt to create a new public, editable share link.
        final response = await _dio.post(
          'https://api.dropboxapi.com/2/sharing/create_shared_link_with_settings',
          data: jsonEncode({
            'path': normalizedPath,
            'settings': {'requested_visibility': 'public', 'access': 'editor'}
          }),
          options: Options(contentType: 'application/json'),
        );
        final url = response.data['url'];
        debugPrint('Created sharable link: $url');
        return url == null ? null : Uri.parse(url);
      } on DioException catch (e) {
        // If a link already exists, fetch the existing one.
        if (e.response?.data?['error_summary']
                ?.contains('shared_link_already_exists') ==
            true) {
          debugPrint(
              'Share link already exists for $normalizedPath, fetching existing one.');
          final listResponse = await _dio.post(
            'https://api.dropboxapi.com/2/sharing/list_shared_links',
            data: jsonEncode({'path': normalizedPath, 'direct_only': true}),
            options: Options(contentType: 'application/json'),
          );
          final links = listResponse.data['links'] as List?;
          if (links != null && links.isNotEmpty) {
            final url = links.first['url'];
            debugPrint('Fetched existing sharable link: $url');
            return url == null ? null : Uri.parse(url);
          }
        }
        rethrow;
      }
    });
  }

  @override
  Future<String?> getShareTokenFromShareLink(Uri shareLink) async {
    throw UnsupportedError(
        'getShareTokenFromShareLink is not supported for dropbox');
  }

  @override
  Future<String> uploadFileByShareToken(
      {required String localPath,
      required String shareToken,
      Map<String, dynamic>? metadata}) async {
    throw UnsupportedError(
        'uploadFileByShareToken is not supported for dropbox');
  }

  @override
  Future<String> downloadFileByShareToken(
      {required String shareToken, required String localPath}) async {
    throw UnsupportedError(
        'downloadFileByShareToken is not supported for dropbox');
  }

  /// A centralized wrapper for executing API requests.
  /// It ensures authentication and handles common API errors.
  Future<T> _executeRequest<T>(Future<T> Function() request) async {
    _checkAuth();
    try {
      return await request();
    } on SocketException catch (e) {
      debugPrint('No connection detected.');
      throw NoConnectionException(e.message);
    } on DioException catch (e) {
      debugPrint('A DioException occurred in Dropbox request');
      if (e.error is SocketException) {
        throw NoConnectionException(e.message ?? e.toString());
      }
      // M-05 fix: 仅将 path_lookup/not_found 类型的 409 当作 NotFoundException，
      // 其他 409 错误（如 path/conflict、too_many_write_operations）应正常抛出
      if (e.response?.statusCode == 409) {
        final errorSummary = e.response?.data?['error_summary'] as String?;
        if (errorSummary != null && errorSummary.contains('path_lookup/not_found')) {
          throw NotFoundException(e.message ?? e.toString());
        }
      }
      if (e.response?.data is Map) {
        final errorSummary = e.response?.data?['error_summary'];
        if (errorSummary != null) {
          throw Exception('Dropbox API Error: $errorSummary');
        }
      }
      rethrow;
    } catch (e) {
      debugPrint('An unexpected error occurred in Dropbox request');
      rethrow;
    }
  }

  /// Initializes the Dio HTTP client with interceptors for auth and token refresh.
  void _initializeDio() {
    _dio = Dio(BaseOptions(
        sendTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 30)));
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        if (_token != null) {
          options.headers['Authorization'] = 'Bearer ${_token!.accessToken}';
        }
        return handler.next(options);
      },
      onError: (e, handler) async {
        if (e.response?.statusCode == 401 && _token?.refreshToken != null) {
          final retryCount = e.requestOptions.extra['dropbox_refresh_retry'] as int? ?? 0;
          if (retryCount >= 1) {
            debugPrint('Dropbox: 401 after refresh attempt, giving up.');
            await logout();
            return handler.reject(e);
          }
          debugPrint(
              'Token expired (401). Attempting to refresh Dropbox token.');
          try {
            await _refreshToken();
            await _saveToken(_token);
            debugPrint(
                'Dropbox token refreshed successfully. Retrying original request.');
            final newHeaders = Map<String, dynamic>.from(e.requestOptions.headers);
            newHeaders['Authorization'] = 'Bearer ${_token!.accessToken}';
            final response = await _dio.request(
              e.requestOptions.path,
              options: Options(
                  method: e.requestOptions.method,
                  headers: newHeaders,
                  extra: {'dropbox_refresh_retry': retryCount + 1}),
              data: e.requestOptions.data,
              queryParameters: e.requestOptions.queryParameters,
            );
            return handler.resolve(response);
          } catch (refreshError) {
            debugPrint('Failed to refresh Dropbox token. Logging out.');
            await logout();
            return handler.reject(e);
          }
        }
        return handler.next(e);
      },
    ));
  }

  /// Throws an exception if the user is not authenticated.
  void _checkAuth() {
    if (!_isAuthenticated || _token == null) {
      throw Exception(
          'DropboxProvider: Not authenticated. Call connect() first.');
    }
  }

  /// Uses the refresh token to get a new access token.
  Future<void> _refreshToken() async {
    if (_token?.refreshToken == null) {
      throw Exception('No Dropbox refresh token available.');
    }
    debugPrint('Executing Dropbox token refresh request.');
    final dioForToken = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      sendTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
    ));
    final body = {
      'grant_type': 'refresh_token',
      'refresh_token': _token!.refreshToken,
      'client_id': _appKey,
    };
    if (_appSecret.isNotEmpty) {
      body['client_secret'] = _appSecret;
    }
    final response = await dioForToken.post(
      'https://api.dropboxapi.com/oauth2/token',
      data: body,
      options: Options(contentType: 'application/x-www-form-urlencoded'),
    );
    final newPartialToken = DropboxToken.fromJson(response.data);
    // Create a new token, preserving the original refresh token.
    _token = DropboxToken(
      accessToken: newPartialToken.accessToken,
      tokenType: newPartialToken.tokenType,
      expiresIn: newPartialToken.expiresIn,
      refreshToken: _token!.refreshToken,
    );
    debugPrint('New Dropbox access token obtained.');
  }

  /// Fetches the current user's account info.
  Future<void> _fetchCurrentUserAccount() async {
    if (_token == null) {
      throw Exception('Cannot fetch user account without a token.');
    }
    debugPrint('Fetching current Dropbox user account.');
    final response = await _dio
        .post('https://api.dropboxapi.com/2/users/get_current_account');
    _account = DropboxAccount.fromJson(response.data);
    debugPrint('Successfully fetched user: ${_account?.email}');
  }

  /// Manages the interactive OAuth2 flow using a web view and app links.
  Future<String?> _getAuthCodeViaInteractiveFlow() async {
    final authUrl = _getAuthorizationUrl();
    final callbackScheme = _redirectUri.split('://')[0];
    debugPrint('Launching Dropbox authorization URL: $authUrl');
    try {
      // 🎯 传入 FlutterWebAuth2Options 解决 Android AuthTabIntent 兼容性问题：
      // 1. preferEphemeral: true → 触发 shouldUseAuthTabs() 的浏览器版本检查，
      //    在不支持 AuthTabIntent 的浏览器上自动回退到 CustomTabsIntent
      // 2. customTabsPackageOrder → 优先使用 Chrome，避免 Edge AuthTabIntent 问题
      //    （与 OneDrive provider 保持一致的做法）
      // 参考：https://github.com/ThexXTURBOXx/flutter_web_auth_2/issues/158
      final options = FlutterWebAuth2Options(
        preferEphemeral: true,
        customTabsPackageOrder: Platform.isAndroid
            ? ['com.android.chrome']
            : null,
      );
      // 添加超时保护：AuthTabIntent 在部分设备上无法正确拦截自定义 scheme 回调，
      // 导致 FlutterWebAuth2.authenticate() 的 Future 永远不会 resolve。
      // 超时后由 _cleanUpDanglingCalls 机制清理挂起的回调。
      final result = await FlutterWebAuth2.authenticate(
        url: authUrl,
        callbackUrlScheme: callbackScheme,
        options: options,
      ).timeout(
        const Duration(minutes: 2),
        onTimeout: () {
          debugPrint('Dropbox interactive auth timed out after 2 minutes.');
          throw TimeoutException('OAuth authentication timed out');
        },
      );
      final code = Uri.parse(result).queryParameters['code'];
      if (code != null) {
        debugPrint('Received authorization code from redirect.');
        return code;
      } else {
        final error = Uri.parse(result).queryParameters['error_description'] ?? 'Unknown error';
        debugPrint('Dropbox auth failed from redirect: $error');
        return null;
      }
    } catch (e) {
      debugPrint('Dropbox interactive auth error: $e');
      return null;
    }
  }

  /// Exchanges the authorization code for an access token.
  Future<void> _completeConnection(String code) async {
    if (_pkceCodeVerifier == null) {
      throw Exception('PKCE code verifier is missing.');
    }
    debugPrint('Exchanging authorization code for a token.');
    // 添加超时配置，防止 token 交换请求无限挂起
    final dioForToken = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      sendTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
    ));
    final response = await dioForToken.post(
      'https://api.dropboxapi.com/oauth2/token',
      data: {
        'grant_type': 'authorization_code',
        'code': code,
        'client_id': _appKey,
        if (_appSecret.isNotEmpty) 'client_secret': _appSecret,
        'redirect_uri': _redirectUri,
        'code_verifier': _pkceCodeVerifier,
      },
      options: Options(contentType: 'application/x-www-form-urlencoded'),
    );
    _token = DropboxToken.fromJson(response.data);
    _isAuthenticated = true;
    _pkceCodeVerifier = null; // Verifier is single-use.
    await _fetchCurrentUserAccount();
  }

  /// Saves the token securely to the device's storage.
  Future<void> _saveToken(DropboxToken? token) async {
    if (token == null) return _clearToken();
    final key = _storageKeyPrefix != null
        ? '${_storageKeyPrefix}token'
        : _kDropboxTokenKey;
    final tokenJson = jsonEncode(token.toJson());
    await _secureStorage.write(key: key, value: tokenJson);
    debugPrint('Dropbox token saved to secure storage.');
  }

  Future<DropboxToken?> _getToken() async {
    final key = _storageKeyPrefix != null
        ? '${_storageKeyPrefix}token'
        : _kDropboxTokenKey;
    final tokenJson = await _secureStorage.read(key: key);
    if (tokenJson == null) {
      debugPrint('No Dropbox token found in secure storage.');
      return null;
    }
    try {
      debugPrint('Found and decoded Dropbox token from secure storage.');
      return DropboxToken.fromJson(jsonDecode(tokenJson));
    } catch (e) {
      debugPrint('Error decoding stored Dropbox token, clearing it.');
      await _clearToken();
      return null;
    }
  }

  Future<void> _clearToken() async {
    final key = _storageKeyPrefix != null
        ? '${_storageKeyPrefix}token'
        : _kDropboxTokenKey;
    await _secureStorage.delete(key: key);
    debugPrint('Cleared Dropbox token from secure storage.');
  }

  /// Normalizes a path for the Dropbox API (must start with '/').
  String _normalizePath(String path) {
    if (path.isEmpty || path == '/') {
      return ''; // Root is an empty string for Dropbox API.
    }
    return p.url.normalize(path.startsWith('/') ? path : '/$path');
  }

  /// Maps a Dropbox API file/folder entry to a generic [CloudFile].
  CloudFile _mapToCloudFile(Map<String, dynamic> data) {
    final isDir = data['.tag'] == 'folder';
    return CloudFile(
      path: data['path_display'],
      name: data['name'],
      size: isDir ? null : data['size'],
      modifiedTime:
          isDir ? null : DateTime.tryParse(data['server_modified'] ?? ''),
      isDirectory: isDir,
      metadata: {'id': data['id'], if (!isDir) 'rev': data['rev']},
      id: data['id'],
      mimeType: null,
    );
  }

  /// Constructs the full authorization URL for the OAuth2 PKCE flow.
  String _getAuthorizationUrl() {
    _pkceCodeVerifier = _generateCodeVerifier();
    final queryParams = {
      'client_id': _appKey,
      'response_type': 'code',
      'redirect_uri': _redirectUri,
      'token_access_type': 'offline', // To get a refresh token
      'code_challenge_method': 'S256',
      'code_challenge': _generateCodeChallengeS256(_pkceCodeVerifier!),
      'scope':
          'account_info.read files.content.read files.content.write sharing.write',
    };
    return Uri.https('www.dropbox.com', '/oauth2/authorize', queryParams)
        .toString();
  }

  /// Generates a cryptographically secure random string for PKCE.
  String _generateCodeVerifier() {
    const charset =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final random = Random.secure();
    return List.generate(128, (_) => charset[random.nextInt(charset.length)])
        .join();
  }

  /// Creates a SHA-256 code challenge from a verifier for PKCE.
  String _generateCodeChallengeS256(String verifier) {
    return base64Url
        .encode(sha256.convert(utf8.encode(verifier)).bytes)
        .replaceAll('=', ''); // base64url encoding must not have padding.
  }
}

/// Represents an OAuth2 token for the Dropbox API.
class DropboxToken {
  /// The access token for making API calls.
  final String accessToken;

  /// The type of token (e.g., 'bearer').
  final String tokenType;

  /// The token used to obtain a new access token.
  final String? refreshToken;

  /// The timestamp when the access token expires.
  final DateTime expiresIn;

  DropboxToken({
    required this.accessToken,
    this.refreshToken,
    required this.tokenType,
    required this.expiresIn,
  });

  /// Creates a [DropboxToken] from a JSON map.
  factory DropboxToken.fromJson(Map<String, dynamic> json) {
    final dynamic expiresInValue = json['expires_in'];
    DateTime expires;
    // Handles both integer (seconds) and ISO 8601 string formats for expiration.
    if (expiresInValue is int) {
      expires = DateTime.now().add(Duration(seconds: expiresInValue));
    } else if (expiresInValue is String) {
      expires = DateTime.parse(expiresInValue);
    } else {
      throw Exception("Invalid 'expires_in' format");
    }
    return DropboxToken(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String?,
      tokenType: json['token_type'] as String,
      expiresIn: expires,
    );
  }

  /// Converts the [DropboxToken] to a JSON map for storage.
  Map<String, dynamic> toJson() => {
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'token_type': tokenType,
        'expires_in': expiresIn.toIso8601String(),
      };

  /// Checks if the token is expired or close to expiring.
  bool get isExpired =>
      DateTime.now().isAfter(expiresIn.subtract(const Duration(minutes: 5)));
}

/// Represents a Dropbox user's account information.
class DropboxAccount {
  /// The user's unique Dropbox account ID.
  final String accountId;

  /// The user's display name.
  final String displayName;

  /// The user's email address.
  final String email;

  DropboxAccount({
    required this.accountId,
    required this.displayName,
    required this.email,
  });

  /// Creates a [DropboxAccount] from a JSON map.
  factory DropboxAccount.fromJson(Map<String, dynamic> json) {
    return DropboxAccount(
      accountId: json['account_id'] as String,
      email: json['email'] as String,
      displayName:
          (json['name'] as Map<String, dynamic>)['display_name'] as String,
    );
  }
}
