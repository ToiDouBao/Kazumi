import 'package:flutter/foundation.dart';

/// 可跳过的片段类型
enum SkipSegmentKind {
  opening('片头'),
  ending('片尾');

  const SkipSegmentKind(this.label);

  final String label;
}

/// 视频中的一段片头或片尾
@immutable
class SkipSegment {
  const SkipSegment({
    required this.kind,
    required this.start,
    required this.end,
  });

  final SkipSegmentKind kind;
  final Duration start;

  /// 跳过后要去的位置；片尾一直到视频结束时为视频总长
  final Duration end;

  Duration get length => end - start;

  @override
  bool operator ==(Object other) =>
      other is SkipSegment &&
      other.kind == kind &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(kind, start, end);

  @override
  String toString() => 'SkipSegment(${kind.name}, $start - $end)';
}

const Duration _minSegmentLength = Duration(seconds: 20);
const Duration _maxSegmentLength = Duration(seconds: 180);

/// AniSkip 数据和本地视频长度最多可以相差多少，超过就认为不是同一个版本
const Duration aniSkipLengthTolerance = Duration(seconds: 15);

/// 片段结束点离视频结尾这么近时，直接跳到结尾（触发自动连播）
const Duration _snapToEndThreshold = Duration(seconds: 3);

Duration _seconds(num value) =>
    Duration(milliseconds: (value * 1000).round());

/// 解析 AniSkip v2 `skip-times` 接口的返回
///
/// AniSkip 只在视频长度完全一致时才返回结果，所以这里用 `episodeLength=0`
/// 拿到全部投稿，再自己按 [videoLength] 过滤：每个投稿记录了投稿者的视频长度，
/// 相差超过 [aniSkipLengthTolerance] 的忽略。
List<SkipSegment> parseAniSkipResponse(
  Object? json,
  Duration videoLength,
) {
  if (json is! Map || json['found'] != true) return const [];
  final results = json['results'];
  if (results is! List) return const [];

  final byKind = <SkipSegmentKind, ({SkipSegment segment, Duration diff})>{};
  for (final raw in results) {
    if (raw is! Map) continue;
    final kind = switch (raw['skipType']) {
      'op' || 'mixed-op' => SkipSegmentKind.opening,
      'ed' || 'mixed-ed' => SkipSegmentKind.ending,
      _ => null,
    };
    final interval = raw['interval'];
    final submittedLength = raw['episodeLength'];
    if (kind == null ||
        interval is! Map ||
        interval['startTime'] is! num ||
        interval['endTime'] is! num ||
        submittedLength is! num) {
      continue;
    }

    final diff = (videoLength - _seconds(submittedLength)).abs();
    if (videoLength > Duration.zero && diff > aniSkipLengthTolerance) {
      continue;
    }

    final start = _seconds(interval['startTime'] as num);
    var end = _seconds(interval['endTime'] as num);
    if (end - start < _minSegmentLength || end - start > _maxSegmentLength) {
      continue;
    }
    // 投稿者的片尾一直到结尾时，在本地视频里也跳到结尾
    if (_seconds(submittedLength) - end <= _snapToEndThreshold &&
        videoLength > Duration.zero) {
      end = videoLength;
    }
    if (videoLength > Duration.zero && start >= videoLength) continue;

    final previous = byKind[kind];
    if (previous == null || diff < previous.diff) {
      byKind[kind] = (
        segment: SkipSegment(kind: kind, start: start, end: end),
        diff: diff,
      );
    }
  }

  return [for (final entry in byKind.values) entry.segment]
    ..sort((a, b) => a.start.compareTo(b.start));
}

/// 视频内嵌章节
typedef VideoChapter = ({Duration start, String title});

// 不用 \b：它对中日文字符不起作用
final RegExp _openingTitle = RegExp(
    r'^\s*(opening|op|intro|片头|片頭|オープニング)(?![a-z])',
    caseSensitive: false);
final RegExp _endingTitle = RegExp(
    r'^\s*(ending|ed|outro|credits|片尾|エンディング)(?![a-z])',
    caseSensitive: false);

/// 从视频内嵌章节里找出片头片尾
///
/// 章节标题写明 OP / ED 的直接采用；没有标题时，按 OP/ED 的常见长度
/// （正片 80～95 秒，短篇 55～65 秒）判断，前半段算片头，后半段算片尾。
List<SkipSegment> segmentsFromChapters(
  List<VideoChapter> chapters,
  Duration videoLength,
) {
  if (chapters.isEmpty || videoLength <= Duration.zero) return const [];
  final sorted = [...chapters]..sort((a, b) => a.start.compareTo(b.start));

  final (Duration, Duration)? typicalLength =
      videoLength > const Duration(minutes: 20)
          ? (const Duration(seconds: 80), const Duration(seconds: 95))
          : videoLength > const Duration(minutes: 10)
              ? (const Duration(seconds: 55), const Duration(seconds: 65))
              : null;

  final segments = <SkipSegment>[];
  for (var i = 0; i < sorted.length; i++) {
    final start = sorted[i].start;
    final end = i + 1 < sorted.length ? sorted[i + 1].start : videoLength;
    final length = end - start;
    if (length <= Duration.zero) continue;

    SkipSegmentKind? kind;
    final title = sorted[i].title;
    if (_openingTitle.hasMatch(title)) {
      kind = SkipSegmentKind.opening;
    } else if (_endingTitle.hasMatch(title)) {
      kind = SkipSegmentKind.ending;
    } else if (typicalLength != null &&
        length >= typicalLength.$1 &&
        length <= typicalLength.$2) {
      kind = start + length ~/ 2 < videoLength ~/ 2
          ? SkipSegmentKind.opening
          : SkipSegmentKind.ending;
    }
    if (kind == null ||
        length < _minSegmentLength ||
        length > _maxSegmentLength) {
      continue;
    }
    if (segments.any((s) => s.kind == kind)) continue;
    segments.add(SkipSegment(kind: kind, start: start, end: end));
  }
  return segments;
}

