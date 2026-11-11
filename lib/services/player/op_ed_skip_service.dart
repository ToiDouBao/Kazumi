import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/player/op_ed_skip.dart';
import 'package:kazumi/services/storage/settings_keys.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 查询片头片尾时间
///
/// 时间来自 AniSkip（https://aniskip.com，社区投稿，按 MyAnimeList id 和集数查询）。
/// Bangumi 条目先通过 AniList 按日文名 + 年份找到对应的 MyAnimeList id，结果会缓存。
class OpEdSkipService {
  Dio get _dio => DioFactory.apiDio;

  static const String _aniListUrl = 'https://graphql.anilist.co';
  static const String _aniSkipUrl = 'https://api.aniskip.com/v2/skip-times';
  static const Duration _timeout = Duration(seconds: 8);

  static const String _searchQuery = r'''
query ($search: String) {
  Page(perPage: 10) {
    media(search: $search, type: ANIME) {
      idMal
      format
      episodes
      seasonYear
      startDate { year }
      title { native romaji english }
      synonyms
    }
  }
}''';

  Map<String, int>? _malIds;
  final Set<int> _notFound = {};
  final Map<String, Future<Object?>> _skipTimes = {};

  Map<String, int> get _malIdCache {
    final cached = _malIds;
    if (cached != null) return cached;
    final loaded = <String, int>{};
    try {
      final decoded =
          jsonDecode(GStorage.getSetting(SettingsKeys.malIdCache));
      if (decoded is Map) {
        decoded.forEach((key, value) {
          if (value is int) loaded['$key'] = value;
        });
      }
    } catch (e) {
      KazumiLogger().w('OpEdSkipService: failed to load MAL id cache', error: e);
    }
    return _malIds = loaded;
  }

  /// 找出该集的片头片尾；查不到时返回空列表，不会抛出异常
  Future<List<SkipSegment>> fetchSegments(
    BangumiItem item, {
    required int episode,
    required Duration videoLength,
  }) async {
    try {
      final malId = await malIdFor(item);
      if (malId == null) return const [];
      final key = '$malId:$episode';
      final response = await (_skipTimes[key] ??= _fetchSkipTimes(malId, episode));
      return parseAniSkipResponse(response, videoLength);
    } catch (e) {
      KazumiLogger().w('OpEdSkipService: lookup failed', error: e);
      return const [];
    }
  }

  Future<Object?> _fetchSkipTimes(int malId, int episode) async {
    try {
      // episodeLength=0：拿全部投稿，按长度过滤在 parseAniSkipResponse 里做
      final response = await _dio.get(
        '$_aniSkipUrl/$malId/$episode'
        '?types[]=op&types[]=ed&types[]=mixed-op&types[]=mixed-ed'
        '&episodeLength=0',
        options: Options(
          receiveTimeout: _timeout,
          sendTimeout: _timeout,
          // 没有数据时 AniSkip 返回 404
          validateStatus: (status) => status == 200 || status == 404,
        ),
      );
      final data = response.data;
      return data is String ? jsonDecode(data) : data;
    } catch (e) {
      _skipTimes.remove('$malId:$episode');
      rethrow;
    }
  }

  Future<int?> malIdFor(BangumiItem item) async {
    final cacheKey = '${item.id}';
    final cached = _malIdCache[cacheKey];
    if (cached != null) return cached;
    if (_notFound.contains(item.id)) return null;

    final names = [
      item.name,
      item.nameCn,
      ...item.alias,
    ].where((n) => n.trim().isNotEmpty).toList();
    if (names.isEmpty) return null;

    final year = int.tryParse(item.airYear);
    final isMovie = item.formatLabel == '剧场版' || item.formatLabel == '电影';
    final searches = <String>{
      names.first,
      stripSeasonSuffix(names.first),
    }.where((s) => s.isNotEmpty);

    for (final search in searches) {
      final candidates = await _searchAniList(search);
      final malId = pickMalId(
        candidates,
        names: names,
        year: year,
        isMovie: isMovie,
        totalEpisodes: item.totalEpisodes,
      );
      if (malId != null) {
        _malIdCache[cacheKey] = malId;
        unawaited(GStorage.putSetting(
          SettingsKeys.malIdCache,
          jsonEncode(_malIdCache),
        ));
        return malId;
      }
    }
    _notFound.add(item.id);
    return null;
  }

  Future<List<AniListCandidate>> _searchAniList(String search) async {
    final response = await _dio.post(
      _aniListUrl,
      data: jsonEncode({
        'query': _searchQuery,
        'variables': {'search': search},
      }),
      options: Options(
        receiveTimeout: _timeout,
        sendTimeout: _timeout,
        headers: {
          'content-type': 'application/json',
          'accept': 'application/json',
        },
      ),
    );
    var data = response.data;
    if (data is String) data = jsonDecode(data);
    final media = (((data as Map?)?['data'] as Map?)?['Page'] as Map?)?['media'];
    if (media is! List) return const [];
    return [
      for (final m in media)
        if (m is Map)
          (
            idMal: m['idMal'] as int?,
            format: m['format'] as String?,
            // 用首播年份，和 Bangumi 的放送日期一致（seasonYear 对年末开播的番会差一年）
            year: ((m['startDate'] as Map?)?['year'] as int?) ??
                (m['seasonYear'] as int?),
            episodes: m['episodes'] as int?,
            titles: [
              ...((m['title'] as Map?)?.values.whereType<String>() ??
                  const <String>[]),
              ...((m['synonyms'] as List?)?.whereType<String>() ??
                  const <String>[]),
            ],
          ),
    ];
  }
}
