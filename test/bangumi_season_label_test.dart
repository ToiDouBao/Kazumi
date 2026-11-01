import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/bangumi_tag.dart';

BangumiItem _item({
  String airDate = '2016-04-03',
  String platform = '',
  int totalEpisodes = 0,
  List<BangumiTag> tags = const [],
}) {
  return BangumiItem(
    id: 1,
    type: 2,
    name: '僕のヒーローアカデミア',
    nameCn: '我的英雄学院',
    summary: '',
    airDate: airDate,
    airWeekday: 7,
    rank: 0,
    images: const {},
    tags: tags,
    alias: const [],
    ratingScore: 0,
    votes: 0,
    votesCount: const [],
    info: '',
    platform: platform,
    totalEpisodes: totalEpisodes,
  );
}

void main() {
  group('BangumiItem.seasonLabel', () {
    test('shows year, format and episode count', () {
      expect(
        _item(platform: 'TV', totalEpisodes: 13).seasonLabel,
        '2016 · TV · 13话',
      );
    });

    test('omits episode count for movies', () {
      expect(
        _item(airDate: '2018-08-03', platform: '剧场版', totalEpisodes: 1)
            .seasonLabel,
        '2018 · 剧场版',
      );
    });

    test('infers format from tags when platform is missing', () {
      final item = _item(
        tags: [BangumiTag(name: 'OVA', count: 10, totalCount: 10)],
      );
      expect(item.seasonLabel, '2016 · OVA');
    });

    test('falls back to the year or nothing', () {
      expect(_item().seasonLabel, '2016');
      expect(_item(airDate: '').seasonLabel, '');
    });
  });
}
