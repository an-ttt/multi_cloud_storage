import 'dart:typed_data';

abstract class CloudStorageProvider {
  /// Lists all files and directories at the specified [path].
  Future<List<CloudFile>> listFiles({
    required String path,
    bool recursive = false,
  });

  /// Downloads a file from a [remotePath] to a [localPath] on the device.
  Future<String> downloadFile({
    required String remotePath,
    required String localPath,
  });

  /// Uploads a file from a [localPath] to a [remotePath] in the cloud.
  Future<String> uploadFile({
    required String localPath,
    required String remotePath,
    Map<String, dynamic>? metadata,
  });

  /// Deletes the file or directory at the specified [path].
  Future<void> deleteFile(String path);

  /// Creates a new directory at the specified [path].
  Future<void> createDirectory(String path);

  /// Retrieves metadata for the file or directory at the specified [path].
  Future<CloudFile> getFileMetadata(String path);

  /// Retrieves the display name of the currently logged-in user.
  Future<String?> loggedInUserDisplayName();

  /// Checks if the current user's authentication token is expired.
  Future<bool> tokenExpired();

  /// 验证当前凭据是否仍然有效（通过实际 API 调用检查）
  /// 返回 true 表示凭据有效，false 表示无效
  /// 默认实现使用 tokenExpired()，子类可覆盖
  Future<bool> validateCredentials() async {
    return !(await tokenExpired());
  }

  /// Logs out the current user from the cloud service.
  Future<bool> logout();

  /// Generates a shareable link for the file or directory at the [path].
  Future<Uri?> generateShareLink(String path);

  /// Extracts a share token from a given [shareLink].
  Future<String?> getShareTokenFromShareLink(Uri shareLink);

  /// Downloads a file to [localPath] using a [shareToken].
  Future<String> downloadFileByShareToken(
      {required String shareToken, required String localPath});

  /// Uploads a file from [localPath] using a [shareToken].
  Future<String> uploadFileByShareToken({
    required String localPath,
    required String shareToken,
    Map<String, dynamic>? metadata,
  });

  Future<Uint8List> getFileRange({
    required String path,
    required int offset,
    required int length,
  });

  Future<String?> getDownloadUrl(String path);

  Future<String?> getAccessToken();

  Future<String?> getRefreshToken();

  Future<DateTime?> getTokenExpiry();

  /// Forces a token refresh. Returns true if successful.
  Future<bool> refreshAccessToken();

  /// Saves the current token to secure storage with the specified key prefix.
  /// Used to migrate tokens from default keys to account-specific keys
  /// after the accountId is determined post-OAuth.
  Future<void> saveToStorage(String storageKeyPrefix);

  Future<String?> loggedInUserEmail();

  Future<String?> loggedInUserId();

  // 🎯 路径规范化虚函数，子类可 override 以适配不同云存储的 ID/路径格式
  // 默认实现：确保路径以 / 开头，Dropbox id: 前缀原样传递
  // Google Drive 等 provider 可 override 为原样传递（file ID 不需要路径规范化）
  String normalizePath(String path) {
    if (path.isEmpty) return '/';
    if (path == 'root') return '/';
    if (path.startsWith('id:')) return path;
    return path.startsWith('/') ? path : '/$path';
  }
}

/// Represents a file or directory within the cloud storage.
class CloudFile {
  /// The full path of the item.
  final String path;

  /// The name of the item.
  final String name;

  /// The size of the file in bytes. Null for directories.
  final int? size;

  /// The last modified timestamp.
  final DateTime? modifiedTime;

  /// True if the item is a directory.
  final bool isDirectory;

  /// Custom metadata associated with the file.
  final Map<String, dynamic>? metadata;
  final String? id;
  final String? mimeType;

  CloudFile({
    required this.path,
    required this.name,
    required this.size,
    required this.modifiedTime,
    required this.isDirectory,
    this.metadata,
    this.id,
    this.mimeType,
  });

  // M-03 fix: 重写 hashCode 和 == 以支持集合操作中的值比较
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CloudFile &&
          runtimeType == other.runtimeType &&
          path == other.path &&
          id == other.id;

  @override
  int get hashCode => Object.hash(path, id);

  @override
  String toString() =>
      'CloudFile(path: $path, name: $name, isDirectory: $isDirectory, size: $size, id: $id)';
}
