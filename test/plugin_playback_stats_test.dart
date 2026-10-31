import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/services/player/resume_playback_service.dart';
import 'package:kazumi/services/plugin/plugin_playback_stats.dart';

void main() {
  group('PluginPlaybackStats', () {
    PluginPlaybackStats newStats({String initial = '{}'}) {
      var stored = initial;
      return PluginPlaybackStats(
        reader: () => stored,
        writer: (json) async => stored = json,
      );
    }

    test('fast reliable plugins rank above slow or failing ones', () async {
      final stats = newStats();
      for (var i = 0; i < 3; i++) {
        await stats.record('fast', ok: true, loadMs: 1500);
        await stats.record('slow', ok: true, loadMs: 9000);
        await stats.record('broken', ok: false);
      }

      final ranked = stats.rankBy(
        ['broken', 'slow', 'unknown', 'fast'],
        (name) => name,
      );
      expect(ranked.first, 'fast');
      expect(ranked.last, 'broken');
      expect(stats.isUnreliable('broken'), isTrue);
      expect(stats.isUnreliable('fast'), isFalse);
      expect(stats.isUnreliable('unknown'), isFalse);
    });

    test('keeps configured order for plugins without records', () {
      final stats = newStats();
      expect(stats.rankBy(['c', 'a', 'b'], (name) => name), ['c', 'a', 'b']);
    });

    test('recent failures pull a plugin down', () async {
      final stats = newStats();
      for (var i = 0; i < 3; i++) {
        await stats.record('a', ok: true, loadMs: 2000);
      }
      final before = stats.score('a');
      for (var i = 0; i < 3; i++) {
        await stats.record('a', ok: false);
      }
      expect(stats.score('a'), lessThan(before));
    });

    test('persists and reloads records', () async {
      var stored = '{}';
      final stats = PluginPlaybackStats(
        reader: () => stored,
        writer: (json) async => stored = json,
      );
      await stats.record('mgnacg', ok: true, loadMs: 1200);

      final decoded = jsonDecode(stored) as Map<String, dynamic>;
      expect(decoded.keys, contains('mgnacg'));

      final reloaded = PluginPlaybackStats(reader: () => stored);
      expect(reloaded.recordOf('mgnacg')!.avgLoadMs, 1200);
      expect(reloaded.score('mgnacg'), stats.score('mgnacg'));
    });

    test('ignores corrupt stored data', () {
      final stats = newStats(initial: 'not json');
      expect(stats.recordOf('a'), isNull);
      expect(stats.score('a'), greaterThan(0));
    });
  });

  group('pickBestSearchItem', () {
    SearchItem item(String name) => SearchItem(name: name, src: '/$name');

    test('prefers an exact title match', () {
      final results = [
        item('我的英雄学院 第六季'),
        item('我的英雄学院 第七季'),
      ];
      final best = pickBestSearchItem(results, ['我的英雄学院第七季']);
      expect(best!.name, '我的英雄学院 第七季');
    });

    test('matches aliases and ignores punctuation', () {
      final results = [item('其他动画'), item('My Hero Academia: Season 7')];
      final best = pickBestSearchItem(
        results,
        ['我的英雄学院 第七季', 'My Hero Academia Season 7'],
      );
      expect(best!.name, 'My Hero Academia: Season 7');
    });

    test('falls back to a containing title, then the first result', () {
      expect(
        pickBestSearchItem(
          [item('别的'), item('葬送的芙莉莲 TV版')],
          ['葬送的芙莉莲'],
        )!
            .name,
        '葬送的芙莉莲 TV版',
      );
      expect(pickBestSearchItem([item('A'), item('B')], ['C'])!.name, 'A');
      expect(pickBestSearchItem([], ['C']), isNull);
    });
  });
}
