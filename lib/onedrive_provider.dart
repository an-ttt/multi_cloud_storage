import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
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

  OneDriveProvider._({
    required this.clientId,
    required this.redirectUri,
  }) {
    _dio = Dio();
  }

  static Future<OneDriveProvider?> connect({
    required String clientId,
    required String redirectUri,
    String? scopes,
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

  Future<void> _authenticate(String scopes) async {
    final prefs = await SharedPreferences.getInstance();
    _accessToken = prefs.getString('onedrive_access_token');
    _refreshToken = prefs.getString('onedrive_refresh_token');
    final expiryString = prefs.getString('onedrive_token_expiry');
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
    final result = await FlutterWebAuth2.authenticate(
      url: authUrl.toString(),
      callbackUrlScheme: redirectUri.split('://')[0],
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

  Future<void> _saveTokens() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('onedrive_access_token', _accessToken ?? '');
    if (_refreshToken != null) {
      await prefs.setString('onedrive_refresh_token', _refreshToken!);
    }
    if (_tokenExpiry != null) {
      await prefs.setString('onedrive_token_expiry', _tokenExpiry!.toIso8601String());
    }
  }

  Future<void> _clearTokens() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('onedrive_access_token');
    await prefs.remove('onedrive_refresh_token');
    await prefs.remove('onedrive_token_expiry');
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
        final encodedPath = Uri.encodeComponent(effectivePath.startsWith('/') ? effectivePath.substring(1) : effectivePath);
        String url;
        if (recursive) {
          url = 'https://graph.microsoft.com/v1.0/me/drive/root:/$encodedPath/children?\$select=id,name,size,lastModifiedDateTime,folder,file,mimeType&\$expand=children';
        } else {
          url = 'https://graph.microsoft.com/v1.0/me/drive/root:/$encodedPath/children?\$select=id,name,size,lastModifiedDateTime,folder,file,mimeType';
        }
        final response = await _dio.get(
          url,
          options: Options(headers: {'Authorization': 'Bearer $_accessToken'}),
        );
        final List<dynamic> items = response.data['value'];
        return items.map((item) => _mapToCloudFile(item)).toList();
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
        final encodedPath = Uri.encodeComponent(remotePath.startsWith('/') ? remotePath.substring(1) : remotePath);
        final url = 'https://graph.microsoft.com/v1.0/me/drive/root:/$encodedPath:/content';
        await _dio.download(
          url,
          localPath,
          options: Options(headers: {'Authorization': 'Bearer $_accessToken'}),
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
        final encodedPath = Uri.encodeComponent(remotePath.startsWith('/') ? remotePath.substring(1) : remotePath);
        final url = 'https://graph.microsoft.com/v1.0/me/drive/root:/$encodedPath:/content';
        await _dio.put(
          url,
          data: bytes,
          options: Options(
            headers: {
              'Authorization': 'Bearer $_accessToken',
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
        final encodedPath = Uri.encodeComponent(path.startsWith('/') ? path.substring(1) : path);
        final url = 'https://graph.microsoft.com/v1.0/me/drive/root:/$encodedPath';
        await _dio.delete(
          url,
          options: Options(headers: {'Authorization': 'Bearer $_accessToken'}),
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
          final encodedParentPath = Uri.encodeComponent(parentPath.startsWith('/') ? parentPath.substring(1) : parentPath);
          url = 'https://graph.microsoft.com/v1.0/me/drive/root:/$encodedParentPath/children';
        }
        await _dio.post(
          url,
          data: {
            'name': dirName,
            'folder': {},
            '@microsoft.graph.conflictBehavior': 'fail',
          },
          options: Options(headers: {'Authorization': 'Bearer $_accessToken'}),
        );
      },
      operation: 'createDirectory at $path',
    );
  }

  @override
  Future<CloudFile> getFileMetadata(String path) {
    return _executeRequest(
      () async {
        final encodedPath = Uri.encodeComponent(path.startsWith('/') ? path.substring(1) : path);
        final url = 'https://graph.microsoft.com/v1.0/me/drive/root:/$encodedPath?\$select=id,name,size,lastModifiedDateTime,folder,file,mimeType';
        final response = await _dio.get(
          url,
          options: Options(headers: {'Authorization': 'Bearer $_accessToken'}),
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
          options: Options(headers: {'Authorization': 'Bearer $_accessToken'}),
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
      final encodedPath = Uri.encodeComponent(path.startsWith('/') ? path.substring(1) : path);
      final url = 'https://graph.microsoft.com/v1.0/me/drive/root:/$encodedPath:/content';
      final response = await _dio.get(
        url,
        options: Options(
          headers: {
            'Authorization': 'Bearer $_accessToken',
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
      final encodedPath = Uri.encodeComponent(path.startsWith('/') ? path.substring(1) : path);
      final url = 'https://graph.microsoft.com/v1.0/me/drive/root:/$encodedPath?\$select=@content.downloadUrl';
      final response = await _dio.get(
        url,
        options: Options(headers: {'Authorization': 'Bearer $_accessToken'}),
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
  Future<String?> loggedInUserEmail() {
    return _executeRequest(() async {
      final response = await _dio.get(
        'https://graph.microsoft.com/v1.0/me',
        options: Options(headers: {'Authorization': 'Bearer $_accessToken'}),
      );
      return response.data['mail'] as String? ?? response.data['userPrincipalName'] as String?;
    }, operation: 'loggedInUserEmail');
  }

  @override
  Future<String?> loggedInUserId() {
    return _executeRequest(() async {
      final response = await _dio.get(
        'https://graph.microsoft.com/v1.0/me',
        options: Options(headers: {'Authorization': 'Bearer $_accessToken'}),
      );
      return response.data['id'] as String?;
    }, operation: 'loggedInUserId');
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
        options: Options(headers: {'Authorization': 'Bearer $_accessToken'}),
      );
      return false;
    } catch (e) {
      return true;
    }
  }

  @override
  Future<bool> logout() async {
    debugPrint("Logging out from OneDrive...");
    if (_isAuthenticated) {
      try {
        await _clearTokens();
        _isAuthenticated = false;
        return true;
      } catch (error) {
        debugPrint("Error during OneDrive logout: $error");
        return false;
      }
    }
    await _clearTokens();
    return false;
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
          options: Options(headers: {'Authorization': 'Bearer $_accessToken'}),
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
              'Authorization': 'Bearer $_accessToken',
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
    } catch (e) {
      debugPrint('Error during OneDrive operation: $operation: $e');
      if (e.toString().contains('401') || e.toString().contains('invalid_grant')) {
        _isAuthenticated = false;
        debugPrint('OneDrive token appears to be expired. User re-authentication is required.');
      }
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
          'Authorization': 'Bearer $_accessToken',
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
}

class _ResolvedShareInfo {
  final String driveId;
  final String itemId;

  _ResolvedShareInfo({required this.driveId, required this.itemId});
}