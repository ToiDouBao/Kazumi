import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/utils/search_keyword.dart';

void main() {
  group('searchKeywordVariants', () {
    test('tries without spaces, other numerals, then the base title', () {
      expect(searchKeywordVariants('我的英雄学院 第二季'), [
        '我的英雄学院第二季',
        '我的英雄学院第2季',
        '我的英雄学院',
      ]);
    });

    test('adds a space before the season', () {
      expect(searchKeywordVariants('我的英雄学院第二季'), [
        '我的英雄学院 第二季',
        '我的英雄学院第2季',
        '我的英雄学院',
      ]);
      expect(searchKeywordVariants('进击的巨人第3季'), [
        '进击的巨人 第3季',
        '进击的巨人第三季',
        '进击的巨人',
      ]);
    });

    test('handles full-width spaces and mixed titles', () {
      expect(searchKeywordVariants('我的英雄学院　第二季'), [
        '我的英雄学院第二季',
        '我的英雄学院 第二季',
        '我的英雄学院第2季',
        '我的英雄学院',
      ]);
      expect(searchKeywordVariants('SPY×FAMILY 第二季'), [
        'SPY×FAMILY第二季',
        'SPY×FAMILY第2季',
        'SPY×FAMILY',
      ]);
    });

    test('keeps spaces between Latin words', () {
      expect(searchKeywordVariants('Fate stay night'), isEmpty);
      expect(
        searchKeywordVariants('My Hero Academia Season 2'),
        ['My Hero Academia'],
      );
    });

    test('returns nothing when there is no other spelling', () {
      expect(searchKeywordVariants('葬送的芙莉莲'), isEmpty);
      expect(searchKeywordVariants('我的英雄学院'), isEmpty);
      expect(searchKeywordVariants(''), isEmpty);
    });
  });

  test('seasonNumberOf reads common season formats', () {
    expect(seasonNumberOf('我的英雄学院 第二季'), 2);
    expect(seasonNumberOf('我的英雄学院第7季'), 7);
    expect(seasonNumberOf('僕のヒーローアカデミア 第7期'), 7);
    expect(seasonNumberOf('某番 第十二季'), 12);
    expect(seasonNumberOf('某番 第二十季'), 20);
    expect(seasonNumberOf('My Hero Academia Season 3'), 3);
    expect(seasonNumberOf('Attack on Titan 2nd Season'), 2);
    expect(seasonNumberOf('我的英雄学院'), isNull);
  });

  test('baseTitleOf drops the season and anything after it', () {
    expect(baseTitleOf('我的英雄学院 第二季'), '我的英雄学院');
    expect(baseTitleOf('Re:从零开始的异世界生活 第三季 后半'), 'Re:从零开始的异世界生活');
    expect(baseTitleOf('葬送的芙莉莲'), '葬送的芙莉莲');
  });

  test('sortBySeason puts the wanted season first', () {
    final names = [
      '我的英雄学院第四季',
      '我的英雄学院：两位英雄',
      '我的英雄学院第2季',
      '我的英雄学院第二季 OVA',
    ];
    expect(sortBySeason(names, '我的英雄学院 第二季', (n) => n), [
      '我的英雄学院第2季',
      '我的英雄学院第二季 OVA',
      '我的英雄学院第四季',
      '我的英雄学院：两位英雄',
    ]);
  });
}
