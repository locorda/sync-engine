import 'package:flutter_test/flutter_test.dart';
import 'package:locorda_ui/src/ui/multi_backend_status_widget.dart';

void main() {
  group('resolveBackendSheetTitle', () {
    test('returns active plugin name when available', () {
      final title = resolveBackendSheetTitle(
        defaultTitle: 'Storage Backends',
        activePluginName: 'Google Drive',
      );

      expect(title, 'Google Drive');
    });

    test('returns default title when active plugin name is null', () {
      final title = resolveBackendSheetTitle(
        defaultTitle: 'Storage Backends',
        activePluginName: null,
      );

      expect(title, 'Storage Backends');
    });

    test('returns default title when active plugin name is blank', () {
      final title = resolveBackendSheetTitle(
        defaultTitle: 'Storage Backends',
        activePluginName: '   ',
      );

      expect(title, 'Storage Backends');
    });
  });
}
