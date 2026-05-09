import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in_all_platforms/google_sign_in_all_platforms.dart'
    as all_platforms;
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/googleapis_auth.dart' show AccessDeniedException;
import 'package:http/http.dart' as http;
import 'package:http/http.dart' as client;
import 'package:http/retry.dart';
import 'package:multi_cloud_storage/exceptions/no_connection_exception.dart';
import 'google_drive_provider.dart';

class GoogleDriveProviderDesktop extends GoogleDriveProvider {
  all_platforms.GoogleSignIn? _googleSignIn;

  // This one is correct because it explicitly calls super.internal()
  GoogleDriveProviderDesktop.internal() : super.internal();

  String? _accessToken;
  String? _storageKeyPrefix;
  String? _manualRefreshToken;
  DateTime? _manualTokenExpiry;
  _DesktopManualTokenHttpClient? _desktopManualTokenHttpClient;
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

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
    // NEW: Client ID and Secret are required for the desktop flow.
    String? serverClientId,
    String? clientSecret, // Secret is needed for the web app flow on desktop
    int redirectPort = 8000, // Default port used by the package
  }) async {
    debugPrint("connect Google Drive,  forceInteractive: $forceInteractive");
    if (scopes != null) {
      GoogleDriveProvider.scopes = scopes;
    }
    try {
      // 1. CONFIGURE: The new package uses a parameters object for configuration.
      final signInParams = all_platforms.GoogleSignInParams(
        clientId: serverClientId,
        clientSecret: clientSecret, // May be null for other client types
        scopes: GoogleDriveProvider.scopes,
        redirectPort: redirectPort,
      );

      // 2. INITIALIZE: Create the GoogleSignIn instance with the params.
      final googleSignIn = all_platforms.GoogleSignIn(params: signInParams);

      // 3. SIGN IN: The sign-in flow is simplified.
      // signIn() attempts offline (silent) first, then falls back to online.
      // signInOnline() forces the interactive flow.
      all_platforms.GoogleSignInCredentials? credentials;
      if (forceInteractive) {
        credentials = await googleSignIn.signInOnline();
      } else {
        credentials = await googleSignIn.signIn();
      }

      if (credentials == null) {
        debugPrint('User cancelled Google Sign-In process.');
        return null;
      }

      // 4. GET CLIENT: The authenticatedClient getter is now used.
      // The separate requestScopes() call is no longer needed as scopes are
      // handled during the signIn process.
      final http.Client? client = await googleSignIn.authenticatedClient;

      if (client == null) {
        debugPrint('Failed to get authenticated Google client.');
        return null;
      }

      // Wrap the client in a RetryClient to handle transient network errors (5xx).
      final retryClient = RetryClient(
        client,
        retries: 3,
        when: (response) => {500, 502, 503, 504}.contains(response.statusCode),
        onRetry: (request, response, retryCount) => debugPrint(
            'Retrying request to ${request.url} (Retry #$retryCount)'),
      );

      // Create a new instance with the authenticated client.
      final provider = GoogleDriveProviderDesktop.internal();
      provider._googleSignIn = googleSignIn;
      provider.driveApi = drive.DriveApi(retryClient);
      provider.isAuthenticated = true;
      provider._accessToken = credentials.accessToken;
      debugPrint('Google Drive user signed in successfully.');
      return provider;
    } on SocketException catch (e) {
      debugPrint(
          'No internet connection during Google Drive sign-in: ${e.message}');
      throw NoConnectionException(e.message);
    } catch (error) {
      debugPrint(
        'Error occurred during the Google Drive connect process: $error',
      );
      if (error is PlatformException && error.code == 'network_error') {
        throw NoConnectionException(error.toString());
      }
      return null;
    }
  }

  static Future<GoogleDriveProvider?> connectWithToken({
    required String accessToken,
    String? refreshToken,
    String? clientId,
    String? clientSecret,
    int? expiresIn,
    String? storageKeyPrefix,
  }) async {
    debugPrint('connectWithToken Google Drive Desktop');
    try {
      final provider = GoogleDriveProviderDesktop.internal();
      final httpClient = _DesktopManualTokenHttpClient(
        accessToken: accessToken,
        refreshToken: refreshToken,
        clientId: clientId,
        clientSecret: clientSecret,
        onTokenRefreshed: (newToken, newExpiresIn) {
          provider._accessToken = newToken;
          if (provider._storageKeyPrefix != null) {
            _secureStorage.write(key: '${provider._storageKeyPrefix}access_token', value: newToken);
          }
          if (newExpiresIn != null) {
            provider._manualTokenExpiry = DateTime.now().add(Duration(seconds: newExpiresIn));
            if (provider._storageKeyPrefix != null) {
              _secureStorage.write(key: '${provider._storageKeyPrefix}token_expiry', value: provider._manualTokenExpiry!.toIso8601String());
            }
          }
        },
      );
      provider._desktopManualTokenHttpClient = httpClient;
      final retryClient = RetryClient(
        httpClient,
        retries: 3,
        when: (response) => {500, 502, 503, 504}.contains(response.statusCode),
        onRetry: (request, response, retryCount) => debugPrint(
            'Retrying request to ${request.url} (Retry #$retryCount)'),
      );
      provider.driveApi = drive.DriveApi(retryClient);
      provider.isAuthenticated = true;
      provider._accessToken = accessToken;
      provider._storageKeyPrefix = storageKeyPrefix;
      provider._manualRefreshToken = refreshToken;
      provider._manualTokenExpiry = expiresIn != null && expiresIn > 0
          ? DateTime.now().add(Duration(seconds: expiresIn))
          : null;
      // Persist tokens to secure storage
      if (storageKeyPrefix != null) {
        await _secureStorage.write(key: '${storageKeyPrefix}access_token', value: accessToken);
        if (refreshToken != null) {
          await _secureStorage.write(key: '${storageKeyPrefix}refresh_token', value: refreshToken);
        }
        if (provider._manualTokenExpiry != null) {
          await _secureStorage.write(key: '${storageKeyPrefix}token_expiry', value: provider._manualTokenExpiry!.toIso8601String());
        }
        if (clientId != null) {
          await _secureStorage.write(key: '${storageKeyPrefix}client_id', value: clientId);
        }
        if (clientSecret != null) {
          await _secureStorage.write(key: '${storageKeyPrefix}client_secret', value: clientSecret);
        }
      }
      debugPrint('Google Drive Desktop connectWithToken successful');
      return provider;
    } catch (error) {
      debugPrint('Error occurred during Google Drive Desktop connectWithToken: $error');
      return null;
    }
  }

  static Future<GoogleDriveProvider?> loadFromStorage({
    required String clientId,
    String? clientSecret,
    required String storageKeyPrefix,
  }) async {
    try {
      final storedAccessToken = await _secureStorage.read(key: '${storageKeyPrefix}access_token');
      final storedRefreshToken = await _secureStorage.read(key: '${storageKeyPrefix}refresh_token');
      final storedExpiry = await _secureStorage.read(key: '${storageKeyPrefix}token_expiry');
      final storedClientId = await _secureStorage.read(key: '${storageKeyPrefix}client_id') ?? clientId;
      final storedClientSecret = await _secureStorage.read(key: '${storageKeyPrefix}client_secret') ?? clientSecret;
      if (storedAccessToken == null) return null;
      int? expiresIn;
      if (storedExpiry != null) {
        final expiry = DateTime.parse(storedExpiry);
        expiresIn = expiry.difference(DateTime.now()).inSeconds;
        if (expiresIn < 0) expiresIn = null;
      }
      final provider = await connectWithToken(
        accessToken: storedAccessToken,
        refreshToken: storedRefreshToken,
        clientId: storedClientId,
        clientSecret: storedClientSecret,
        storageKeyPrefix: storageKeyPrefix,
        expiresIn: expiresIn,
      );
      // Proactively refresh if token is expired or close to expiry
      if (provider != null && provider is GoogleDriveProviderDesktop) {
        if (provider._desktopManualTokenHttpClient != null && provider._manualRefreshToken != null) {
          if (provider._manualTokenExpiry == null ||
              DateTime.now().isAfter(provider._manualTokenExpiry!.subtract(const Duration(minutes: 5)))) {
            debugPrint('Google Drive Desktop loadFromStorage: token expired or near expiry, attempting refresh.');
            final refreshed = await provider._desktopManualTokenHttpClient!.refresh();
            if (!refreshed) {
              debugPrint('Google Drive Desktop loadFromStorage: token refresh failed.');
            }
          }
        }
      }
      return provider;
    } catch (e) {
      debugPrint('Google Drive Desktop loadFromStorage failed: $e');
      return null;
    }
  }

  @override
  Future<String?> loggedInUserDisplayName() async {
    try {
      final response = await client.get(
        Uri.parse('https://www.googleapis.com/oauth2/v3/userinfo'),
        headers: {'Authorization': 'Bearer $_accessToken'},
      );

      if (response.statusCode == 200) {
        final userInfo = jsonDecode(response.body);
        return userInfo['name'];
      } else {
        debugPrint(
            'Failed to fetch user info. Status: ${response.statusCode}, Body: ${response.body}');
      }
    } catch (e) {
      debugPrint('Error fetching user info: $e');
    }
    return null;
  }

  @override
  Future<String?> loggedInUserEmail() async {
    try {
      final response = await client.get(
        Uri.parse('https://www.googleapis.com/oauth2/v3/userinfo'),
        headers: {'Authorization': 'Bearer $_accessToken'},
      );
      if (response.statusCode == 200) {
        final userInfo = jsonDecode(response.body);
        return userInfo['email'] as String?;
      }
    } catch (e) {
      debugPrint('Error fetching user email: $e');
    }
    return null;
  }

  @override
  Future<String?> loggedInUserId() async {
    try {
      final response = await client.get(
        Uri.parse('https://www.googleapis.com/oauth2/v3/userinfo'),
        headers: {'Authorization': 'Bearer $_accessToken'},
      );
      if (response.statusCode == 200) {
        final userInfo = jsonDecode(response.body);
        return userInfo['sub'] as String?;
      }
    } catch (e) {
      debugPrint('Error fetching user id: $e');
    }
    return null;
  }

  @override
  Future<void> signOut() async {
    try {
      await _googleSignIn?.signOut();
    } catch (error) {
      debugPrint('Failed to sign out or disconnect from Google. $error');
    } finally {
      _googleSignIn = null;
      isAuthenticated = false;
      // Clear persisted tokens
      if (_storageKeyPrefix != null) {
        await _secureStorage.delete(key: '${_storageKeyPrefix}access_token');
        await _secureStorage.delete(key: '${_storageKeyPrefix}refresh_token');
        await _secureStorage.delete(key: '${_storageKeyPrefix}token_expiry');
        await _secureStorage.delete(key: '${_storageKeyPrefix}client_id');
        await _secureStorage.delete(key: '${_storageKeyPrefix}client_secret');
      }
      debugPrint('User signed out from Google Drive.');
    }
  }

  @override
  Future<T> handleAuthErrorAndRetry<T>(
      Future<T> Function() request, Object error, StackTrace stackTrace, {int authRetryCount = 0}) async {
    if (authRetryCount >= 1) {
      debugPrint('Auth retry limit reached. Throwing original error.');
      throw error;
    }
    debugPrint('Authentication error occurred. Attempting to reconnect...');
    isAuthenticated = false;
    try {
      if (_desktopManualTokenHttpClient != null) {
        final refreshed = await _desktopManualTokenHttpClient!.refresh();
        if (refreshed) {
          isAuthenticated = true;
          debugPrint('Successfully refreshed manual token. Retrying the original request.');
          try {
            return await request();
          } on drive.DetailedApiRequestError catch (e) {
            if (e.status == 401 || e.status == 403) {
              debugPrint('Auth retry limit reached after reconnect. Throwing original error.');
              throw error;
            }
            rethrow;
          } on AccessDeniedException {
            debugPrint('Auth retry limit reached after reconnect. Throwing original error.');
            throw error;
          }
        }
      }
      if (_googleSignIn != null) {
        final credentials = await _googleSignIn!.signIn();
        if (credentials != null) {
          _accessToken = credentials.accessToken;
          final client = await _googleSignIn!.authenticatedClient;
          if (client != null) {
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
            try {
              return await request();
            } on drive.DetailedApiRequestError catch (e) {
              if (e.status == 401 || e.status == 403) {
                debugPrint('Auth retry limit reached after reconnect. Throwing original error.');
                throw error;
              }
              rethrow;
            } on AccessDeniedException {
              debugPrint('Auth retry limit reached after reconnect. Throwing original error.');
              throw error;
            }
          }
        }
      }
    } catch (e) {
      if (e == error) rethrow;
      debugPrint('Failed to reconnect after auth error: $e');
    }
    throw error;
  }

  @override
  Future<String?> getAccessToken() async {
    if (_desktopManualTokenHttpClient != null) {
      if (_manualTokenExpiry != null &&
          DateTime.now().isAfter(_manualTokenExpiry!.subtract(const Duration(minutes: 5)))) {
        await _desktopManualTokenHttpClient!.refresh();
      }
      return _desktopManualTokenHttpClient!.accessToken;
    }
    return _accessToken;
  }

  @override
  Future<String?> getRefreshToken() async => _manualRefreshToken;

  @override
  Future<DateTime?> getTokenExpiry() async => _manualTokenExpiry;

  @override
  Future<bool> refreshAccessToken() async {
    if (_desktopManualTokenHttpClient != null) {
      return _desktopManualTokenHttpClient!.refresh();
    }
    if (_googleSignIn != null) {
      try {
        final credentials = await _googleSignIn!.signIn();
        if (credentials != null) {
          _accessToken = credentials.accessToken;
          final client = await _googleSignIn!.authenticatedClient;
          if (client != null) {
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
        }
        return false;
      } catch (e) {
        debugPrint('Google Drive Desktop token refresh failed: $e');
        return false;
      }
    }
    return false;
  }
}

