import 'dart:io';

import 'package:flutter/foundation.dart';

/// Phones and tablets: share sheets instead of "open with", no hover, no key hints.
bool get kTouch => debugTouchOverride ?? _touchPlatform;

final bool _touchPlatform = Platform.isIOS || Platform.isAndroid;

/// Tests set this to get the phone behaviour on a desktop host.
@visibleForTesting
bool? debugTouchOverride;
