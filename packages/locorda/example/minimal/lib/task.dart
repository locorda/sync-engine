/// Minimal Task model demonstrating Locorda sync.
library;

import 'package:locorda/annotations.dart';

// #docregion task-model
/// A simple task that syncs across devices.
@RootResource(AppVocab(appBaseUri: 'https://locorda.dev/example/minimal'))
class Task {
  /// Unique ID for this task
  @RdfIriPart()
  final String id;

  /// Task title
  final String title;

  /// Completion status
  final bool completed;

  /// Creation timestamp
  final DateTime createdAt;

  Task({
    required this.id,
    required this.title,
    this.completed = false,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Task copyWith({String? title, bool? completed}) => Task(
        id: id,
        title: title ?? this.title,
        completed: completed ?? this.completed,
        createdAt: createdAt,
      );
}

// #enddocregion task-model
