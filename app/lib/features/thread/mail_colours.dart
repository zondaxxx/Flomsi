/// Colours as mail writes them (`bgcolor="#111"`, `style="background-color: navy"`), read
/// only as far as the reading pane needs: to paint an old `bgcolor` and to tell a dark
/// fill from a light one.
library;

/// A colour from an HTML attribute: `#hex`, bare hex digits (old mail), or a keyword.
/// Null for anything else.
String? htmlColour(String? v) {
  final c = v?.trim();
  if (c == null || c.isEmpty) return null;
  if (RegExp(r'^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$')
      .hasMatch(c)) {
    return c.toLowerCase();
  }
  if (RegExp(r'^([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$').hasMatch(c)) {
    return '#${c.toLowerCase()}';
  }
  if (RegExp(r'^[a-zA-Z]+$').hasMatch(c)) return c.toLowerCase();
  return null;
}

/// The value of [property] in an inline `style`, or null. `background` counts for
/// `background-color` (the sanitizer keeps only its colour).
String? styleValue(String? style, String property) {
  if (style == null) return null;
  for (final decl in style.split(';')) {
    final i = decl.indexOf(':');
    if (i < 0) continue;
    final key = decl.substring(0, i).trim().toLowerCase();
    final value = decl.substring(i + 1).trim();
    if (value.isEmpty) continue;
    if (key == property ||
        (property == 'background-color' && key == 'background')) {
      return value;
    }
  }
  return null;
}

const _named = {
  'black': 0x000000,
  'navy': 0x000080,
  'darkblue': 0x00008b,
  'mediumblue': 0x0000cd,
  'darkgreen': 0x006400,
  'green': 0x008000,
  'teal': 0x008080,
  'darkcyan': 0x008b8b,
  'midnightblue': 0x191970,
  'darkslategray': 0x2f4f4f,
  'darkslategrey': 0x2f4f4f,
  'indigo': 0x4b0082,
  'maroon': 0x800000,
  'purple': 0x800080,
  'olive': 0x808000,
  'darkred': 0x8b0000,
  'darkmagenta': 0x8b008b,
  'dimgray': 0x696969,
  'dimgrey': 0x696969,
  'gray': 0x808080,
  'grey': 0x808080,
  'brown': 0xa52a2a,
  'firebrick': 0xb22222,
  'red': 0xff0000,
  'blue': 0x0000ff,
  'white': 0xffffff,
  'silver': 0xc0c0c0,
  'yellow': 0xffff00,
};

/// True when text in the default dark ink would be hard to read on [colour]. Unknown
/// colours count as light, which leaves them as they were.
bool isDarkColour(String colour) {
  final c = colour.trim().toLowerCase();
  int? rgb;
  final hex = RegExp(r'^#([0-9a-f]{3,8})$').firstMatch(c)?.group(1);
  if (hex != null) {
    final full = switch (hex.length) {
      3 || 4 => hex.substring(0, 3).split('').map((d) => '$d$d').join(),
      6 || 8 => hex.substring(0, 6),
      _ => null,
    };
    if (full != null) rgb = int.tryParse(full, radix: 16);
  } else if (c.startsWith('rgb')) {
    final parts = RegExp(r'[\d.]+')
        .allMatches(c)
        .take(3)
        .map((m) => double.tryParse(m.group(0)!) ?? 0)
        .toList();
    if (parts.length == 3) {
      rgb =
          (parts[0].clamp(0, 255).round() << 16) |
          (parts[1].clamp(0, 255).round() << 8) |
          parts[2].clamp(0, 255).round();
    }
  } else {
    rgb = _named[c];
  }
  if (rgb == null) return false;
  final r = (rgb >> 16) & 0xff, g = (rgb >> 8) & 0xff, b = rgb & 0xff;
  return 0.299 * r + 0.587 * g + 0.114 * b < 110;
}
