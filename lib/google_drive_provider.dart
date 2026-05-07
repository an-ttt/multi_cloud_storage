import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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
  /// The authenticated Google Drive API client.
  late drive.DriveApi driveApi;
  bool isAuthenticated = false;

  // Singleton instance backing fields.
  static GoogleSignInAccount? currentAccount;
  static GoogleSignInClientAuthorization? currentAuthorization;
  static AuthClient? _authClient;
  static GoogleDriveProvider? _instance;
  static bool _initialized = false;
  static List<String> scopes = [
    MultiCloudStorage.cloudAccess == CloudAccessType.appStorage
        ? drive.DriveApi.driveAppdataScope
        : drive.DriveApi.driveScope,
  ];

  GoogleDriveProvider.internal();

  static GoogleDriveProvider? get instance => _instance;

  /// Connects to Google Drive, authenticating the user.
  ///
  /// This method handles the Google Sign-In flow. It will attempt to sign in
  /// silently first, unless [forceInteractive] is true.
  ///
  /// [scopes] a list of additional Google API scopes to request.
  /// The default scopes are `drive.DriveApi.driveAppdataScope` or
  /// `drive.DriveApi.driveScope` depending on `MultiCloudStorage.cloudAccess`.
  /// [serverClientId] The server client ID for requesting an ID token if you
  /// need to authenticate to a backend server.
  ///
  /// Returns a connected [GoogleDriveProvider] instance on success, or null on failure/cancellation.
  static Future<GoogleDriveProvider?> connect({
    bool forceInteractive = false,
    List<String>? scopes,
    String? serverClientId,
    String? clientSecret, // Secret is needed for the web app flow on desktop
     int redirectPort = 8000, // Default port used by the package
  }) async {
    debugPrint("connect Google Drive,  forceInteractive: $forceInteractive");
    // Return existing instance if already connected and not forcing a new interactive session.
    if (_instance != null && _instance!.isAuthenticated && !forceInteractive) {
      return _instance;
    }
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
      currentAccount = account;
      final authorization = await account.authorizationClient
          .authorizeScopes(GoogleDriveProvider.scopes);
      currentAuthorization = authorization;
      final client =
          authorization.authClient(scopes: GoogleDriveProvider.scopes);
      _authClient = client;
      final retryClient = RetryClient(
        client,
        retries: 3,
        when: (response) => {500, 502, 503, 504}.contains(response.statusCode),
        onRetry: (request, response, retryCount) => debugPrint(
            'Retrying request to ${request.url} (Retry #$retryCount)'),
      );
      final provider = _instance ?? GoogleDriveProvider.internal();
      provider.driveApi = drive.DriveApi(retryClient);
      provider.isAuthenticated = true;
      _instance = provider;
      debugPrint(
          'Google Drive user signed in: ID=${account.id}, Email=${account.email}');
      return _instance;
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
      await signOut(); // Clean up on error.
      return null;
    }
  }

  static Future<GoogleDriveProvider?> connectWithToken({
    required String accessToken,
    String? refreshToken,
    String? clientId,
    String? clientSecret,
  }) async {
    debugPrint('connectWithToken Google Drive');
    try {
      final httpClient = _ManualTokenHttpClient(
        accessToken: accessToken,
        refreshToken: refreshToken,
        clientId: clientId,
        clientSecret: clientSecret,
      );
      final retryClient = RetryClient(
        httpClient,
        retries: 3,
        when: (response) => {500, 502, 503, 504}.contains(response.statusCode),
        onRetry: (request, response, retryCount) => debugPrint(
            'Retrying request to ${request.url} (Retry #$retryCount)'),
      );
      final provider = GoogleDriveProvider.internal();
      provider.driveApi = drive.DriveApi(retryClient);
      provider.isAuthenticated = true;
      debugPrint('Google Drive connectWithToken successful');
      return provider;
    } catch (error) {
      debugPrint('Error occurred during Google Drive connectWithToken: $error');
      return null;
    }
  }

  /// Uploads a file from a [localPath] to a [remotePath] in the cloud.
  @override
  Future<List<CloudFile>> listFiles(
      {String path = '', bool recursive = false}) {
    return _executeRequest(() async {
      final folder = await _getFolderByPath(path);
      if (folder == null || folder.id == null) {
        return []; // Return empty list if path does not exist.
      }
      final List<CloudFile> cloudFiles = [];
      String? pageToken;
      // Loop to handle paginated results from the Drive API.
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
            // Convert Google Drive file object to a generic CloudFile.
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
      // If recursive is true, fetch files from all subdirectories.
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

  /// Downloads a file from a [remotePath] to a [localPath] on the device.
  @override
  Future<String> downloadFile({
    required String remotePath,
    required String localPath,
  }) {
    return _executeRequest(() async {
      // Find the file by its path to get its ID.
      final file = await _getFileByPath(remotePath);
      if (file == null || file.id == null) {
        throw Exception('GoogleDriveProvider: File not found at $remotePath');
      }
      final output = File(localPath);
      final sink = output.openWrite();
      try {
        // Download the file content by its ID.
        final media = await driveApi.files.get(file.id!,
            downloadOptions: drive.DownloadOptions.fullMedia) as drive.Media;
        // Stream the content to the local file.
        await media.stream.pipe(sink);
      } catch (e) {
        await sink.close(); // Ensure sink is closed on error.
        if (await output.exists()) {
          await output.delete(); // Clean up partial file on failure.
        }
        rethrow;
      }
      await sink.close();
      return localPath;
    });
  }

  /// Uploads a file from a [localPath] to a [remotePath].
  @override
  Future<String> uploadFile({
    required String localPath,
    required String remotePath,
    Map<String, dynamic>? metadata,
  }) {
    return _executeRequest(() async {
      // Check if a file already exists at the remote path.
      final existingFile = await _getFileByPath(remotePath);
      if (existingFile != null && existingFile.id != null) {
        // If it exists, update it using its file ID.
        return uploadFileByShareToken(
          localPath: localPath,
          shareToken: existingFile.id!,
          metadata: metadata,
        );
      } else {
        // If it doesn't exist, create it.
        final file = File(localPath);
        final fileName = basename(remotePath);
        final remoteDir = dirname(remotePath) == '.' ? '' : dirname(remotePath);
        // Ensure the parent directory exists.
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

  /// Deletes the file or directory at the specified [path].
  @override
  Future<void> deleteFile(String path) {
    return _executeRequest(() async {
      final file = await _getFileByPath(path);
      if (file != null && file.id != null) {
        await driveApi.files.delete(file.id!);
      }
    });
  }

  /// Creates a new directory at the specified [path].
  @override
  Future<void> createDirectory(String path) {
    return _executeRequest(() async {
      // This helper finds the folder and creates it if it doesn't exist.
      await _getOrCreateFolder(path);
    });
  }

  /// Retrieves metadata for the file or directory at the specified [path].
  @override
  Future<CloudFile> getFileMetadata(String path) {
    return _executeRequest(() async {
      final file = await _getFileByPath(path);
      if (file == null) {
        throw Exception('GoogleDriveProvider: File not found at $path');
      }
      // Convert the Google Drive file object to a generic CloudFile.
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
    return currentAccount?.displayName;
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
      final client = _authClient;
      if (client == null) throw Exception('Not authenticated');
      final uri = Uri.parse(
          'https://www.googleapis.com/drive/v3/files/${file.id}?alt=media');
      final request = http.Request('GET', uri);
      request.headers['Range'] = 'bytes=$offset-${offset + length - 1}';
      final response = await client.send(request);
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
  Future<String?> loggedInUserEmail() async => currentAccount?.email;

  @override
  Future<String?> loggedInUserId() async => currentAccount?.id;

  /// Checks if the current user's authentication token is expired.
  @override
  Future<bool> tokenExpired() {
    return _executeRequest(() async {
      // Make a lightweight API call to check token validity.
      // If it succeeds, the token is valid. A 401/403 error is caught by
      // _executeRequest, which then tries to re-authenticate.
      await driveApi.about.get($fields: 'user');
      return false;
    })
        .then((_) =>
            false) // If the request (and potential retry) succeeds, token is not expired.
        .catchError((_) =>
            true); // If it ultimately fails, token is considered expired.
  }

  /// Logs out the current user from the cloud service.
  @override
  Future<bool> logout() async {
    if (isAuthenticated) {
      try {
        await signOut();
        isAuthenticated = false; // This is redundant due to signOut but safe.
        return true;
      } catch (e) {
        return false;
      }
    }
    return false; // Already logged out.
  }

  /// Generates a shareable link for the file or directory at the [path].
  @override
  Future<Uri?> generateShareLink(String path) {
    return _executeRequest(() async {
      final drive.File? file = await _getFileByPath(path);
      if (file == null || file.id == null) {
        return null;
      }
      // Create a permission to make the file accessible to anyone with the link.
      final permission = drive.Permission()
        ..type = 'anyone'
        ..role = 'writer'; // or 'reader'
      await driveApi.permissions.create(permission, file.id!, $fields: 'id');
      // Retrieve the file metadata again to get the shareable link.
      final fileMetadata = await driveApi.files
          .get(file.id!, $fields: 'id, name, webViewLink') as drive.File;
      if (fileMetadata.webViewLink == null) {
        return null;
      }
      return Uri.parse(fileMetadata.webViewLink!);
    });
  }

  /// Extracts a share token from a given [shareLink].
  @override
  Future<String?> getShareTokenFromShareLink(Uri shareLink) async {
    // Extracts the file ID from a standard Google Drive URL format.
    // e.g., .../d/FILE_ID/edit
    final regex = RegExp(r'd/([a-zA-Z0-9_-]+)');
    final match = regex.firstMatch(shareLink.toString());
    return match?.group(1);
  }

  /// Downloads a file to [localPath] using a [shareToken].
  @override
  Future<String> downloadFileByShareToken(
      {required String shareToken, required String localPath}) {
    return _executeRequest(() async {
      final output = File(localPath);
      final sink = output.openWrite();
      try {
        // Download the file directly using its ID (shareToken).
        final media = await driveApi.files.get(shareToken,
            downloadOptions: drive.DownloadOptions.fullMedia) as drive.Media;
        await media.stream.pipe(sink);
      } finally {
        await sink.close();
      }
      return localPath;
    });
  }

  /// Uploads a file from [localPath] using a [shareToken].
  @override
  Future<String> uploadFileByShareToken({
    required String localPath,
    required String shareToken,
    Map<String, dynamic>? metadata,
  }) {
    return _executeRequest(() async {
      final file = File(localPath);
      final driveFile = drive.File(); // Empty file metadata for update
      final media = drive.Media(file.openRead(), await file.length());
      // Use the 'update' method with the file ID (shareToken) to overwrite content.
      final updatedFile = await driveApi.files
          .update(driveFile, shareToken, uploadMedia: media, $fields: 'id');
      return updatedFile.id!;
    });
  }

  /// Signs the user out of Google and disconnects the app.
  static Future<void> signOut() async {
    try {
      await GoogleSignIn.instance.disconnect();
      await GoogleSignIn.instance.signOut();
    } catch (error) {
      debugPrint('Failed to sign out or disconnect from Google. $error');
    } finally {
      _authClient?.close();
      _authClient = null;
      currentAccount = null;
      currentAuthorization = null;
      if (_instance != null) {
        _instance!.isAuthenticated = false;
        _instance = null;
      }
      debugPrint('User signed out from Google Drive.');
    }
  }

  /// A wrapper for all API requests to centralize authentication checks and error handling.
  ///
  /// Executes the given `request` function. If an authentication error (401/403)
  /// occurs, it triggers the automatic reconnection and retry logic.
  Future<T> _executeRequest<T>(Future<T> Function() request) async {
    _checkAuth();
    try {
      return await request();
    } on drive.DetailedApiRequestError catch (e, stackTrace) {
      // If the error is an auth token issue, try to recover.
      if (e.status == 401 || e.status == 403) {
        return handleAuthErrorAndRetry(request, e, stackTrace);
      } else if (e.status == 404) {
        throw NotFoundException(e.message ?? '');
      } else {
        // For other API errors, rethrow them.
        rethrow;
      }
    } on AccessDeniedException catch (e, stackTrace) {
      // Also handle auth errors from the underlying auth library.
      return handleAuthErrorAndRetry(request, e, stackTrace);
    } on SocketException catch (e) {
      debugPrint('No connection detected.');
      throw NoConnectionException(e.message);
    } on Exception catch (e) {
      // Catch any other generic exception that matches the message
      if (e.toString().contains('File not found')) {
        throw NotFoundException(e.toString());
      }
      rethrow;
    }
  }

  /// Throws an exception if the provider is not authenticated.
  void _checkAuth() {
    if (!isAuthenticated || _instance == null) {
      throw Exception(
          'GoogleDriveProvider: Not authenticated. Call connect() first.');
    }
  }

  /// A helper to handle auth errors by reconnecting and retrying the request.
  ///
  /// This is called when a 401/403 error occurs, indicating an expired token.
  /// It attempts a silent reconnect to refresh the token and then retries the
  /// original function `request`.
  Future<T> handleAuthErrorAndRetry<T>(
      Future<T> Function() request, Object error, StackTrace stackTrace) async {
    debugPrint('Authentication error occurred. Attempting to reconnect...');
    isAuthenticated = false;
    // Silently try to reconnect to refresh the auth token.
    final reconnectedProvider = await GoogleDriveProvider.connect();
    if (reconnectedProvider != null && reconnectedProvider.isAuthenticated) {
      debugPrint('Successfully reconnected. Retrying the original request.');
      // Retry the original request closure.
      return await request();
    } else {
      debugPrint(
          'Failed to reconnect after auth error. Throwing original error.');
      // If reconnection fails, rethrow the original error to the caller.
      throw error;
    }
  }

  /// Gets the root folder ID ('appDataFolder' or 'root') based on the access type.
  Future<String> _getRootFolderId() async {
    return MultiCloudStorage.cloudAccess == CloudAccessType.appStorage
        ? 'appDataFolder'
        : 'root';
  }

  /// Finds a folder by its full path, returning null if not found.
  Future<drive.File?> _getFolderByPath(String folderPath) async {
    if (folderPath.isEmpty || folderPath == '.' || folderPath == '/') {
      return _getRootFolder();
    }
    // Normalize path and split into components.
    final parts = split(folderPath
        .replaceAll(RegExp(r'^/+'), '')
        .replaceAll(RegExp(r'/+$'), ''));
    if (parts.isEmpty || (parts.length == 1 && parts[0].isEmpty)) {
      return _getRootFolder();
    }
    drive.File currentFolder = await _getRootFolder();
    // Traverse the path segment by segment.
    for (final part in parts) {
      if (part.isEmpty) continue;
      final folder = await _getFolderByName(currentFolder.id!, part);
      if (folder == null) return null; // Path does not exist.
      currentFolder = folder;
    }
    return currentFolder;
  }

  /// Finds a file or folder by its full path, returning null if not found.
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
    // Traverse the directory parts of the path.
    for (var i = 0; i < parts.length - 1; i++) {
      final folderName = parts[i];
      if (folderName.isEmpty) continue;
      final folder = await _getFolderByName(currentFolder.id!, folderName);
      if (folder == null) {
        return null; // Parent path does not exist.
      }
      currentFolder = folder;
    }
    final fileName = parts.last;
    if (fileName.isEmpty) return currentFolder; // Path was a directory.
    // Search for the file in the final parent directory.
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

  /// Gets a folder by its path, creating it and any missing parent directories if necessary.
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
    // Traverse the path, creating folders as needed.
    for (final part in parts) {
      if (part.isEmpty) continue;
      var folder = await _getFolderByName(currentFolder.id!, part);
      folder ??= await _createFolder(currentFolder.id!, part);
      currentFolder = folder;
    }
    return currentFolder;
  }

  /// Returns a `drive.File` object representing the root folder.
  Future<drive.File> _getRootFolder() async {
    return drive.File()..id = await _getRootFolderId();
  }

  /// Finds a folder by name within a specific parent folder.
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

  /// Creates a new folder with the given name inside a parent folder.
  Future<drive.File> _createFolder(String parentId, String name) async {
    final folder = drive.File()
      ..name = name
      ..mimeType = 'application/vnd.google-apps.folder'
      ..parents = [parentId];
    return await driveApi.files
        .create(folder, $fields: 'id, name, mimeType, parents');
  }

  /// Escapes single quotes in a string for use in a Drive API query.
  String _sanitizeQueryString(String value) => value.replaceAll("'", "\\'");

  @override
  Future<String?> getAccessToken() async {
    if (currentAuthorization != null) {
      return currentAuthorization!.accessToken;
    }
    return null;
  }
}

class _ManualTokenHttpClient extends http.BaseClient {
  _ManualTokenHttpClient({
    required this.accessToken,
    this.refreshToken,
    this.clientId,
    this.clientSecret,
  });

  String accessToken;
  final String? refreshToken;
  final String? clientId;
  final String? clientSecret;
  final http.Client _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    request.headers['Authorization'] = 'Bearer $accessToken';
    return _inner.send(request);
  }

  @override
  void close() {
    _inner.close();
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