class _DesktopManualTokenHttpClient extends http.BaseClient {
  _DesktopManualTokenHttpClient({
    required this.accessToken,
    this.refreshToken,
    this.clientId,
    this.clientSecret,
    this.onTokenRefreshed,
  });

  String accessToken;
  final String? refreshToken;
  final String? clientId;
  final String? clientSecret;
  final void Function(String newAccessToken, int? expiresIn)? onTokenRefreshed;
  final http.Client _inner = http.Client();
  bool _isRefreshing = false;
  Completer<bool>? _refreshCompleter;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    request.headers['Authorization'] = 'Bearer $accessToken';
    final response = await _inner.send(request);

    if (response.statusCode == 401 && refreshToken != null && clientId != null) {
      if (_isRefreshing && _refreshCompleter != null) {
        final refreshed = await _refreshCompleter!.future;
        if (refreshed) {
          final retryRequest = _copyRequest(request);
          retryRequest.headers['Authorization'] = 'Bearer $accessToken';
          return _inner.send(retryRequest);
        }
        return response;
      }
      final refreshed = await _refreshAccessToken();
      if (refreshed) {
        final retryRequest = _copyRequest(request);
        retryRequest.headers['Authorization'] = 'Bearer $accessToken';
        return _inner.send(retryRequest);
      }
    }

