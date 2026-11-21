/// 中日文字符（含全角符号）
const String _cjk = r'぀-ヿ㐀-鿿豈-﫿＀-￯';

final RegExp _spaceNextToCjk = RegExp('(?<=[$_cjk])\\s+|\\s+(?=[$_cjk])');

const String _cnDigits = '零一二两三四五六七八九十';

final RegExp _seasonMarker = RegExp(
  '(?<=\\S)(第\\s*[0-9$_cnDigits]+\\s*[季期部章篇]|season\\s*\\d+)',
  caseSensitive: false,
);

/// 季数写法：第二季 / 第2期 / Season 2 / 2nd Season
final RegExp _seasonPattern = RegExp(
  '第\\s*([0-9$_cnDigits]+)\\s*[季期部]'
  r'|season\s*(\d+)'
  r'|(\d+)\s*(?:st|nd|rd|th)\s*season',
  caseSensitive: false,
);

/// 季数和它后面的内容，去掉后得到番剧的基本名字
final RegExp _seasonSuffix = RegExp(
  '[\\s:：\\-–—]*(第\\s*[0-9$_cnDigits]+\\s*[季期部章篇]'
  r'|season\s*\d+|\d+\s*(?:st|nd|rd|th)\s*season).*$',
  caseSensitive: false,
);

/// 把 “二”“十二”“二十” 这样的中文数字转成整数，不认识时返回 null
int? _parseChineseNumber(String text) {
  const values = {
    '零': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4,
    '五': 5, '六': 6, '七': 7, '八': 8, '九': 9,
  };
  if (text.isEmpty) return null;
  final ten = text.indexOf('十');
  if (ten < 0) {
    return text.length == 1 ? values[text] : null;
  }
  final tens = ten == 0 ? 1 : values[text.substring(0, ten)];
  final rest = text.substring(ten + 1);
  final ones = rest.isEmpty ? 0 : values[rest];
  if (tens == null || ones == null || ten > 1 || rest.length > 1) return null;
  return tens * 10 + ones;
}

const List<String> _cnNumbers = [
  '零', '一', '二', '三', '四', '五', '六', '七', '八', '九', '十',
];

String _toChineseNumber(int n) {
  if (n <= 10) return _cnNumbers[n];
  if (n < 20) return '十${_cnNumbers[n - 10]}';
  final ones = n % 10;
  return '${_cnNumbers[n ~/ 10]}十${ones == 0 ? '' : _cnNumbers[ones]}';
}

/// 从标题中读出第几季；没有写季数时返回 null
int? seasonNumberOf(String title) {
  final match = _seasonPattern.firstMatch(title);
  if (match == null) return null;
  final cn = match.group(1);
  if (cn != null) {
    return int.tryParse(cn) ?? _parseChineseNumber(cn);
  }
  return int.tryParse(match.group(2) ?? match.group(3) ?? '');
}

/// 去掉季数及其后面的内容：“我的英雄学院 第二季” → “我的英雄学院”
String baseTitleOf(String title) => title.replaceAll(_seasonSuffix, '').trim();

/// 第二季 ↔ 第2季
String _swapSeasonNumerals(String keyword) {
  return keyword.replaceAllMapped(
    RegExp('第(\\s*)([0-9]+|[$_cnDigits]+)(\\s*[季期部])'),
    (m) {
      final raw = m[2]!;
      final arabic = int.tryParse(raw);
      final converted = arabic != null
          ? (arabic > 0 && arabic < 100 ? _toChineseNumber(arabic) : raw)
          : (_parseChineseNumber(raw)?.toString() ?? raw);
      return '第${m[1]}$converted${m[3]}';
    },
  );
}

/// 同一个关键词的其他写法，用于规则搜索没有结果时依次重试
///
/// 各站点给番剧起名的习惯不同，而很多站点的搜索是逐字匹配的。
/// 返回的列表不包含 [keyword] 本身，也没有重复项，按顺序为：
/// 1. 去掉中日文旁边的空格：“我的英雄学院 第二季” → “我的英雄学院第二季”
/// 2. 在季数前补一个空格：“我的英雄学院第二季” → “我的英雄学院 第二季”
/// 3. 换一种季数写法：“第二季” ↔ “第2季”
/// 4. 只搜番剧的基本名字：“我的英雄学院”（结果会包含其他季，
///    调用方可以用 [sortBySeason] 把对应的季排到前面）
List<String> searchKeywordVariants(String keyword) {
  final original = keyword.trim();
  final normalized = original.replaceAll(RegExp(r'\s+'), ' ');
  final noSpace = normalized.replaceAll(_spaceNextToCjk, '');
  final candidates = [
    noSpace,
    normalized.replaceAllMapped(_seasonMarker, (m) => ' ${m[0]}'),
    _swapSeasonNumerals(noSpace),
    if (seasonNumberOf(normalized) != null) baseTitleOf(normalized),
  ];
  final seen = <String>{original, keyword};
  return [
    for (final candidate in candidates)
      if (candidate.runes.length >= 2 && seen.add(candidate)) candidate,
  ];
}

/// 把和 [keyword] 同一季的结果排到前面，其他结果保持原有顺序
///
/// [keyword] 没有写季数时按第 1 季处理，标题没写季数的结果也算第 1 季。
List<T> sortBySeason<T>(
  List<T> items,
  String keyword,
  String Function(T item) nameOf,
) {
  final wanted = seasonNumberOf(keyword) ?? 1;
  final matching = <T>[];
  final others = <T>[];
  for (final item in items) {
    ((seasonNumberOf(nameOf(item)) ?? 1) == wanted ? matching : others)
        .add(item);
  }
  return [...matching, ...others];
}
