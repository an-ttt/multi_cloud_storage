import 'package:googleapis/drive/v3.dart' as gdrive;

/// Google Drive OAuth scope 常量
/// Drive 相关 scope 引用自 googleapis 包的 DriveApi，
/// userinfo scope 为 OpenID Connect 标准 scope，googleapis 未提供常量
class GoogleDriveScopes {
  GoogleDriveScopes._();

  static const String drive = gdrive.DriveApi.driveScope;
  static const String driveReadonly = gdrive.DriveApi.driveReadonlyScope;
  static const String driveFile = gdrive.DriveApi.driveFileScope;
  static const String driveAppdata = gdrive.DriveApi.driveAppdataScope;

  // OpenID Connect 标准 scope，googleapis 包未提供常量
  static const String userinfoEmail =
      'https://www.googleapis.com/auth/userinfo.email';
  static const String userinfoProfile =
      'https://www.googleapis.com/auth/userinfo.profile';
}
