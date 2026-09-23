import 'dart:io';

import 'package:flutter/widgets.dart';

/// Phones and tablets: share sheets instead of "open with", no hover, no key hints.
bool get kTouch => debugTouchOverride ?? _touchPlatform;

final bool _touchPlatform = Platform.isIOS || Platform.isAndroid;

/// Tests set this to get the phone behaviour on a desktop host.
@visibleForTesting
bool? debugTouchOverride;

/// A phone: touch and a short side under 600 (in landscape too). Tablets are not phones:
/// they keep the editor layout.
bool isPhone(BuildContext context) =>
    kTouch && MediaQuery.sizeOf(context).shortestSide < 600;