/// AniList 搜索结果中的一项
typedef AniListCandidate = ({
  int? idMal,
  String? format,
  int? year,
  int? episodes,
  List<String> titles,
});

String _normalizeTitle(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[\s\p{P}\p{S}]', unicode: true), '');

final RegExp _seasonSuffix = RegExp(
  r'(\s*(第\s*[0-9一二三四五六七八九十]+\s*[期季部章]|'
  r'(season|s)\s*\d+|\d+(st|nd|rd|th)\s*season|'
  r'final\s*season|[0-9０-９]+)\s*)$',
  caseSensitive: false,
);

/// 去掉 “第7期”“Season 2” 之类的季数后缀，用于重新搜索
String stripSeasonSuffix(String title) =>
    title.replaceAll(_seasonSuffix, '').trim();

/// 从 AniList 搜索结果中找出和 Bangumi 条目对应的 MyAnimeList id
///
/// 知道播出年份时只接受同一年的结果，避免把第 2 季当成第 1 季；
/// 不知道年份时要求标题完全一致。
int? pickMalId(
  List<AniListCandidate> candidates, {
  required List<String> names,
  int? year,
  bool isMovie = false,
  int totalEpisodes = 0,
}) {
  final wanted = {
    for (final name in names)
      if (_normalizeTitle(name).isNotEmpty) _normalizeTitle(name),
  };

  int? bestId;
  var bestScore = -1;
  for (final candidate in candidates) {
    final id = candidate.idMal;
    if (id == null || id <= 0) continue;
    final titleMatch =
        candidate.titles.any((t) => wanted.contains(_normalizeTitle(t)));
    if (year != null) {
      if (candidate.year != year) continue;
    } else if (!titleMatch) {
      continue;
    }

    final candidateIsMovie = candidate.format == 'MOVIE';
    var score = 0;
    if (titleMatch) score += 4;
    if (candidateIsMovie == isMovie) score += 2;
    if (totalEpisodes > 0 && candidate.episodes == totalEpisodes) score += 1;
    if (score > bestScore) {
      bestScore = score;
      bestId = id;
    }
  }
  return bestId;
}

/// 跳过提示的当前状态，供界面显示
@immutable
class PendingSkip {
  const PendingSkip(this.segment, this.secondsLeft);

  final SkipSegment segment;
  final int secondsLeft;
}

/// 根据播放进度决定什么时候提示、什么时候跳过
///
/// 每秒调用一次 [tick]：进入片段前 [leadTime] 开始倒数 [countdownSeconds] 秒，
/// 播放中才倒数，倒数结束返回要跳到的位置。用户取消或跳过之后，
/// 本集内同一片段不再提示（即使往回拖动重看）。
class OpEdSkipTracker {
  OpEdSkipTracker({
    this.countdownSeconds = 3,
    this.leadTime = const Duration(seconds: 3),
  });

  final int countdownSeconds;
  final Duration leadTime;

  /// 剩余至少这么多时才值得跳
  static const Duration _minRemaining = Duration(seconds: 5);

  List<SkipSegment> _segments = const [];
  final Set<SkipSegment> _handled = {};

  final ValueNotifier<PendingSkip?> pending = ValueNotifier(null);

  List<SkipSegment> get segments => _segments;

  void setSegments(List<SkipSegment> segments) {
    _segments = List.unmodifiable(segments);
    _handled.clear();
    pending.value = null;
  }

  void reset() => setSegments(const []);

  SkipSegment? _segmentAt(Duration position) {
    for (final segment in _segments) {
      if (_handled.contains(segment)) continue;
      if (position >= segment.start - leadTime &&
          position < segment.end - _minRemaining) {
        return segment;
      }
    }
    return null;
  }

  /// 返回需要跳转到的位置；不需要跳转时返回 null
  Duration? tick(Duration position, {required bool playing}) {
    final segment = _segmentAt(position);
    final current = pending.value;
    if (segment == null) {
      // 拖出了片段范围，下次进入时重新倒数
      if (current != null) pending.value = null;
      return null;
    }
    if (current == null || current.segment != segment) {
      pending.value = PendingSkip(segment, countdownSeconds);
      return null;
    }
    if (!playing) return null;
    final left = current.secondsLeft - 1;
    if (left > 0) {
      pending.value = PendingSkip(segment, left);
      return null;
    }
    return _complete(segment);
  }

  /// 立即跳过当前提示的片段
  Duration? skipNow() {
    final segment = pending.value?.segment;
    return segment == null ? null : _complete(segment);
  }

  /// 本集不再跳过当前提示的片段
  void cancel() {
    final segment = pending.value?.segment;
    if (segment == null) return;
    _handled.add(segment);
    pending.value = null;
  }

  Duration _complete(SkipSegment segment) {
    _handled.add(segment);
    pending.value = null;
    return segment.end;
  }

  void dispose() => pending.dispose();
}
