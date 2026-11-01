import 'package:kazumi/services/network/acceleration_mode.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/bangumi_mirror_credentials.dart';

enum BangumiAcceleration implements AccelerationMode {
  direct,
  ech,
  mirror;

  static BangumiAcceleration get current {
    final configured = values.asNameMap()[GStorage.getSetting(
          SettingsKeys.bangumiAcceleration,
        )] ??
        (GStorage.getSetting(SettingsKeys.enableBangumiProxy) ? mirror : direct);
    // 镜像接口需要编译时注入的密钥；自行编译的版本没有密钥，改为直连
    if (configured == mirror && !mirrorAvailable) return direct;
    return configured;
  }

  static bool get mirrorAvailable =>
      bangumiMirrorCredentials['id']!.isNotEmpty &&
      bangumiMirrorCredentials['value']!.isNotEmpty;

  @override
  String get label => switch (this) {
    direct => '直连',
    ech => 'ECH',
    mirror => '镜像',
  };

  @override
  String get description => switch (this) {
    direct => '访问官方接口',
    ech => '启用加密握手',
    mirror => '镜像接口（默认）',
  };
}
