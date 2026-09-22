import 'dart:io';

/// Phones and tablets: share sheets instead of "open with", no hover, no key hints.
final bool kTouch = Platform.isIOS || Platform.isAndroid;
