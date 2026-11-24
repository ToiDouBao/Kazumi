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
    this.confident = true,
  });

  final SkipSegmentKind kind;
  final Duration start;

  /// 跳过后要去的位置；片尾一直到视频结束时为视频总长
  final Duration end;

  /// 时间可靠时倒数后自动跳过；不可靠时只显示跳过按钮，由用户决定
  final bool confident;

  Duration get length => end - start;

  SkipSegment withConfidence(bool value) =>
      SkipSegment(kind: kind, start: start, end: end, confident: value);

  @override
  bool operator ==(Object other) =>
      other is SkipSegment &&
      other.kind == kind &&
      other.start == start &&
      other.end == end &&
      other.confident == confident;

  @override
  int get hashCode => Object.hash(kind, start, end, confident);

  @override
  String toString() => 'SkipSegment(${kind.name}, $start - $end'
      '${confident ? '' : ', manual'})';
}

const Duration _minSegmentLength = Duration(seconds: 20);
const Duration _maxSegmentLength = Duration(seconds: 180);

/// AniSkip 里 OP/ED 的合理长度，之外的多半是投稿错误
const Duration _minSongLength = Duration(seconds: 45);
const Duration _maxSongLength = Duration(seconds: 130);

/// AniSkip 数据和本地视频长度最多可以相差多少，超过就认为不是同一个版本
const Duration aniSkipLengthTolerance = Duration(seconds: 15);

/// 长度相差在这个范围内才认为是同一个视频版本，可以自动跳过；
/// 否则时间可能整体偏移几秒，只显示跳过按钮
const Duration aniSkipConfidentTolerance = Duration(seconds: 3);

/// 片段结束点离视频结尾这么近时，直接跳到结尾（触发自动连播）
const Duration _snapToEndThreshold = Duration(seconds: 3);

Duration _seconds(num value) =>
    Duration(milliseconds: (value * 1000).round());

