/// Minimal Task model demonstrating Locorda sync.
library;

import 'package:locorda_annotations/locorda_annotations.dart';
import 'package:locorda_rdf_mapper_annotations/annotations.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_rdf_terms_schema/schema.dart';
import 'package:minimal_task_sync/consts.dart' show appBaseUrl;

// #docregion task-model
/// A simple task with CRDT sync.
@LcrdRootResource(
  IriTerm('$appBaseUrl/vocabulary/task#Task'),
  '$appBaseUrl/mappings/task-v1.ttl',
)
class Task {
  /// Unique ID for this task
  @RdfIriPart()
  final String id;

  /// Task title - LWW (Last Writer Wins)
  @RdfProperty(SchemaThing.name)
  @CrdtLwwRegister()
  final String title;

  /// Completion status - LWW (schema.org has no boolean completion property)
  @RdfProperty(IriTerm('$appBaseUrl/vocabulary/task#completed'))
  @CrdtLwwRegister()
  final bool completed;

  /// Creation timestamp - Immutable
  @RdfProperty(SchemaCreativeWork.dateCreated)
  @CrdtImmutable()
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
