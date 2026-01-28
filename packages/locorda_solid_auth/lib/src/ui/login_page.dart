import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:solid_auth/solid_auth.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/solid_auth_localizations.dart';
import '../providers/solid_provider_service.dart';

final _log = Logger('SolidLoginScreen');

/// A ready-to-use Solid login screen widget.
///
/// This widget provides a complete login interface for Solid authentication,
/// including provider selection and manual WebID entry.
class SolidLoginScreen extends StatefulWidget {
  /// The SolidAuth instance to use for authentication.
  final SolidAuth solidAuth;

  /// Service for managing Solid providers and registration URLs.
  final SolidProviderService providerService;

  /// Callback called when login succeeds with user information.
  final void Function(UserAndWebId userInfo)? onLoginSuccess;

  /// Callback called when login fails.
  final void Function(String error)? onLoginError;

  /// Optional additional OIDC scopes to request during authentication - usually not needed.
  final List<String> extraOidcScopes;

  const SolidLoginScreen({
    super.key,
    required this.solidAuth,
    required this.providerService,
    this.onLoginSuccess,
    this.onLoginError,
    this.extraOidcScopes = const [],
  });

  @override
  State<SolidLoginScreen> createState() => _SolidLoginScreenState();
}

class _SolidLoginScreenState extends State<SolidLoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _webIdController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;

  List<SolidProvider> get _providers => widget.providerService.getProviders();

  Future<void> _login(String input) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final userInfo = await widget.solidAuth.authenticate(
        input.trim(),
        scopes: widget.extraOidcScopes,
      );

      if (!mounted) return;

      widget.onLoginSuccess?.call(userInfo);

      // Close login screen and signal success
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e, stackTrace) {
      _log.severe('Authentication failed', e, stackTrace);
      if (!mounted) return;
      final error = SolidAuthLocalizations.of(context)!
          .errorConnectingSolid(e.toString());
      setState(() {
        _errorMessage = error;
      });
      widget.onLoginError?.call(error);
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = SolidAuthLocalizations.of(context)!;
    final screenWidth = MediaQuery.of(context).size.width;
    final isWideScreen = screenWidth > 600;

    Widget loginContent = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Icons.cloud_sync_rounded, size: 48, color: colorScheme.primary),
        const SizedBox(height: 16),
        Text(
          l10n.syncAcrossDevices,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 32),

        // Provider selection buttons
        if (_providers.isNotEmpty) ...[
          Text(
            l10n.chooseProvider,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 8),
          ..._providers.map(
            (provider) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: ElevatedButton(
                onPressed: _isLoading ? null : () => _login(provider.url),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  backgroundColor: colorScheme.surfaceContainerHighest,
                ),
                child: Text(provider.name),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Divider(),
          ),
        ],

        // Manual WebID input
        Text(
          l10n.orEnterManually,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 8),
        Form(
          key: _formKey,
          child: TextFormField(
            controller: _webIdController,
            decoration: InputDecoration(
              hintText: l10n.webIdHint,
              errorText: _errorMessage,
              errorMaxLines: 2,
            ),
            enabled: !_isLoading,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.go,
            onFieldSubmitted: (value) => _login(value),
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return SolidAuthLocalizations.of(context)!.pleaseEnterWebId;
              }
              return null;
            },
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _isLoading
              ? null
              : () {
                  if (_formKey.currentState!.validate()) {
                    _login(_webIdController.text);
                  }
                },
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
          child: _isLoading
              ? const SizedBox(
                  height: 24,
                  width: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                )
              : Text(l10n.connect),
        ),

        // "Get a Pod" section
        const SizedBox(height: 24),
        Text(
          l10n.noPod,
          style: Theme.of(context).textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
        TextButton(
          onPressed: () async {
            final url = widget.providerService.getNewPodUrl();
            final uri = Uri.parse(url);
            if (await canLaunchUrl(uri)) {
              await launchUrl(uri);
            }
          },
          child: Text(l10n.getPod),
        ),
      ],
    );

    // For wider screens, wrap the content in a constrained box
    if (isWideScreen) {
      loginContent = Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Card(
            elevation: 4,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: loginContent,
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          l10n.connectToSolid,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.symmetric(
          horizontal: isWideScreen ? 24 : 16,
          vertical: 24,
        ),
        child: loginContent,
      ),
    );
  }

  @override
  void dispose() {
    _webIdController.dispose();
    super.dispose();
  }
}
