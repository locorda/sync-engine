#!/usr/bin/env dart
// Copyright (c) 2025, Klas Kalaß <habbatical@gmail.com>
// All rights reserved. Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

/// Script to run tests across all packages using melos
///
/// Usage: dart tool/run_tests.dart
///
/// For individual package coverage, run:
///   cd packages/PACKAGE_NAME && dart test --coverage=coverage
library;
// ignore_for_file: avoid_print

import 'dart:io';

Future<void> main() async {
  print('Running tests across all packages with melos...');

  // Use melos to run tests across all packages
  final testProcess = await Process.start(
      'dart',
      [
        'pub',
        'run',
        'melos',
        'test',
      ],
      mode: ProcessStartMode.inheritStdio);

  final exitCode = await testProcess.exitCode;
  if (exitCode != 0) {
    print('Tests failed with exit code $exitCode');
    exit(exitCode);
  }

  print('For detailed coverage reports, run:');
  print('  cd packages/locorda_core && dart test --coverage=coverage');
  print('  cd packages/locorda_solid_auth && dart test --coverage=coverage');
  print('  cd packages/locorda_solid_ui && dart test --coverage=coverage');
  print('');
  print(
      'Note: Multipackage coverage aggregation requires individual package reports.');
  print(
      'Consider using melos for per-package coverage or implement coverage merger.');

  // Skip coverage processing for now - melos doesn't aggregate coverage easily
  print('Tests completed successfully!');
}
