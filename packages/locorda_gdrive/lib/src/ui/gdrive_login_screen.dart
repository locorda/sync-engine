/// Google Drive login screen.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:locorda_gdrive/locorda_gdrive.dart';
import 'package:logging/logging.dart';

import 'gdrive_web_sign_in_button.dart'
    if (dart.library.html) 'gdrive_web_sign_in_button_web.dart';

final _log = Logger('GDriveLoginScreen');

/// Full-screen login UI for Google Drive authentication.
///
/// Presents a clean interface for users to:
/// - Sign in with their Google account
/// - Understand why authentication is needed
/// - Cancel if they choose
///
/// Uses [GDriveAuth] to initiate OAuth2 flow.
typedef GDriveSignInCallback = Future<bool> Function();

class GDriveLoginScreen extends StatefulWidget {
  final GDriveSignInCallback onSignIn;

  const GDriveLoginScreen({
    super.key,
    required this.onSignIn,
  });

  @override
  State<GDriveLoginScreen> createState() => _GDriveLoginScreenState();
}

class _GDriveLoginScreenState extends State<GDriveLoginScreen> {
  bool _isConnecting = false;
  String? _errorMessage;

  Future<void> _handleSignIn() async {
    setState(() {
      _isConnecting = true;
      _errorMessage = null;
    });

    try {
      final success = await widget.onSignIn();

      if (!mounted) return;

      if (success) {
        // Close login screen and signal success
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

  @override
  Widget build(BuildContext context) {
    final l10n = GDriveLocalizations.of(context)!;
    final theme = Theme.of(context);

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
                l10n.syncAcrossDevices,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Text(
                l10n.dataPrivacyNotice,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
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
                  if (kIsWeb)
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
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.login),
                        label: Text(l10n.signInWithGoogle),
                      ),
                    )
                ],
              )
            ],
          ),
        ),
      ),
    );
  }
}
