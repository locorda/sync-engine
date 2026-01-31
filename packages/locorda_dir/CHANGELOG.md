# Changelog

## 0.1.0-dev

### Initial Implementation

- ✅ **DirAuth**: Simple boolean-based authentication with enable/disable toggle
- ✅ **DirLoginScreen**: Flutter UI explaining feature with directory path display
- ✅ **DirBackend**: File-based storage backend writing RDF Turtle files
- ✅ **DirRemoteStorage**: Remote storage implementation with ETag support
- ✅ **DirMainIntegration**: Main thread integration with path detection
- ✅ **DirWorkerHandler**: Worker thread handler for file I/O operations

### Features

- Desktop-focused (macOS, Windows, Linux)
- Files organized by resource type (Note/, Category/, etc.)
- ETag generation from file modification time + size
- Automatic directory creation
- Platform-appropriate path detection using path_provider
- Simple toggle UI for enabling/disabling sync

### Platform Support

- ✅ macOS, Linux, Windows (full support)
- ⚠️ iOS, Android (limited - app sandbox only)
- ❌ Web (not supported)

### Default Paths

- **macOS/Linux**: `~/Documents/<appName>/locorda-sync/`
- **Windows**: `%USERPROFILE%\Documents\<appName>\locorda-sync\`
 