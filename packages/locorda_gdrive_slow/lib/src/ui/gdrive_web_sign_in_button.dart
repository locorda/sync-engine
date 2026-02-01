import 'package:flutter/widgets.dart';

/// Web sign-in button placeholder for non-web platforms.
///
/// On non-web platforms, Google Sign-In is triggered via the normal
/// app-provided button. This stub avoids importing web-only APIs.
Widget renderGDriveWebSignInButton() => const SizedBox.shrink();
