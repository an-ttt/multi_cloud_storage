import 'dart:typed_data';

abstract class CloudStorageProvider {
  /// Lists all files and directories at the specified [path].
  /// [isPath] true 表示 path 是路径，false 表示 path 是文件 ID
  Future<List<CloudFile>> listFiles({
    required String path,
    required bool isPath,
    bool recursive = false,
  });

  /// Downloads a file from a [remotePath] to a [localPath] on the device.
  /// [isPath] true 表示 remotePath 是路径，false 表示 remotePath 是文件 ID
  Future<String> downloadFile({
    required String remotePath,
    required String localPath,
    required bool isPath,
  });

  /// Uploads a file from [localPath] to a [remotePath] in the cloud.
  /// [isPath] true 表示 remotePath 是路径，false 表示 remotePath 是文件 ID
  Future<String> uploadFile({
    required String localPath,
    required String remotePath,
    required bool isPath,
    Map<String, dynamic>? metadata,
  });

  // 🎯 直接用 parentId + fileName 上传文件，避免拼接路径字符串后重新解析
  // parentId 语义固定为文件 ID，不需要 isPath 参数
  // Google Drive 等基于 ID 的 Provider 应 override 此方法，直接用 parentId 设置 parents
  // 其他 Provider 使用 default 实现（拼接路径后调 uploadFile）
  Future<String> uploadFileToParent({
    required String localPath,
    required String parentId,
    required String fileName,
    Map<String, dynamic>? metadata,
  }) async {
    final remotePath = '$parentId/$fileName';
    return uploadFile(localPath: localPath, remotePath: remotePath, isPath: false, metadata: metadata);
  }

  /// Deletes the file or directory at the specified [path].
  /// [isPath] true 表示 path 是路径，false 表示 path 是文件 ID
  Future<void> deleteFile(String path, {required bool isPath});

  /// Creates a new directory at the specified [path].
  /// [isPath] true 表示 path 是路径，false 表示 path 是文件 ID
  Future<void> createDirectory(String path, {required bool isPath});

  /// Retrieves metadata for the file or directory at the specified [path].
  /// [isPath] true 表示 path 是路径，false 表示 path 是文件 ID
  Future<CloudFile> getFileMetadata(String path, {required bool isPath});

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
  /// [isPath] true 表示 path 是路径，false 表示 path 是文件 ID
  Future<Uri?> generateShareLink(String path, {required bool isPath});

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

  /// [isPath] true 表示 path 是路径，false 表示 path 是文件 ID
  Future<Uint8List> getFileRange({
    required String path,
    required bool isPath,
    required int offset,
    required int length,
  });

  /// [isPath] true 表示 path 是路径，false 表示 path 是文件 ID
  Future<String?> getDownloadUrl(String path, {required bool isPath});

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
