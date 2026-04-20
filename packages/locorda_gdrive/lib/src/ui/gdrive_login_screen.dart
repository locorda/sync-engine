/// Google Drive login screen.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_gdrive/locorda_gdrive.dart';
import 'package:logging/logging.dart';

import 'gdrive_web_sign_in_button.dart'
    if (dart.library.html) 'gdrive_web_sign_in_button_web.dart';

final _log = Logger('GDriveLoginScreen');

/// Full-screen login UI for Google Drive authentication.
///
/// On web, authentication is a two-step flow to comply with Google's GIS
/// branding requirements and browser popup policies:
/// 1. User clicks the official GIS button to authenticate their Google identity.
/// 2. User clicks the "Authorize Drive Access" button (a regular Flutter button
///    in a user-gesture context) to grant the Drive appdata scope.
///
/// On native platforms, [onSignIn] handles both steps atomically.
///
/// ## Parameters
///
/// - [onSignIn]: Called on native platforms to run the full auth flow.
/// - [isAuthenticatedNotifier]: Listenable that signals GIS button success on
///   web, advancing the screen to step 2. Supply [GDriveAuth.isAuthenticatedNotifier].
/// - [onAuthorizeScopes]: Called on web step 2 from a button's `onPressed`,
///   ensuring the popup is in a user-gesture context. Supply
///   [GDriveAuth.authorizeInteractively].
typedef GDriveSignInCallback = Future<bool> Function();

class GDriveLoginScreen extends StatefulWidget {
  final GDriveSignInCallback onSignIn;

  /// Listenable for auth state changes — used on web to detect when the GIS
  /// button completes step 1 and reveal the step-2 authorize button.
  final AuthValueListenable? isAuthenticatedNotifier;

  /// Called on web when the user taps the "Authorize Drive Access" button.
  /// Must be invoked directly from an `onPressed` handler so the browser
  /// treats it as a user gesture, allowing the GIS popup to open.
  final Future<bool> Function()? onAuthorizeScopes;

  const GDriveLoginScreen({
    super.key,
    required this.onSignIn,
    this.isAuthenticatedNotifier,
    this.onAuthorizeScopes,
  });

  @override
  State<GDriveLoginScreen> createState() => _GDriveLoginScreenState();
}

class _GDriveLoginScreenState extends State<GDriveLoginScreen> {
  bool _isConnecting = false;
  String? _errorMessage;

  /// On web: true once the GIS button completes step 1 (Google identity auth).
  /// Acts as a one-way ratchet — never reset to false once set, to avoid
  /// flickering caused by [GDriveAuth._markUserInteractionRequired] temporarily
  /// setting the notifier back to false while checking for cached scopes.
  bool _isSignedIn = false;

  @override
  void initState() {
    super.initState();
    widget.isAuthenticatedNotifier?.addListener(_onAuthStateChanged);
  }

  @override
  void dispose() {
    widget.isAuthenticatedNotifier?.removeListener(_onAuthStateChanged);
    super.dispose();
  }

  void _onAuthStateChanged() {
    if (widget.isAuthenticatedNotifier?.isAuthenticated == true && !_isSignedIn) {
      setState(() => _isSignedIn = true);
    }
  }

  Future<void> _handleSignIn() async {
    setState(() {
      _isConnecting = true;
      _errorMessage = null;
    });

    try {
      final success = await widget.onSignIn();

      if (!mounted) return;

      if (success) {
        Navigator.of(context).pop(true);
      } else {
        setState(() {
          _errorMessage = 'Authentication failed';
          _isConnecting = false;
        });
      }
    } catch (e, stackTrace) {
      _log.severe('Error during Google Drive authentication', e, stackTrace);
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
          _isConnecting = false;
        });
      }
    }
  }

  Future<void> _handleAuthorize() async {
    setState(() {
      _isConnecting = true;
      _errorMessage = null;
    });

    try {
      final success = await widget.onAuthorizeScopes!();

      if (!mounted) return;

      if (success) {
        Navigator.of(context).pop(true);
      } else {
        setState(() {
          _errorMessage = 'Drive authorization failed';
          _isConnecting = false;
        });
      }
    } catch (e, stackTrace) {
      _log.severe('Error during Drive scope authorization', e, stackTrace);
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
          _isConnecting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = GDriveLocalizations.of(context)!;
    final theme = Theme.of(context);

    // On web after step 1, switch the description and show the authorize button.
    final isWebStep2 = kIsWeb && _isSignedIn;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.connectToGoogleDrive),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(
                Icons.cloud,
                size: 80,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 32),
              Text(
                l10n.connectToGoogleDrive,
                style: theme.textTheme.headlineMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Text(
                isWebStep2
                    ? l10n.authorizeDriveAccessDescription
                    : l10n.syncAcrossDevices,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              if (!isWebStep2) ...[
                const SizedBox(height: 16),
                Text(
                  l10n.dataPrivacyNotice,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 48),
              if (_errorMessage != null) ...[
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    l10n.errorConnectingGoogleDrive(_errorMessage!),
                    style: TextStyle(color: theme.colorScheme.onErrorContainer),
                  ),
                ),
                const SizedBox(height: 24),
              ],
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 140,
                    child: OutlinedButton(
                      onPressed: _isConnecting
                          ? null
                          : () => Navigator.of(context).pop(false),
                      child: Text(l10n.cancel),
                    ),
                  ),
                  const SizedBox(width: 16),
                  if (isWebStep2)
                    SizedBox(
                      width: 280,
                      child: FilledButton.icon(
                        onPressed: _isConnecting ? null : _handleAuthorize,
                        icon: _isConnecting
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2),
                              )
                            : const Icon(Icons.lock_open),
                        label: Text(l10n.authorizeDriveAccess),
                      ),
                    )
                  else if (kIsWeb)
                    renderGDriveWebSignInButton()
                  else
                    SizedBox(
                      width: 280,
                      child: FilledButton.icon(
                        onPressed: _isConnecting ? null : _handleSignIn,
                        icon: _isConnecting
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2),
                              )
                            : const Icon(Icons.login),
                        label: Text(l10n.signInWithGoogle),
                      ),
                    ),
                ],
              )
            ],
          ),
        ),
      ),
    );
  }
}
