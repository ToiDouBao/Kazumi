/// 中日文字符（含全角符号）
const String _cjk = r'぀-ヿ㐀-鿿豈-﫿＀-￯';

final RegExp _spaceNextToCjk = RegExp('(?<=[$_cjk])\\s+|\\s+(?=[$_cjk])');

final RegExp _seasonMarker = RegExp(
  r'(?<=\S)(第\s*[0-9一二三四五六七八九十]+\s*[季期部章篇]|season\s*\d+)',
  caseSensitive: false,
);

/// 同一个关键词的其他空格写法，用于规则搜索没有结果时重试
///
/// 各站点给番剧起名的空格习惯不同，例如 “我的英雄学院 第二季” 和
/// “我的英雄学院第二季”，而很多站点的搜索是逐字匹配的。返回的列表不包含
/// [keyword] 本身，也没有重复项：
/// 1. 去掉中日文旁边的空格：“我的英雄学院 第二季” → “我的英雄学院第二季”
/// 2. 在季数前补一个空格：“我的英雄学院第二季” → “我的英雄学院 第二季”
List<String> searchKeywordVariants(String keyword) {
  final original = keyword.trim();
  final normalized = original.replaceAll(RegExp(r'\s+'), ' ');
  final candidates = [
    normalized.replaceAll(_spaceNextToCjk, ''),
    normalized.replaceAllMapped(_seasonMarker, (m) => ' ${m[0]}'),
  ];
  final seen = <String>{original, keyword};
  return [
    for (final candidate in candidates)
      if (candidate.isNotEmpty && seen.add(candidate)) candidate,
  ];
}