    return response;
  }

  Future<bool> _refreshAccessToken() async {
    if (refreshToken == null || clientId == null) return false;
    _isRefreshing = true;
    _refreshCompleter = Completer<bool>();
    try {
      final body = {
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        'client_id': clientId!,
      };
      if (clientSecret != null && clientSecret!.isNotEmpty) {
        body['client_secret'] = clientSecret!;
      }
      final response = await http.post(
        Uri.parse('https://oauth2.googleapis.com/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: body,
      );
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        accessToken = json['access_token'] as String;
        final expiresIn = json['expires_in'] as int?;
        debugPrint('Google Drive Desktop manual token client: access token refreshed successfully.');
        onTokenRefreshed?.call(accessToken, expiresIn);
        _refreshCompleter!.complete(true);
        return true;
      } else {
        debugPrint('Google Drive Desktop manual token client: token refresh failed: ${response.statusCode}');
        _refreshCompleter!.complete(false);
        return false;
      }
    } catch (e) {
      debugPrint('Google Drive Desktop manual token client: token refresh error: $e');
      _refreshCompleter!.complete(false);
      return false;
    } finally {
      _isRefreshing = false;
      _refreshCompleter = null;
    }
  }

  Future<bool> refresh() => _refreshAccessToken();

  http.Request _copyRequest(http.BaseRequest original) {
    if (original is! http.Request) {
      throw StateError('Cannot copy non-Request BaseRequest');
    }
    final copy = http.Request(original.method, original.url);
    copy.headers.addAll(original.headers);
    copy.bodyBytes = original.bodyBytes;
    copy.encoding = original.encoding;
    copy.followRedirects = original.followRedirects;
    copy.maxRedirects = original.maxRedirects;
    copy.persistentConnection = original.persistentConnection;
    return copy;
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
    GoogleDriveProviderDesktop.connect(
        forceInteractive: forceInteractive,
        scopes: scopes,
        serverClientId: serverClientId,
        clientSecret: clientSecret,
        redirectPort: redirectPort);
