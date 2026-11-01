import 'dart:async';

import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/pages/history/history_controller.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/player/history_playback_service.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart'
    show RuleCancelToken;
import 'package:kazumi/services/storage/settings_keys.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 一键继续观看：为番剧找一个能播放的规则。
///
/// 先用上次看的规则（有 lastSrc 时不用重新搜索），不行再按规则排名同时试前几个，
/// 取排名最高的成功结果。进入播放页后会自动跳到上次的集数和进度。
class ResumePlaybackService {
  ResumePlaybackService(
    this._pluginsController,
    this._historyController,
    this._historyPlaybackService,
  );

  final PluginsController _pluginsController;
  final HistoryController _historyController;
  final HistoryPlaybackService _historyPlaybackService;

  /// 搜索失败时最多同时尝试的规则数
  static const int maxCandidates = 4;

  /// 每个规则搜索 + 获取剧集列表的时限
  static const Duration perPluginTimeout = Duration(seconds: 8);

  Future<VideoPlaybackArgs?> open(
    BangumiItem bangumiItem, {
    RuleCancelToken? cancelToken,
  }) async {
    final stats = _pluginsController.playbackStats;
    final latest = _historyController.latestForBangumi(bangumiItem.id);
    String? triedPlugin;

    if (latest != null &&
        latest.lastSrc.isNotEmpty &&
        !stats.isUnreliable(latest.adapterName)) {
      triedPlugin = latest.adapterName;
      final result = await _historyPlaybackService.open(
        latest,
        cancelToken: cancelToken,
      );
      if (result is HistoryPlaybackReady) {
        return result.args;
      }
    }
    if (cancelToken?.isCancelled ?? false) return null;

    return findAlternative(
      bangumiItem,
      exclude: triedPlugin == null ? const {} : {triedPlugin},
      cancelToken: cancelToken,
    );
  }

  /// 按排名同时试前几个规则（跳过 [exclude]），返回排名最高且至少有
  /// [minEpisode] 集的结果。播放失败时用来换规则。
  Future<OnlineVideoPlaybackArgs?> findAlternative(
    BangumiItem bangumiItem, {
    Set<String> exclude = const {},
    int minEpisode = 1,
    RuleCancelToken? cancelToken,
  }) async {
    final plugins = List<Plugin>.of(_pluginsController.pluginList);
    final ordered = GStorage.getSetting(SettingsKeys.smartPluginOrder)
        ? _pluginsController.playbackStats.rank(plugins)
        : plugins;
    final candidates = ordered
        .where((plugin) => !exclude.contains(plugin.name))
        .take(maxCandidates)
        .toList();
    if (candidates.isEmpty) return null;

    final tokens = [for (final _ in candidates) RuleCancelToken()];
    unawaited(cancelToken?.whenCancel.then((_) {
      for (final token in tokens) {
        token.cancel();
      }
    }));
    final attempts = [
      for (var i = 0; i < candidates.length; i++)
        _tryPlugin(candidates[i], bangumiItem, tokens[i], minEpisode),
    ];
    try {
      // 按排名顺序取第一个成功的，其余的取消
      for (final attempt in attempts) {
        final args = await attempt;
        if (args != null) return args;
      }
      return null;
    } finally {
      for (final token in tokens) {
        if (!token.isCancelled) token.cancel();
      }
    }
  }

  Future<OnlineVideoPlaybackArgs?> _tryPlugin(
    Plugin plugin,
    BangumiItem bangumiItem,
    RuleCancelToken token,
    int minEpisode,
  ) {
    return _searchAndLoad(plugin, bangumiItem, token, minEpisode).timeout(
      perPluginTimeout,
      onTimeout: () {
        token.cancel();
        return null;
      },
    ).catchError((Object error) {
      KazumiLogger().w(
        'ResumePlaybackService: ${plugin.name} unavailable',
        error: error,
      );
      return null;
    });
  }

  Future<OnlineVideoPlaybackArgs?> _searchAndLoad(
    Plugin plugin,
    BangumiItem bangumiItem,
    RuleCancelToken token,
    int minEpisode,
  ) async {
    final keyword =
        bangumiItem.nameCn.isEmpty ? bangumiItem.name : bangumiItem.nameCn;
    final response = await plugin.queryBangumi(keyword, cancelToken: token);
    final match = pickBestSearchItem(response.data, [
      bangumiItem.nameCn,
      bangumiItem.name,
      ...bangumiItem.alias,
    ]);
    if (match == null) return null;
    final roads = await plugin.queryChapterRoads(match.src, cancelToken: token);
    if (!roads.any((road) => road.data.length >= minEpisode)) return null;
    return OnlineVideoPlaybackArgs(
      bangumiItem: bangumiItem,
      plugin: plugin,
      title: match.name,
      src: match.src,
      roads: roads,
    );
  }
}

/// 从搜索结果中挑最符合番名的一项：
/// 名字完全一致 > 包含番名 > 第一个结果。
SearchItem? pickBestSearchItem(List<SearchItem> results, List<String> names) {
  if (results.isEmpty) return null;
  final targets = {
    for (final name in names)
      if (_normalize(name).isNotEmpty) _normalize(name),
  };
  for (final result in results) {
    if (targets.contains(_normalize(result.name))) return result;
  }
  for (final result in results) {
    final normalized = _normalize(result.name);
    if (targets.any(normalized.contains)) return result;
  }
  return results.first;
}

String _normalize(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[\s\p{P}]', unicode: true), '');
