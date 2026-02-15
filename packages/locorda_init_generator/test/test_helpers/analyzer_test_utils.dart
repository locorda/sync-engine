import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:test/test.dart';

class ResolvedTestLibrary {
  final ResolvedUnitResult resolved;
  final Map<String, Uri> fileUris;

  const ResolvedTestLibrary({
    required this.resolved,
    required this.fileUris,
  });
}

Future<ResolvedTestLibrary> resolveTestLibrary({
  required Map<String, String> files,
  String entryFile = 'main.dart',
  String tempPrefix = 'locorda_init_generator_test_',
}) async {
  final tempDir = await Directory.systemTemp.createTemp(tempPrefix);
  addTearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  final fileUris = <String, Uri>{};
  for (final entry in files.entries) {
    final file = File('${tempDir.path}/${entry.key}');
    await file.writeAsString(entry.value);
    fileUris[entry.key] = file.uri;
  }

  final entryPath = '${tempDir.path}/$entryFile';
  final result = await resolveFile(path: entryPath);

  return ResolvedTestLibrary(
    resolved: result as ResolvedUnitResult,
    fileUris: fileUris,
  );
}
