import 'dart:convert';

import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/settings_keys.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 单个规则的播放表现
class PluginPlaybackRecord {
  PluginPlaybackRecord({
    this.success = 0,
    this.fail = 0,
    this.avgLoadMs,
  });

  /// 带衰减的成功/失败次数，越近的播放权重越高
  double success;
  double fail;

  /// 成功播放时从开始解析到播放器就绪的平均耗时（EWMA）
  double? avgLoadMs;

  double get total => success + fail;

  factory PluginPlaybackRecord.fromJson(Map<String, dynamic> json) {
    return PluginPlaybackRecord(
      success: (json['s'] as num?)?.toDouble() ?? 0,
      fail: (json['f'] as num?)?.toDouble() ?? 0,
      avgLoadMs: (json['ms'] as num?)?.toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
        's': success,
        'f': fail,
        if (avgLoadMs != null) 'ms': avgLoadMs,
      };
}

/// 记录每个规则的实际播放成功率和加载速度，用来自动给规则排序
///
/// 数据以 JSON 存在设置里，跨启动保留。
class PluginPlaybackStats {
  PluginPlaybackStats({
    String Function()? reader,
    Future<void> Function(String json)? writer,
  })  : _reader = reader ??
            (() => GStorage.getSetting(SettingsKeys.pluginPlaybackStats)),
        _writer = writer ??
            ((json) =>
                GStorage.putSetting(SettingsKeys.pluginPlaybackStats, json));

  final String Function() _reader;
  final Future<void> Function(String json) _writer;
  Map<String, PluginPlaybackRecord>? _records;

  /// 每次记录前旧数据乘以该系数，让排名跟得上规则的近况
  static const double decay = 0.9;

  /// 加载耗时的 EWMA 平滑系数
  static const double loadAlpha = 0.3;

  /// 没有速度数据时假设的加载耗时
  static const double unknownLoadMs = 3500;

  Map<String, PluginPlaybackRecord> get _data {
    final cached = _records;
    if (cached != null) return cached;
    final loaded = <String, PluginPlaybackRecord>{};
    try {
      final decoded = jsonDecode(_reader());
      if (decoded is Map<String, dynamic>) {
        decoded.forEach((name, value) {
          if (value is Map<String, dynamic>) {
            loaded[name] = PluginPlaybackRecord.fromJson(value);
          }
        });
      }
    } catch (e) {
      KazumiLogger().w('PluginPlaybackStats: failed to load stats', error: e);
    }
    return _records = loaded;
  }

  PluginPlaybackRecord? recordOf(String pluginName) => _data[pluginName];

  Future<void> record(String pluginName, {required bool ok, int? loadMs}) async {
    final record = _data.putIfAbsent(pluginName, PluginPlaybackRecord.new);
    record.success *= decay;
    record.fail *= decay;
    if (ok) {
      record.success += 1;
      if (loadMs != null && loadMs > 0) {
        final previous = record.avgLoadMs;
        record.avgLoadMs = previous == null
            ? loadMs.toDouble()
            : previous + loadAlpha * (loadMs - previous);
      }
    } else {
      record.fail += 1;
    }
    try {
      await _writer(jsonEncode(
        _data.map((name, value) => MapEntry(name, value.toJson())),
      ));
    } catch (e) {
      KazumiLogger().w('PluginPlaybackStats: failed to save stats', error: e);
    }
  }

  /// 0～1，越高越好。没有记录的规则得到中间分。
  double score(String pluginName) {
    final record = _data[pluginName];
    final success = record?.success ?? 0;
    final fail = record?.fail ?? 0;
    final successRate = (success + 1) / (success + fail + 2);
    final loadMs = record?.avgLoadMs ?? unknownLoadMs;
    final speedFactor = 1 / (1 + loadMs / 10000);
    return successRate * speedFactor;
  }

  /// 最近多次播放大多失败的规则
  bool isUnreliable(String pluginName) {
    final record = _data[pluginName];
    if (record == null || record.total < 2) return false;
    return record.success / record.total < 0.4;
  }

  /// 按分数从高到低排序；分数相同时保持规则管理里的手动顺序
  List<Plugin> rank(List<Plugin> plugins) => rankBy(plugins, (p) => p.name);

  List<T> rankBy<T>(List<T> items, String Function(T item) nameOf) {
    final indexed = [
      for (var i = 0; i < items.length; i++)
        (index: i, item: items[i], score: score(nameOf(items[i]))),
    ];
    indexed.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      return byScore != 0 ? byScore : a.index.compareTo(b.index);
    });
    return [for (final entry in indexed) entry.item];
  }
}
