import 'package:flutter/material.dart';

/// F1 · Editor. Palette after One Dark / One Light; IBM Plex Sans for UI, Plex Mono for data.
class Scheme extends ThemeExtension<Scheme> {
  const Scheme({
    required this.brightness,
    required this.bg,
    required this.bg2,
    required this.panel,
    required this.raised,
    required this.hover,
    required this.selected,
    required this.border,
    required this.fg,
    required this.fg2,
    required this.fg3,
    required this.blue,
    required this.green,
    required this.yellow,
    required this.red,
    required this.purple,
    required this.cyan,
  });

  final Brightness brightness;
  final Color bg; // list + reading
  final Color bg2; // top bar, sidebar, status bar
  final Color panel; // fields
  final Color raised; // selected sidebar row, chips, buttons
  final Color hover;
  final Color selected; // selected thread row
  final Color border;
  final Color fg;
  final Color fg2;
  final Color fg3;
  final Color blue;
  final Color green;
  final Color yellow;
  final Color red;
  final Color purple;
  final Color cyan;

  Color get accent => blue;

  static const dark = Scheme(
    brightness: Brightness.dark,
    bg: Color(0xFF16181D),
    bg2: Color(0xFF1B1E24),
    panel: Color(0xFF191C22),
    raised: Color(0xFF22262E),
    hover: Color(0xFF1C1F26),
    selected: Color(0xFF232A3C),
    border: Color(0xFF262A31),
    fg: Color(0xFFD7DAE0),
    fg2: Color(0xFF8B93A1),
    fg3: Color(0xFF5F6673),
    blue: Color(0xFF74ADE8),
    green: Color(0xFFA1C181),
    yellow: Color(0xFFDFC184),
    red: Color(0xFFD07277),
    purple: Color(0xFFB477CF),
    cyan: Color(0xFF6FB3C9),
  );

  static const light = Scheme(
    brightness: Brightness.light,
    bg: Color(0xFFFAFAFA),
    bg2: Color(0xFFF0F0F1),
    panel: Color(0xFFFFFFFF),
    raised: Color(0xFFE5E5E6),
    hover: Color(0xFFF2F2F3),
    selected: Color(0xFFDCE6F7),
    border: Color(0xFFE1E1E3),
    fg: Color(0xFF383A42),
    fg2: Color(0xFF696C77),
    fg3: Color(0xFFA0A1A7),
    blue: Color(0xFF4078F2),
    green: Color(0xFF50A14F),
    yellow: Color(0xFFC18401),
    red: Color(0xFFE45649),
    purple: Color(0xFFA626A4),
    cyan: Color(0xFF0184BC),
  );

  bool get isDark => brightness == Brightness.dark;

  /// Label / account colors by name, so the same tag looks the same everywhere.
  Color tagColor(String name) => switch (name) {
    'ci' => cyan,
    'work' => blue,
    'invoices' => yellow,
    'personal' => purple,
    _ => fg2,
  };

  @override
  Scheme copyWith() => this;

  @override
  Scheme lerp(ThemeExtension<Scheme>? other, double t) =>
      t < 0.5 ? this : (other as Scheme? ?? this);
}

extension SchemeContext on BuildContext {
  Scheme get s => Theme.of(this).extension<Scheme>() ?? Scheme.dark;
}

const kSans = 'IBM Plex Sans';
const kMono = 'IBM Plex Mono';

/// Interface text: IBM Plex Sans (bundled, variable weight).
TextStyle ui(
  BuildContext context, {
  double size = 13,
  FontWeight weight = FontWeight.w400,
  Color? color,
  double height = 1.45,
  double? letterSpacing,
}) => TextStyle(
  fontFamily: kSans,
  fontSize: size,
  fontWeight: weight,
  // The bundled Sans is a variable font: fontWeight picks nothing by itself, the
  // wght axis does.
  fontVariations: [FontVariation.weight(weight.value.toDouble())],
  color: color ?? context.s.fg,
  height: height,
  letterSpacing: letterSpacing,
);

/// Data text: IBM Plex Mono with tabular figures (times, counts, keys, headers).
TextStyle mono(
  BuildContext context, {
  double size = 11.5,
  FontWeight weight = FontWeight.w400,
  Color? color,
  double height = 1.45,
  double? letterSpacing,
}) => TextStyle(
  fontFamily: kMono,
  fontSize: size,
  fontWeight: weight,
  color: color ?? context.s.fg2,
  height: height,
  letterSpacing: letterSpacing,
  fontFeatures: const [FontFeature.tabularFigures()],
);

ThemeData buildTheme(Scheme s) {
  final base = ThemeData(brightness: s.brightness, useMaterial3: true);
  return base.copyWith(
    extensions: [s],
    scaffoldBackgroundColor: s.bg,
    canvasColor: s.bg,
    colorScheme: base.colorScheme.copyWith(
      primary: s.blue,
      onPrimary: s.bg,
      surface: s.bg,
      onSurface: s.fg,
      outline: s.border,
    ),
    textTheme: base.textTheme.apply(
      fontFamily: kSans,
      bodyColor: s.fg,
      displayColor: s.fg,
    ),
    splashFactory: NoSplash.splashFactory,
    hoverColor: s.hover,
    dividerColor: s.border,
    iconTheme: IconThemeData(color: s.fg2, size: 15),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: s.fg,
      selectionColor: s.blue.withValues(alpha: 0.3),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: s.raised,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: s.border),
      ),
      textStyle: TextStyle(fontFamily: kSans, fontSize: 12, color: s.fg),
      waitDuration: const Duration(milliseconds: 500),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.all(s.fg3.withValues(alpha: 0.5)),
      thickness: WidgetStateProperty.all(5),
      radius: const Radius.circular(3),
    ),
  );
}
