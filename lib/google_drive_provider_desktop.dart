import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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

  GoogleDriveProviderDesktop.internal() : super.internal();

  String? _accessToken;

  static Future<GoogleDriveProvider?> connect({
    bool forceInteractive = false,
    List<String>? scopes,
    String? serverClientId,
    String? clientSecret,
    int redirectPort = 0,
  }) async {
    debugPrint("connect Google Drive,  forceInteractive: $forceInteractive");
    if (scopes != null) {
      GoogleDriveProvider.scopes = scopes;
    }
    // 🎯 动态分配端口，避免硬编码 8000 端口冲突
    if (redirectPort == 0) {
      try {
        final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        redirectPort = socket.port;
        await socket.close();
      } catch (e) {
        debugPrint('Failed to allocate dynamic port for Google Drive OAuth: $e');
        redirectPort = 8000;
      }
    }
    try {
      final signInParams = all_platforms.GoogleSignInParams(
        clientId: serverClientId,
        clientSecret: clientSecret,
        scopes: GoogleDriveProvider.scopes,
        redirectPort: redirectPort,
      );

      final googleSignIn = all_platforms.GoogleSignIn(params: signInParams);

      all_platforms.GoogleSignInCredentials? credentials;
      if (forceInteractive) {
        credentials = await googleSignIn.signInOnline();
      } else {
        credentials = await googleSignIn.signIn();
      }

      if (credentials == null) {
        debugPrint('Google Sign-In returned null — user may have cancelled or token exchange failed (redirectPort: $redirectPort).');
        return null;
      }

      final http.Client? client = await googleSignIn.authenticatedClient;

      if (client == null) {
        debugPrint('Failed to get authenticated Google client — token may be invalid or expired.');
        throw Exception('Google Drive authentication failed: unable to obtain authenticated client. The access token may be invalid or expired.');
      }

      final retryClient = RetryClient(
        client,
        retries: 3,
        when: (response) => {500, 502, 503, 504}.contains(response.statusCode),
        onRetry: (request, response, retryCount) => debugPrint(
            'Retrying request to ${request.url} (Retry #$retryCount)'),
      );

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
      rethrow;
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
  Future<String?> getAccessToken() async => _accessToken;

  @override
  Future<String?> getRefreshToken() async => null;

  @override
  Future<DateTime?> getTokenExpiry() async => null;

  @override
  Future<bool> refreshAccessToken() async {
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

Future<GoogleDriveProvider?> connectToGoogleDrive(
        {bool forceInteractive = false,
        List<String>? scopes,
        String? serverClientId,
        String? clientSecret,
        int redirectPort = 0}) =>
    GoogleDriveProviderDesktop.connect(
        forceInteractive: forceInteractive,
        scopes: scopes,
        serverClientId: serverClientId,
        clientSecret: clientSecret,
        redirectPort: redirectPort);
