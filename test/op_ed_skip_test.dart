import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/player/op_ed_skip.dart';

Duration s(num seconds) => Duration(milliseconds: (seconds * 1000).round());

Map<String, Object?> aniSkipResult(
  String type,
  num start,
  num end,
  num length,
) =>
    {
      'interval': {'startTime': start, 'endTime': end},
      'skipType': type,
      'skipId': 'x',
      'episodeLength': length,
    };

void main() {
  group('parseAniSkipResponse', () {
    test('reads opening and ending, snapping a final ending to the video end',
        () {
      final json = {
        'found': true,
        'results': [
          aniSkipResult('op', 153.346, 243.346, 1469.97),
          aniSkipResult('ed', 1370, 1468, 1471),
        ],
      };
      final segments = parseAniSkipResponse(json, s(1470));
      expect(segments, [
        SkipSegment(
            kind: SkipSegmentKind.opening, start: s(153.346), end: s(243.346)),
        SkipSegment(kind: SkipSegmentKind.ending, start: s(1370), end: s(1470)),
      ]);
    });

    test('keeps an ending followed by a preview', () {
      final json = {
        'found': true,
        'results': [aniSkipResult('ed', 1300, 1390, 1440)],
      };
      final segments = parseAniSkipResponse(json, s(1440));
      expect(segments.single.end, s(1390));
    });

    test('ignores submissions for a different video length', () {
      final json = {
        'found': true,
        'results': [
          aniSkipResult('op', 10, 100, 1300),
          aniSkipResult('ed', 1350, 1440, 1442),
        ],
      };
      final segments = parseAniSkipResponse(json, s(1440));
      expect(segments.map((e) => e.kind), [SkipSegmentKind.ending]);
    });

    test('picks the submission closest to the video length', () {
      final json = {
        'found': true,
        'results': [
          aniSkipResult('op', 30, 120, 1452),
          aniSkipResult('op', 15, 105, 1441),
        ],
      };
      expect(parseAniSkipResponse(json, s(1440)).single.start, s(15));
    });

    test('drops implausible lengths and handles empty responses', () {
      final json = {
        'found': true,
        'results': [aniSkipResult('op', 0, 5, 1440)],
      };
      expect(parseAniSkipResponse(json, s(1440)), isEmpty);
      expect(parseAniSkipResponse({'found': false, 'results': []}, s(1440)),
          isEmpty);
      expect(parseAniSkipResponse('oops', s(1440)), isEmpty);
    });
  });

  group('parseAniSkipResponse safety', () {
    test('ignores mixed OP/ED that plays over the story', () {
      final json = {
        'found': true,
        'results': [aniSkipResult('mixed-op', 1383, 1441, 1441.5)],
      };
      expect(parseAniSkipResponse(json, s(1441)), isEmpty);
    });

    test('rejects entries that cannot be a song', () {
      final json = {
        'found': true,
        'results': [
          aniSkipResult('op', 0, 27, 1430),
          aniSkipResult('ed', 1300, 1440, 1440),
          aniSkipResult('op', 1200, 1290, 1430),
          aniSkipResult('ed', 100, 190, 1430),
        ],
      };
      expect(parseAniSkipResponse(json, s(1430)), isEmpty);
    });

    test('only auto-skips when the video version matches', () {
      final json = {
        'found': true,
        'results': [
          aniSkipResult('op', 60, 150, 1432),
          aniSkipResult('ed', 1300, 1390, 1440),
        ],
      };
      final segments = parseAniSkipResponse(json, s(1430));
      expect(segments.map((e) => (e.kind, e.confident)), [
        (SkipSegmentKind.opening, true),
        (SkipSegmentKind.ending, false),
      ]);
    });
  });

  group('segmentsFromChapters', () {
    test('uses chapter titles', () {
      final segments = segmentsFromChapters([
        (start: s(0), title: 'Prologue'),
        (start: s(60), title: 'Opening'),
        (start: s(150), title: 'Part A'),
        (start: s(1300), title: 'ED'),
        (start: s(1390), title: 'Preview'),
      ], s(1420));
      expect(segments, [
        SkipSegment(kind: SkipSegmentKind.opening, start: s(60), end: s(150)),
        SkipSegment(kind: SkipSegmentKind.ending, start: s(1300), end: s(1390)),
      ]);
    });

    test('falls back to typical OP/ED length for untitled chapters', () {
      final segments = segmentsFromChapters([
        (start: s(0), title: 'Chapter 1'),
        (start: s(120), title: 'Chapter 2'),
        (start: s(210), title: 'Chapter 3'),
        (start: s(1330), title: 'Chapter 4'),
      ], s(1420));
      expect(segments.map((e) => (e.kind, e.start, e.confident)), [
        (SkipSegmentKind.opening, s(120), false),
        (SkipSegmentKind.ending, s(1330), false),
      ]);
    });

    test('recognises Chinese and Japanese chapter titles', () {
      final segments = segmentsFromChapters([
        (start: s(0), title: 'アバン'),
        (start: s(30), title: 'オープニング'),
        (start: s(120), title: '本编'),
        (start: s(1300), title: '片尾'),
      ], s(1420));
      expect(segments.map((e) => e.kind),
          [SkipSegmentKind.opening, SkipSegmentKind.ending]);
    });

    test('does not mistake words that start with op/ed', () {
      final segments = segmentsFromChapters([
        (start: s(0), title: 'Operation'),
        (start: s(30), title: 'Episode'),
      ], s(1420));
      expect(segments, isEmpty);
    });

    test('returns nothing without chapters', () {
      expect(segmentsFromChapters([], s(1420)), isEmpty);
    });
  });

  group('pickMalId', () {
    AniListCandidate candidate(int id, int year, List<String> titles,
            {String format = 'TV', int? episodes}) =>
        (
          idMal: id,
          format: format,
          year: year,
          episodes: episodes,
          titles: titles,
        );

    final heroAcademia = [
      candidate(31964, 2016, ['僕のヒーローアカデミア', 'Boku no Hero Academia']),
      candidate(33486, 2017, ['僕のヒーローアカデミア２']),
      candidate(54789, 2024, ['僕のヒーローアカデミア７'], episodes: 21),
      candidate(36873, 2018, ['僕のヒーローアカデミア THE MOVIE ～2人の英雄～'],
          format: 'MOVIE'),
    ];

    test('matches the season by air year', () {
      expect(
        pickMalId(heroAcademia,
            names: ['僕のヒーローアカデミア 第7期'], year: 2024, totalEpisodes: 21),
        54789,
      );
      expect(pickMalId(heroAcademia, names: ['僕のヒーローアカデミア'], year: 2016),
          31964);
    });

    test('prefers a movie for a movie entry', () {
      final sameYear = [
        candidate(1, 2018, ['僕のヒーローアカデミア３']),
        candidate(36873, 2018, ['僕のヒーローアカデミア THE MOVIE'],
            format: 'MOVIE'),
      ];
      expect(
        pickMalId(sameYear,
            names: ['僕のヒーローアカデミア THE MOVIE ～2人の英雄～'],
            year: 2018,
            isMovie: true),
        36873,
      );
    });

    test('does not guess across years or without a title match', () {
      expect(pickMalId(heroAcademia, names: ['僕のヒーローアカデミア'], year: 2030),
          isNull);
      expect(pickMalId(heroAcademia, names: ['別のアニメ']), isNull);
      expect(pickMalId(heroAcademia, names: ['Boku no Hero Academia']), 31964);
    });
  });

  test('stripSeasonSuffix removes season markers', () {
    expect(stripSeasonSuffix('僕のヒーローアカデミア 第7期'), '僕のヒーローアカデミア');
    expect(stripSeasonSuffix('進撃の巨人 Season 3'), '進撃の巨人');
    expect(stripSeasonSuffix('葬送のフリーレン'), '葬送のフリーレン');
  });

  group('OpEdSkipTracker', () {
    final opening =
        SkipSegment(kind: SkipSegmentKind.opening, start: s(60), end: s(150));

    OpEdSkipTracker tracker() => OpEdSkipTracker()..setSegments([opening]);

    test('counts down three seconds then skips to the segment end', () {
      final t = tracker();
      expect(t.tick(s(50), playing: true), isNull);
      expect(t.pending.value, isNull);

      expect(t.tick(s(57), playing: true), isNull);
      expect(t.pending.value!.secondsLeft, 3);
      expect(t.tick(s(58), playing: true), isNull);
      expect(t.pending.value!.secondsLeft, 2);
      expect(t.tick(s(59), playing: true), isNull);
      expect(t.pending.value!.secondsLeft, 1);
      expect(t.tick(s(60), playing: true), s(150));
      expect(t.pending.value, isNull);

      // 往回拖动重看片头不会再跳
      expect(t.tick(s(70), playing: true), isNull);
      expect(t.pending.value, isNull);
    });

    test('pauses the countdown while paused', () {
      final t = tracker();
      t.tick(s(58), playing: true);
      t.tick(s(58), playing: false);
      t.tick(s(58), playing: false);
      expect(t.pending.value!.secondsLeft, 3);
    });

    test('cancel keeps playing the segment', () {
      final t = tracker();
      t.tick(s(58), playing: true);
      t.cancel();
      expect(t.pending.value, isNull);
      for (var p = 59; p < 150; p++) {
        expect(t.tick(s(p), playing: true), isNull);
      }
    });

    test('skipNow jumps immediately', () {
      final t = tracker();
      t.tick(s(80), playing: true);
      expect(t.skipNow(s(80)), s(150));
      expect(t.skipNow(s(150)), isNull);
    });

    test('seeking away hides the prompt and it comes back later', () {
      final t = tracker();
      t.tick(s(58), playing: true);
      t.tick(s(10), playing: true);
      expect(t.pending.value, isNull);
      t.tick(s(59), playing: true);
      expect(t.pending.value!.secondsLeft, 3);
    });

    test('uncertain segments only offer a button', () {
      final t = OpEdSkipTracker()..setSegments([opening.withConfidence(false)]);
      for (var p = 57; p < 100; p++) {
        expect(t.tick(s(p), playing: true), isNull);
        expect(t.pending.value!.automatic, isFalse);
      }
      expect(t.skipNow(s(100)), s(150));
    });

    test('a skip can be undone for a few seconds', () {
      final t = tracker();
      t.tick(s(80), playing: true);
      expect(t.skipNow(s(80)), s(150));
      expect(t.recent.value!.from, s(80));
      t.tick(s(151), playing: true);
      expect(t.undo(), s(80));
      expect(t.recent.value, isNull);
      // 撤销后回到片头里也不会再提示
      t.tick(s(81), playing: true);
      expect(t.pending.value, isNull);
    });

    test('the undo button disappears after five seconds of playback', () {
      final t = tracker();
      t.tick(s(80), playing: true);
      t.skipNow(s(80));
      for (var i = 0; i < 4; i++) {
        t.tick(s(151 + i), playing: true);
      }
      expect(t.recent.value, isNotNull);
      t.tick(s(155), playing: false);
      expect(t.recent.value, isNotNull);
      t.tick(s(156), playing: true);
      expect(t.recent.value, isNull);
    });

    test('does not prompt near the end of a segment', () {
      final t = tracker();
      expect(t.tick(s(147), playing: true), isNull);
      expect(t.pending.value, isNull);
    });
  });

  test('episodeNumberMatchesPosition', () {
    expect(episodeNumberMatchesPosition('第05集', 5), isTrue);
    expect(episodeNumberMatchesPosition('第14集', 1), isFalse);
    expect(episodeNumberMatchesPosition('EP03', 3), isTrue);
    expect(episodeNumberMatchesPosition('07', 6), isFalse);
    expect(episodeNumberMatchesPosition('PV', 1), isTrue);
    expect(episodeNumberMatchesPosition('正片', 1), isTrue);
  });
}
