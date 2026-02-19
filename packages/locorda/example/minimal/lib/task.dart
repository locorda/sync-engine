/// Minimal Task model demonstrating Locorda sync.
library;

import 'package:locorda_annotations/locorda_annotations.dart';
import 'package:locorda_rdf_mapper_annotations/annotations.dart';
import 'package:minimal_task_sync/consts.dart' show appBaseUrl;

// #docregion task-model
/// A simple task with CRDT sync.
@RootResource(AppVocab(appBaseUri: appBaseUrl))
class Task {
  /// Unique ID for this task
  @RdfIriPart()
  final String id;

  /// Task title - LWW (Last Writer Wins) is the default merge strategy
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
