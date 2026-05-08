import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;
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
  final _secureStorage = const FlutterSecureStorage();
  String? _storageKeyPrefix;

  OneDriveProvider._({
    required this.clientId,
    required this.redirectUri,
  }) {
    _initializeDio();
  }

  static Future<OneDriveProvider?> connect({
    required String clientId,
    required String redirectUri,
    String? scopes,
    String? storageKeyPrefix,
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
  }) async {
    try {
      final provider = OneDriveProvider._(
        clientId: clientId,
        redirectUri: redirectUri,
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
      if (provider._tokenExpiry != null && provider._tokenExpiry!.isBefore(DateTime.now())) {
        if (provider._refreshToken != null) {
          try {
            await provider._refreshAccessToken();
          } catch (e) {
            debugPrint('OneDrive loadFromStorage: token refresh failed: $e');
            return null;
          }
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
    final authUrl = Uri.https('login.microsoftonline.com', 'common/oauth2/v2.0/authorize', {
      'client_id': clientId,
      'redirect_uri': redirectUri,
      'response_type': 'code',
      'scope': scopes,
      'prompt': 'select_account',
      'response_mode': 'query',
    });
    final callbackScheme = redirectUri.split('://')[0];
    FlutterWebAuth2Options options;
    if (callbackScheme == 'https' || callbackScheme == 'http') {
      final redirectUriParsed = Uri.parse(redirectUri);
      options = FlutterWebAuth2Options(
        httpsHost: redirectUriParsed.host,
        httpsPath: redirectUriParsed.path.isEmpty ? '/' : redirectUriParsed.path,
      );
    } else {
      options = const FlutterWebAuth2Options();
    }
    final result = await FlutterWebAuth2.authenticate(
      url: authUrl.toString(),
      callbackUrlScheme: callbackScheme,
      options: options,
    );
    final code = Uri.parse(result).queryParameters['code'];
    if (code == null) {
      throw Exception('Authorization code not found');
    }
    await _exchangeCodeForToken(code, scopes);
  }

  Future<void> _exchangeCodeForToken(String code, String scopes) async {
    final response = await http.post(
      Uri.parse('https://login.microsoftonline.com/common/oauth2/v2.0/token'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'client_id': clientId,
        'redirect_uri': redirectUri,
        'grant_type': 'authorization_code',
        'code': code,
        'scope': scopes,
      },
    );
    if (response.statusCode != 200) {
      throw Exception('Token exchange failed: ${response.body}');
    }
    final json = jsonDecode(response.body);
    _accessToken = json['access_token'] as String;
    _refreshToken = json['refresh_token'] as String?;
    _tokenExpiry = DateTime.now().add(Duration(seconds: json['expires_in'] as int));
    await _saveTokens();
  }

  Future<void> _refreshAccessToken() async {
    if (_refreshToken == null) {
      throw Exception('No refresh token available');
    }
    final response = await http.post(
      Uri.parse('https://login.microsoftonline.com/common/oauth2/v2.0/token'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'client_id': clientId,
        'redirect_uri': redirectUri,
        'grant_type': 'refresh_token',
        'refresh_token': _refreshToken,
      },
    );
    if (response.statusCode != 200) {
      throw Exception('Token refresh failed: ${response.body}');
    }
    final json = jsonDecode(response.body);
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
          debugPrint('OneDrive token expired (401). Attempting to refresh token.');
          try {
            await _refreshAccessToken();
            debugPrint('OneDrive token refreshed successfully. Retrying original request.');
            final response = await _dio.request(
              e.requestOptions.path,
              options: Options(
                method: e.requestOptions.method,
                headers: e.requestOptions.headers,
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
        final url = 'https://graph.microsoft.com/v1.0/me/drive/root:/$encodedPath/children?\$select=id,name,size,lastModifiedDateTime,folder,file,mimeType';
        final response = await _dio.get(
          url,
        );
        final List<dynamic> items = response.data['value'];
        final cloudFiles = items.map((item) => _mapToCloudFile(item)).toList();
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

  @override
  Future<String> uploadFile({
    required String localPath,
    required String remotePath,
    Map<String, dynamic>? metadata,
  }) {
    return _executeRequest(
      () async {
        final file = File(localPath);
        final bytes = await file.readAsBytes();
        final encodedPath = _encodePath(remotePath);
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
            '@microsoft.graph.conflictBehavior': 'fail',
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
        _tokenExpiry != null && _tokenExpiry!.isBefore(DateTime.now())) {
      if (_refreshToken != null) {
        await _refreshAccessToken();
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
  Future<bool> tokenExpired() async {
    if (!_isAuthenticated) return true;
    if (_tokenExpiry != null && _tokenExpiry!.isBefore(DateTime.now())) {
      return true;
    }
    try {
      await _dio.get(
        'https://graph.microsoft.com/v1.0/me/drive/root/children?\$select=id&\$top=1',
      );
      return false;
    } catch (e) {
      return true;
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
  }) async {
    final downloadUrl = Uri.parse(shareToken).replace(queryParameters: {'download': '1'});
    await _dio.download(
      downloadUrl.toString(),
      localPath,
    );
    return localPath;
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
    final base64UrlString = base64Url.encode(utf8.encode(url));
    return 'u!$base64UrlString';
  }

  String _encodePath(String path) {
    final cleanPath = path.startsWith('/') ? path.substring(1) : path;
    if (cleanPath.isEmpty) return '';
    return cleanPath.split('/').map(Uri.encodeComponent).join('/');
  }
}

class _ResolvedShareInfo {
  final String driveId;
  final String itemId;

  _ResolvedShareInfo({required this.driveId, required this.itemId});
}