/// 解析 AniSkip v2 `skip-times` 接口的返回
///
/// AniSkip 只在视频长度完全一致时才返回结果，所以这里用 `episodeLength=0`
/// 拿到全部投稿，再自己按 [videoLength] 过滤：每个投稿记录了投稿者的视频长度，
/// 相差超过 [aniSkipLengthTolerance] 的忽略，超过 [aniSkipConfidentTolerance]
/// 的只作为手动跳过。
///
/// 不使用 `mixed-op` / `mixed-ed`：那是叠在正片画面上的 OP/ED，跳过会漏掉剧情。
/// 长度不像一首歌、或者位置不对（片头在后半段、片尾在前半段）的投稿也忽略。
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
      'op' => SkipSegmentKind.opening,
      'ed' => SkipSegmentKind.ending,
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
    final reference = _seconds(submittedLength);
    if (end - start < _minSongLength || end - start > _maxSongLength) {
      continue;
    }
    final inPlace = kind == SkipSegmentKind.opening
        ? start < reference * 0.45
        : start > reference * 0.5;
    if (!inPlace) continue;
    // 投稿者的片尾一直到结尾时，在本地视频里也跳到结尾
    if (reference - end <= _snapToEndThreshold &&
        videoLength > Duration.zero) {
      end = videoLength;
    }
    if (videoLength > Duration.zero && start >= videoLength) continue;

    final previous = byKind[kind];
    if (previous == null || diff < previous.diff) {
      byKind[kind] = (
        segment: SkipSegment(
          kind: kind,
          start: start,
          end: end,
          confident: videoLength > Duration.zero &&
              diff <= aniSkipConfidentTolerance,
        ),
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
    // 标题写明的章节可以自动跳过，按长度猜的只显示按钮
    var titled = true;
    final title = sorted[i].title;
    if (_openingTitle.hasMatch(title)) {
      kind = SkipSegmentKind.opening;
    } else if (_endingTitle.hasMatch(title)) {
      kind = SkipSegmentKind.ending;
    } else if (typicalLength != null &&
        length >= typicalLength.$1 &&
        length <= typicalLength.$2) {
      titled = false;
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
    segments.add(
      SkipSegment(kind: kind, start: start, end: end, confident: titled),
    );
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

  /// 自动跳过前剩余的秒数；时间不可靠、只提供按钮时为 null
  final int? secondsLeft;

  bool get automatic => secondsLeft != null;
}

/// 刚刚跳过的片段，在 [OpEdSkipTracker.undoSeconds] 秒内可以撤销
@immutable
class RecentSkip {
  const RecentSkip(this.segment, this.from, this.secondsLeft);

  final SkipSegment segment;

  /// 跳过前的播放位置，撤销时回到这里
  final Duration from;
  final int secondsLeft;
}

/// 根据播放进度决定什么时候提示、什么时候跳过
///
/// 每秒调用一次 [tick]。进入片段前 [leadTime] 开始提示：
/// - 时间可靠的片段倒数 [countdownSeconds] 秒（只在播放时倒数），然后跳过；
/// - 不可靠的片段只显示跳过按钮，不会自动跳。
/// 跳过后 [undoSeconds] 秒内可以撤销。用户取消、跳过或撤销之后，
/// 本集内同一片段不再提示（即使往回拖动重看）。
class OpEdSkipTracker {
  OpEdSkipTracker({
    this.countdownSeconds = 3,
    this.leadTime = const Duration(seconds: 3),
    this.undoSeconds = 5,
  });

  final int countdownSeconds;
  final Duration leadTime;
  final int undoSeconds;

  /// 剩余至少这么多时才值得跳
  static const Duration _minRemaining = Duration(seconds: 5);

  List<SkipSegment> _segments = const [];
  final Set<SkipSegment> _handled = {};

  final ValueNotifier<PendingSkip?> pending = ValueNotifier(null);
  final ValueNotifier<RecentSkip?> recent = ValueNotifier(null);

  List<SkipSegment> get segments => _segments;

  void setSegments(List<SkipSegment> segments) {
    _segments = List.unmodifiable(segments);
    _handled.clear();
    pending.value = null;
    recent.value = null;
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
    final undo = recent.value;
    if (undo != null && playing) {
      recent.value = undo.secondsLeft > 1
          ? RecentSkip(undo.segment, undo.from, undo.secondsLeft - 1)
          : null;
    }

    final segment = _segmentAt(position);
    final current = pending.value;
    if (segment == null) {
      // 拖出了片段范围，下次进入时重新提示
      if (current != null) pending.value = null;
      return null;
    }
    if (current == null || current.segment != segment) {
      pending.value =
          PendingSkip(segment, segment.confident ? countdownSeconds : null);
      return null;
    }
    final left = current.secondsLeft;
    if (left == null || !playing) return null;
    if (left > 1) {
      pending.value = PendingSkip(segment, left - 1);
      return null;
    }
    return _complete(segment, position);
  }

  /// 立即跳过当前提示的片段
  Duration? skipNow(Duration position) {
    final segment = pending.value?.segment;
    return segment == null ? null : _complete(segment, position);
  }

  /// 本集不再跳过当前提示的片段
  void cancel() {
    final segment = pending.value?.segment;
    if (segment == null) return;
    _handled.add(segment);
    pending.value = null;
  }

  /// 撤销刚才的跳过，返回要回到的位置
  Duration? undo() {
    final undo = recent.value;
    recent.value = null;
    return undo?.from;
  }

  Duration _complete(SkipSegment segment, Duration position) {
    _handled.add(segment);
    pending.value = null;
    recent.value = RecentSkip(segment, position, undoSeconds);
    return segment.end;
  }

  void dispose() {
    pending.dispose();
    recent.dispose();
  }
}

final RegExp _episodeNumber = RegExp(
  r'第\s*0*(\d+)\s*[集话話]|\bep?\s*0*(\d+)\b|^\s*0*(\d+)\s*$',
  caseSensitive: false,
);

/// 选集标题里的集数是否和它在列表中的位置（从 1 开始）一致
///
/// AniSkip 按位置查询；列表开头多了 PV、第 0 集，或者站点把第二季
/// 接着第一季编号时，位置和真正的集数对不上，查到的时间就不可靠。
/// 标题里没有集数时无法判断，按一致处理。
bool episodeNumberMatchesPosition(String title, int position) {
  final match = _episodeNumber.firstMatch(title);
  if (match == null) return true;
  final number =
      int.tryParse(match.group(1) ?? match.group(2) ?? match.group(3) ?? '');
  return number == null || number == position;
}
