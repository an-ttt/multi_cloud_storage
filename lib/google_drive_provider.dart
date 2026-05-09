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
import 'package:http/http.dart' as http;
import 'package:http/retry.dart';
import 'package:multi_cloud_storage/exceptions/no_connection_exception.dart';
import 'package:path/path.dart';
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
  static List<String> scopes = [
    MultiCloudStorage.cloudAccess == CloudAccessType.appStorage
        ? drive.DriveApi.driveAppdataScope
        : drive.DriveApi.driveScope,
  ];

  GoogleDriveProvider.internal();

  static Future<GoogleDriveProvider?> connect({
    bool forceInteractive = false,
    List<String>? scopes,
    String? serverClientId,
    String? clientSecret,
    int redirectPort = 8000,
  }) async {
    debugPrint("connect Google Drive,  forceInteractive: $forceInteractive");
    if (scopes != null) {
      GoogleDriveProvider.scopes = scopes;
    }
    try {
      if (!_initialized) {
        await GoogleSignIn.instance.initialize(serverClientId: serverClientId);
        _initialized = true;
      }
      GoogleSignInAccount? account;
      if (!forceInteractive) {
        final lightweightResult =
            GoogleSignIn.instance.attemptLightweightAuthentication();
        if (lightweightResult != null) {
          account = await lightweightResult;
        }
      }
      if (account == null) {
        try {
          account = await GoogleSignIn.instance
              .authenticate(scopeHint: GoogleDriveProvider.scopes);
        } on GoogleSignInException catch (e) {
          if (e.code == GoogleSignInExceptionCode.canceled) {
            debugPrint('User cancelled Google Sign-In process.');
            return null;
          }
          rethrow;
        }
      }
      final authorization = await account.authorizationClient
          .authorizeScopes(GoogleDriveProvider.scopes);
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
      return null;
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
            String currentItemPath = join(path, file.name ?? '');
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
        final fileName = basename(remotePath);
        final remoteDir = dirname(remotePath) == '.' ? '' : dirname(remotePath);
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
      // driveApi 不支持 Range 头，需手动构造 HTTP 请求
      final uri = Uri.parse(
          'https://www.googleapis.com/drive/v3/files/${file.id}?alt=media');
      final request = http.Request('GET', uri);
      request.headers['Range'] = 'bytes=$offset-${offset + length - 1}';
      final response = await _authClient!.send(request);
      final bytes = await response.stream.fold<BytesBuilder>(
          BytesBuilder(), (b, d) => b..add(d));
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
    final regex = RegExp(r'd/([a-zA-Z0-9_-]+)');
    final match = regex.firstMatch(shareLink.toString());
    return match?.group(1);
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
      } finally {
        await sink.close();
      }
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

  Future<T> _executeRequest<T>(Future<T> Function() request, {int authRetryCount = 0}) async {
    _checkAuth();
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

  Future<T> handleAuthErrorAndRetry<T>(
      Future<T> Function() request, Object error, StackTrace stackTrace, {int authRetryCount = 0}) async {
    if (authRetryCount >= 1) {
      debugPrint('Auth retry limit reached. Throwing original error.');
      throw error;
    }
    debugPrint('Authentication error occurred. Attempting to reconnect...');
    isAuthenticated = false;
    try {
      if (_currentAccount != null) {
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
      }
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
    final parts = split(folderPath
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
    final parts = split(normalizedPath);
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
    final parts = split(normalizedPath);
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

  String _sanitizeQueryString(String value) => value.replaceAll('\\', '\\\\').replaceAll("'", "\\'");

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
