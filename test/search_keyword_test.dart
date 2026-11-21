import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/utils/search_keyword.dart';

void main() {
  group('searchKeywordVariants', () {
    test('removes spaces between Chinese words', () {
      expect(searchKeywordVariants('我的英雄学院 第二季'), ['我的英雄学院第二季']);
    });

    test('adds a space before the season', () {
      expect(searchKeywordVariants('我的英雄学院第二季'), ['我的英雄学院 第二季']);
      expect(searchKeywordVariants('进击的巨人第3季'), ['进击的巨人 第3季']);
      expect(searchKeywordVariants('魔法少女小圆 第一部'), ['魔法少女小圆第一部']);
    });

    test('handles full-width spaces and mixed titles', () {
      expect(
        searchKeywordVariants('我的英雄学院　第二季'),
        ['我的英雄学院第二季', '我的英雄学院 第二季'],
      );
      expect(
        searchKeywordVariants('Re:从零开始的异世界生活 第三季'),
        ['Re:从零开始的异世界生活第三季'],
      );
      expect(searchKeywordVariants('SPY×FAMILY 第二季'), ['SPY×FAMILY第二季']);
    });

    test('keeps spaces between Latin words', () {
      expect(searchKeywordVariants('Fate stay night'), isEmpty);
      expect(
        searchKeywordVariants('My Hero Academia Season 2'),
        isEmpty,
      );
      expect(
        searchKeywordVariants('My Hero AcademiaSeason 2'),
        ['My Hero Academia Season 2'],
      );
    });

    test('returns nothing when there is no other spelling', () {
      expect(searchKeywordVariants('葬送的芙莉莲'), isEmpty);
      expect(searchKeywordVariants(''), isEmpty);
    });
  });
}
