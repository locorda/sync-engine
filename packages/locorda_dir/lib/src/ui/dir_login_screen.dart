/// Login/setup screen for local directory backend.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

import '../auth/dir_auth.dart';

final _log = Logger('DirLoginScreen');

/// Login/setup screen for local directory sync.
///
/// Explains the feature to users and allows them to enable/disable it.
/// Shows the directory path where files will be synced.
class DirLoginScreen extends StatefulWidget {
  final DirAuth dirAuth;

  const DirLoginScreen({
    super.key,
    required this.dirAuth,
  });

  @override
  State<DirLoginScreen> createState() => _DirLoginScreenState();
}

class _DirLoginScreenState extends State<DirLoginScreen> {
  bool _isLoading = false;
  bool _isEnabled = false;

  @override
  void initState() {
    super.initState();
    _checkStatus();
  }

  Future<void> _checkStatus() async {
    final enabled = await widget.dirAuth.isAuthenticated();
    if (mounted) {
      setState(() {
        _isEnabled = enabled;
      });
    }
  }

  Future<void> _toggleSync() async {
    setState(() {
      _isLoading = true;
    });

    try {
      if (_isEnabled) {
        await widget.dirAuth.disable();
      } else {
        // Before enabling, test directory access
        final hasAccess = await widget.dirAuth.testDirectoryAccess();

        if (!hasAccess) {
          _log.warning(
              'Directory access denied, prompting user to select directory');

          if (!mounted) return;

          // Show dialog explaining the issue
          final shouldChoose = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Directory Access Required'),
              content: const Text(
                'The app does not have permission to access the sync directory.\n\n'
                'On macOS, you need to grant explicit permission by selecting the directory through the file picker.\n\n'
                'Would you like to select the directory now?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Select Directory'),
                ),
              ],
            ),
          );

          if (shouldChoose == true && mounted) {
            await _chooseDirectory();

            // Test again after selection
            final hasAccessNow = await widget.dirAuth.testDirectoryAccess();
            if (!hasAccessNow) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                        'Still no access to directory. Please try a different location.'),
                    backgroundColor: Colors.red,
                  ),
                );
              }
              return;
            }
          } else {
            // User cancelled
            return;
          }
        }

        await widget.dirAuth.enable();
      }

      if (!mounted) return;

      setState(() {
        _isEnabled = !_isEnabled;
      });

      // Close screen and signal change
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e, stackTrace) {
      _log.severe('Failed to toggle sync', e, stackTrace);
      if (!mounted) return;
      setState(() {
        // Keep current state on error
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _openDirectory() async {
    try {
      final path = widget.dirAuth.syncDirectoryPath;
      _log.info('Attempting to open directory: $path');

      // Use shell command to open directory
      if (Platform.isMacOS) {
        final result = await Process.run('open', [path]);
        if (result.exitCode != 0) {
          _log.warning('Failed to open directory: ${result.stderr}');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                    'Could not open directory. It may be in a sandboxed location.'),
              ),
            );
          }
        }
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [path]);
      } else if (Platform.isWindows) {
        await Process.run('explorer', [path]);
      }
    } catch (e, stackTrace) {
      _log.severe('Failed to open directory', e, stackTrace);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not open directory'),
          ),
        );
      }
    }
  }

  /// Check if directory is in a sandboxed container path.
  bool _isInSandbox(String path) {
    return path.contains('/Library/Containers/') ||
        path.contains('/Library/Application Support/');
  }

  Future<void> _chooseDirectory() async {
    _log.info('Opening directory picker...');
    try {
      final selectedPath = await FilePicker.getDirectoryPath(
        dialogTitle: 'Choose Sync Directory',
        initialDirectory: widget.dirAuth.syncDirectoryPath,
      );

      _log.info('Directory picker result: $selectedPath');

      if (selectedPath != null) {
        _log.info('Updating sync directory path to: $selectedPath');
        await widget.dirAuth.updateSyncDirectoryPath(selectedPath);
        if (mounted) {
          setState(() {}); // Refresh UI with new path
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Sync directory changed to: $selectedPath'),
            ),
          );
        }
      } else {
        _log.info('Directory picker cancelled by user');
      }
    } catch (e, stackTrace) {
      _log.severe('Failed to choose directory', e, stackTrace);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error choosing directory: $e'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Local Directory Sync'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Icon
                  Icon(
                    Icons.folder_copy_outlined,
                    size: 80,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(height: 24),

                  // Title
                  Text(
                    'Local Directory Sync',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),

                  // Platform warning
                  if (!Platform.isMacOS &&
                      !Platform.isWindows &&
                      !Platform.isLinux)
                    Card(
                      color: colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            Icon(Icons.warning, color: colorScheme.error),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'Local directory sync is designed for desktop platforms (macOS, Windows, Linux).',
                                style: TextStyle(
                                    color: colorScheme.onErrorContainer),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (!Platform.isMacOS &&
                      !Platform.isWindows &&
                      !Platform.isLinux)
                    const SizedBox(height: 16),

                  // Explanation
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'How it works',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 12),
                          _buildBulletPoint(
                            'Your data is synced to a local directory on your computer',
                          ),
                          const SizedBox(height: 8),
                          _buildBulletPoint(
                            'Files are stored as RDF/Turtle documents',
                          ),
                          const SizedBox(height: 8),
                          _buildBulletPoint(
                            'You can view and backup files directly from your file system',
                          ),
                          const SizedBox(height: 8),
                          _buildBulletPoint(
                            'Great for local backups and development',
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Directory path
                  Card(
                    color: colorScheme.surfaceContainerHighest,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.folder_outlined,
                                size: 20,
                                color: colorScheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Sync Directory',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          SelectableText(
                            widget.dirAuth.syncDirectoryPath,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontFamily: 'monospace',
                            ),
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              OutlinedButton.icon(
                                onPressed: _chooseDirectory,
                                icon: const Icon(Icons.folder_open, size: 18),
                                label: const Text('Choose Directory'),
                                style: OutlinedButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                ),
                              ),
                              if (!_isInSandbox(
                                  widget.dirAuth.syncDirectoryPath))
                                OutlinedButton.icon(
                                  onPressed: _openDirectory,
                                  icon: const Icon(Icons.open_in_new, size: 18),
                                  label: const Text('Open in Finder'),
                                  style: OutlinedButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                  ),
                                ),
                            ],
                          ),
                          if (_isInSandbox(widget.dirAuth.syncDirectoryPath))
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                'Note: Directory is in app sandbox. Use "Choose Directory" to select an accessible location.',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),

                  // Enable/Disable button
                  FilledButton.icon(
                    onPressed: _isLoading ? null : _toggleSync,
                    icon: _isLoading
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: colorScheme.onPrimary,
                            ),
                          )
                        : Icon(_isEnabled ? Icons.pause : Icons.play_arrow),
                    label: Text(_isEnabled ? 'Disable Sync' : 'Enable Sync'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),

                  // Current status
                  const SizedBox(height: 16),
                  Center(
                    child: Text(
                      _isEnabled ? '✓ Sync is enabled' : 'Sync is disabled',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: _isEnabled
                            ? colorScheme.primary
                            : colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBulletPoint(String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('• ', style: TextStyle(fontSize: 16)),
        Expanded(child: Text(text)),
      ],
    );
  }
}
