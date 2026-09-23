import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
    required this.accentStrong,
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

  /// The accent where it fills a button or colours a text button on a phone: dark keeps
  /// One Dark's blue; light needs a deeper one to read at 4.5:1 on the page.
  final Color accentStrong;

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
    accentStrong: Color(0xFF74ADE8),
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
    accentStrong: Color(0xFF2F5FCC),
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

/// Sizes for fingers (phones and tablets): one target size everywhere.
abstract final class Touch {
  static const target = 48.0;
  static const appBar = 56.0;
  static const bottomBar = 56.0;
  static const row = 48.0;
  static const threadRow = 76.0;
  static const button = 50.0;
  static const radius = 8.0;
  static const sheetRadius = 12.0;
  static const gutter = 16.0;
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
    // Every screen's bar: flat on the page, the system bars' icons readable on it.
    appBarTheme: AppBarTheme(
      backgroundColor: s.bg,
      foregroundColor: s.fg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      iconTheme: IconThemeData(color: s.fg, size: 24),
      actionsIconTheme: IconThemeData(color: s.fg, size: 24),
      titleTextStyle: TextStyle(
        fontFamily: kSans,
        fontSize: 17,
        fontWeight: FontWeight.w600,
        fontVariations: const [FontVariation.weight(600)],
        color: s.fg,
      ),
      systemOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: s.isDark ? Brightness.light : Brightness.dark,
        statusBarBrightness: s.brightness,
        systemNavigationBarColor: s.bg2,
        systemNavigationBarIconBrightness: s.isDark
            ? Brightness.light
            : Brightness.dark,
      ),
    ),
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
    // Menus, sheets, buttons and notices on phones: the same quiet surfaces as the rest.
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(s.bg2),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(6),
        shadowColor: WidgetStatePropertyAll(
          Colors.black.withValues(alpha: s.isDark ? 0.5 : 0.3),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: 6),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: s.border),
          ),
        ),
      ),
    ),
    menuButtonTheme: MenuButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(180, Touch.row)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 16),
        ),
        foregroundColor: WidgetStatePropertyAll(s.fg),
        iconColor: WidgetStatePropertyAll(s.fg2),
        iconSize: const WidgetStatePropertyAll(20),
        overlayColor: WidgetStatePropertyAll(s.hover),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(fontFamily: kSans, fontSize: 16),
        ),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: s.bg2,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: s.bg2,
      modalBarrierColor: Colors.black.withValues(alpha: 0.25),
      dragHandleColor: s.border,
      dragHandleSize: const Size(36, 4),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(Touch.sheetRadius),
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: s.accentStrong,
        foregroundColor: s.bg,
        disabledBackgroundColor: s.raised,
        disabledForegroundColor: s.fg3,
        minimumSize: const Size(48, Touch.target),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Touch.radius),
        ),
        textStyle: const TextStyle(
          fontFamily: kSans,
          fontSize: 15,
          fontWeight: FontWeight.w600,
          fontVariations: [FontVariation.weight(600)],
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: s.accentStrong,
        minimumSize: const Size(48, Touch.target),
        textStyle: const TextStyle(
          fontFamily: kSans,
          fontSize: 15,
          fontWeight: FontWeight.w500,
          fontVariations: [FontVariation.weight(500)],
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: s.fg,
        side: BorderSide(color: s.border),
        minimumSize: const Size(48, Touch.target),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Touch.radius),
        ),
        textStyle: const TextStyle(
          fontFamily: kSans,
          fontSize: 15,
          fontWeight: FontWeight.w500,
          fontVariations: [FontVariation.weight(500)],
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.fixed,
      backgroundColor: s.raised,
      elevation: 0,
      shape: Border(top: BorderSide(color: s.border)),
      contentTextStyle: TextStyle(fontFamily: kSans, fontSize: 14, color: s.fg),
      actionTextColor: s.accentStrong,
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
      },
    ),
  );
}
