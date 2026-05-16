import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in_all_platforms/google_sign_in_all_platforms.dart'
    as all_platforms;
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/googleapis_auth.dart' show AccessDeniedException;
import 'package:http/retry.dart';
import 'package:multi_cloud_storage/exceptions/no_connection_exception.dart';
import 'google_drive_provider.dart';

class GoogleDriveProviderDesktop extends GoogleDriveProvider {
  all_platforms.GoogleSignIn? _googleSignIn;

  // 🎯 复用 GoogleSignIn 实例，避免重复创建导致 "__params is already not null" 断言错误
  // google_sign_in_all_platforms 内部使用单例 GoogleSignInAllPlatformsInterface.instance，
  // 其 _setParams() 有 assert(_params == null) 断言，第二次创建 GoogleSignIn 时会触发此断言失败。
  // 复用同一实例可避免重复调用 init()，从而绕过该限制。
  static all_platforms.GoogleSignIn? _sharedGoogleSignIn;

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
    try {
      // 🎯 复用已有的 GoogleSignIn 实例，避免 "__params is already not null" 错误
      all_platforms.GoogleSignIn googleSignIn;
      if (_sharedGoogleSignIn != null) {
        googleSignIn = _sharedGoogleSignIn!;
        debugPrint('Reusing existing GoogleSignIn instance for Google Drive OAuth.');
      } else {
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

        final signInParams = all_platforms.GoogleSignInParams(
          clientId: serverClientId,
          clientSecret: clientSecret,
          scopes: GoogleDriveProvider.scopes,
          redirectPort: redirectPort,
        );

        googleSignIn = all_platforms.GoogleSignIn(params: signInParams);
        _sharedGoogleSignIn = googleSignIn;
      }

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

      final client = await googleSignIn.authenticatedClient;

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

  // S-04 fix: 使用认证客户端发起用户信息请求，确保 token 自动刷新和错误重试
  Future<Map<String, dynamic>?> _fetchUserInfo() async {
    try {
      if (_googleSignIn == null) return null;
      final authClient = await _googleSignIn!.authenticatedClient;
      if (authClient == null) return null;
      final response = await authClient.get(
        Uri.parse('https://www.googleapis.com/oauth2/v3/userinfo'),
      );
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
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
  Future<String?> loggedInUserDisplayName() async {
    final userInfo = await _fetchUserInfo();
    return userInfo?['name'] as String?;
  }

  @override
  Future<String?> loggedInUserEmail() async {
    final userInfo = await _fetchUserInfo();
    return userInfo?['email'] as String?;
  }

  @override
  Future<String?> loggedInUserId() async {
    final userInfo = await _fetchUserInfo();
    return userInfo?['sub'] as String?;
  }

  @override
  Future<void> signOut() async {
    try {
      await _googleSignIn?.signOut();
    } catch (error) {
      debugPrint('Failed to sign out or disconnect from Google. $error');
    } finally {
      // M-12 fix: 清理内部状态和引用
      _googleSignIn = null;
      _accessToken = null;
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
            } on drive.DetailedApiRequestError catch (retryError) {
              if (retryError.status == 401 || retryError.status == 403) {
                // M-13 fix: 抛出重试时的具体错误，而非原始错误，保留更多调试信息
                debugPrint('Auth retry limit reached after reconnect. Throwing retry error.');
                rethrow;
              }
              rethrow;
            } on AccessDeniedException {
              debugPrint('Auth retry limit reached after reconnect. Throwing retry error.');
              rethrow;
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

  static Future<bool> verifySilentLogin({
    String? serverClientId,
    String? clientSecret,
  }) async {
    try {
      all_platforms.GoogleSignIn googleSignIn;
      if (_sharedGoogleSignIn != null) {
        googleSignIn = _sharedGoogleSignIn!;
      } else {
        if (serverClientId == null) return false;
        int redirectPort = 0;
        try {
          final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
          redirectPort = socket.port;
          await socket.close();
        } catch (e) {
          debugPrint('Failed to allocate dynamic port for Google Drive silent login: $e');
          redirectPort = 8000;
        }
        final signInParams = all_platforms.GoogleSignInParams(
          clientId: serverClientId,
          clientSecret: clientSecret,
          scopes: GoogleDriveProvider.scopes,
          redirectPort: redirectPort,
        );
        googleSignIn = all_platforms.GoogleSignIn(params: signInParams);
        _sharedGoogleSignIn = googleSignIn;
      }
      final credentials = await googleSignIn.silentSignIn();
      if (credentials != null) {
        debugPrint('Google Drive Desktop silent login verified');
        return true;
      }
      debugPrint('Google Drive Desktop silent login failed: no cached credentials');
      return false;
    } catch (e) {
      debugPrint('Google Drive Desktop silent login verification failed: $e');
      return false;
    }
  }

  @override
  Future<bool> refreshAccessToken() async {
    if (_googleSignIn != null) {
      try {
        // M-14 fix: 使用 silentSignIn 避免弹出 UI 窗口
        final credentials = await _googleSignIn!.silentSignIn();
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

  // Google Drive uses SDK-managed tokens, no storage migration needed
  @override
  Future<void> saveToStorage(String storageKeyPrefix) async {}
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

Future<bool> verifyGoogleDriveSilentLogin({
  String? serverClientId,
  String? clientSecret,
}) =>
    GoogleDriveProviderDesktop.verifySilentLogin(
      serverClientId: serverClientId,
      clientSecret: clientSecret,
    );
