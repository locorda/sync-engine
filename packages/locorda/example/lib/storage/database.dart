/// Drift database schema for the example app's local storage.
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:logging/logging.dart';
import 'package:locorda_rdf_core/core.dart';

import '../models/weblink.dart';

part 'database.g.dart';

final _log = Logger('AppDatabase');

/// Type converter for `Set<String>` to/from JSON
class StringSetConverter extends TypeConverter<Set<String>, String> {
  const StringSetConverter();

  @override
  Set<String> fromSql(String fromDb) {
    if (fromDb.isEmpty) return <String>{};
    try {
      final List<dynamic> decoded = json.decode(fromDb);
      return decoded.cast<String>().toSet();
    } catch (e) {
      // Fallback for comma-separated format
      return fromDb.split(',').where((s) => s.isNotEmpty).toSet();
    }
  }

  @override
  String toSql(Set<String> value) {
    return json.encode(value.toList());
  }
}

/// Type converter for `Set<Weblink>` to/from JSON
class WeblinkSetConverter extends TypeConverter<Set<Weblink>, String> {
  const WeblinkSetConverter();

  @override
  Set<Weblink> fromSql(String fromDb) {
    if (fromDb.isEmpty) return <Weblink>{};
    try {
      final List<dynamic> decoded = json.decode(fromDb);
      return decoded.map((item) {
        return Weblink(
          url: item['url'] as String,
          title: item['title'] as String?,
          description: item['description'] as String?,
        );
      }).toSet();
    } catch (e) {
      return <Weblink>{};
    }
  }

  @override
  String toSql(Set<Weblink> value) {
    return json.encode(value
        .map((w) => {
              'url': w.url,
              'title': w.title,
              'description': w.description,
            })
        .toList());
  }
}

/// Type converter for `RdfGraph` to/from Turtle format
class RdfGraphConverter extends TypeConverter<RdfGraph, String> {
  const RdfGraphConverter();

  @override
  RdfGraph fromSql(String fromDb) {
    if (fromDb.isEmpty) return RdfGraph();
    try {
      final codec = turtle;
      return codec.decode(fromDb);
    } catch (e, stack) {
      _log.severe('Error parsing RDF graph from Turtle: $e', e, stack);
      // Return empty graph on parse error
      return RdfGraph();
    }
  }

  @override
  String toSql(RdfGraph value) {
    if (value.isEmpty) return '';
    try {
      final codec = turtle;
      return codec.encode(value);
    } catch (e, stack) {
      _log.severe('Error serializing RDF graph to Turtle: $e', e, stack);
      // Return empty string on encoding error
      return '';
    }
  }
}

/// Categories table
class Categories extends Table {
  /// Category ID (primary key)
  TextColumn get id => text()();

  /// Category name
  TextColumn get name => text()();

  /// Category description (optional)
  TextColumn get description => text().nullable()();

  /// Category color (optional)
  TextColumn get color => text().nullable()();

  /// Category icon (optional)
  TextColumn get icon => text().nullable()();

  /// Creation timestamp
  DateTimeColumn get createdAt => dateTime()();

  /// Last modification timestamp
  DateTimeColumn get modifiedAt => dateTime()();

  /// Whether this category is archived (soft deleted)
  BoolColumn get archived => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Comments table
class Comments extends Table {
  /// Comment ID (primary key)
  TextColumn get id => text()();

  /// Note ID (foreign key)
  TextColumn get noteId => text().references(Notes, #id)();

  /// Comment content
  TextColumn get content => text()();

  /// Creation timestamp
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Notes table
class Notes extends Table {
  /// Note ID (primary key)
  TextColumn get id => text()();

  /// Note title
  TextColumn get title => text()();

  /// Note content
  TextColumn get content => text()();

  /// Tags that can be added/removed independently
  TextColumn get tags => text()
      .map(const StringSetConverter())
      .withDefault(const Constant('[]'))();

  /// Weblinks referenced by this note
  TextColumn get weblinks => text()
      .map(const WeblinkSetConverter())
      .withDefault(const Constant('[]'))();

  /// Other unmapped triples from RDF (for lossless round-tripping)
  TextColumn get otherTriples =>
      text().map(const RdfGraphConverter()).withDefault(const Constant(''))();

  /// Category ID (foreign key)
  TextColumn get categoryId => text().nullable().references(Categories, #id)();

  /// Creation timestamp
  DateTimeColumn get createdAt => dateTime()();

  /// Last modification timestamp
  DateTimeColumn get modifiedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Note index entries table - lightweight metadata for browsing
class NoteIndexEntries extends Table {
  /// Note ID (primary key, references note)
  TextColumn get id => text()();

  /// Note name/title (from indexed properties)
  TextColumn get name => text()();

  /// Creation timestamp (from indexed properties)
  DateTimeColumn get dateCreated => dateTime()();

  /// Last modification timestamp (from indexed properties)
  DateTimeColumn get dateModified => dateTime()();

  /// Keywords (from indexed properties)
  TextColumn get keywords =>
      text().map(const StringSetConverter()).nullable()();

  /// Category ID (from indexed properties)
  TextColumn get categoryId => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Hydration cursors table for tracking sync storage state
class HydrationCursors extends Table {
  /// Resource type (e.g., 'category', 'note')
  TextColumn get resourceType => text()();

  /// Last processed cursor value
  TextColumn get cursor => text()();

  /// Last update timestamp
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {resourceType};
}

/// Main app database class (schema only)
@DriftDatabase(
    tables: [Categories, Comments, Notes, NoteIndexEntries, HydrationCursors],
    daos: [CategoryDao, CommentDao, NoteDao, NoteIndexEntryDao, CursorDao])
class AppDatabase extends _$AppDatabase {
  AppDatabase({DriftWebOptions? web, DriftNativeOptions? native})
      : super(_openConnection(web: web, native: native));

  @override
  int get schemaVersion => 9;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (Migrator m) async {
          await m.createAll();

          // Create indices for performance
          await m.database.customStatement('''
        CREATE INDEX IF NOT EXISTS idx_notes_category 
        ON notes(category_id);
      ''');

          await m.database.customStatement('''
        CREATE INDEX IF NOT EXISTS idx_notes_modified 
        ON notes(modified_at DESC);
      ''');

          await m.database.customStatement('''
        CREATE INDEX IF NOT EXISTS idx_categories_name 
        ON categories(name);
      ''');

          await m.database.customStatement('''
        CREATE INDEX IF NOT EXISTS idx_note_index_entries_category
        ON note_index_entries(category_id);
      ''');
        },
        onUpgrade: (Migrator m, int from, int to) async {
          if (from < 2) {
            // Add HydrationCursors table in version 2
            await m.createTable(hydrationCursors);
          }
          if (from < 3) {
            // Add archived column to categories table in version 3
            await m.addColumn(categories, categories.archived);
          }
          if (from < 4) {
            // Add NoteIndexEntries table in version 4
            await m.createTable(noteIndexEntries);

            await m.database.customStatement('''
              CREATE INDEX IF NOT EXISTS idx_note_index_entries_category
              ON note_index_entries(category_id);
            ''');
          }
          if (from < 5) {
            // Add tags column to notes table in version 5
            await m.database.customStatement('''
              ALTER TABLE notes ADD COLUMN tags TEXT NOT NULL DEFAULT '[]';
            ''');
          }
          if (from < 6) {
            // Version 6: Recreate note_index_entries table to ensure clean schema
            // Drop the old table (may have unexpected columns from previous versions)
            await m.database.customStatement('''
              DROP TABLE IF EXISTS note_index_entries;
            ''');

            // Recreate with clean schema
            await m.createTable(noteIndexEntries);

            await m.database.customStatement('''
              CREATE INDEX IF NOT EXISTS idx_note_index_entries_category
              ON note_index_entries(category_id);
            ''');
          }
          if (from < 7) {
            // Version 7: Add weblinks column to notes table
            await m.database.customStatement('''
              ALTER TABLE notes ADD COLUMN weblinks TEXT NOT NULL DEFAULT '[]';
            ''');
          }
          if (from < 8) {
            // Version 8: Add comments table
            await m.createTable(comments);

            await m.database.customStatement('''
              CREATE INDEX IF NOT EXISTS idx_comments_note
              ON comments(note_id);
            ''');
          }
          if (from < 9) {
            // Version 9: Add otherTriples column for lossless RDF round-tripping
            await m.database.customStatement('''
              ALTER TABLE notes ADD COLUMN other_triples TEXT NOT NULL DEFAULT '';
            ''');
          }
        },
      );
}

/// Data Access Object for Categories
@DriftAccessor(tables: [Categories])
class CategoryDao extends DatabaseAccessor<AppDatabase>
    with _$CategoryDaoMixin {
  CategoryDao(super.db);

  /// Watch all categories ordered by name (non-archived only)
  Stream<List<Category>> getAllCategories() {
    return (select(categories)
          ..where((c) => c.archived.equals(false))
          ..orderBy([(c) => OrderingTerm(expression: c.name)]))
        .watch();
  }

  /// Watch all categories including archived ones, ordered by name
  Stream<List<Category>> getAllCategoriesIncludingArchived() {
    return (select(categories)
          ..orderBy([(c) => OrderingTerm(expression: c.name)]))
        .watch();
  }

  /// Get a specific category by ID
  Future<Category?> getCategoryById(String id) {
    return (select(categories)..where((c) => c.id.equals(id)))
        .getSingleOrNull();
  }

  /// Insert or update a category
  Future<void> insertOrUpdateCategory(CategoriesCompanion companion) {
    return into(categories).insertOnConflictUpdate(companion);
  }

  /// Delete a category by ID
  Future<void> deleteCategoryById(String id) {
    return (delete(categories)..where((c) => c.id.equals(id))).go();
  }
}

/// Data Access Object for Comments
@DriftAccessor(tables: [Comments])
class CommentDao extends DatabaseAccessor<AppDatabase> with _$CommentDaoMixin {
  CommentDao(super.db);

  /// Get all comments for a specific note
  Future<List<Comment>> getCommentsForNote(String noteId) {
    return (select(comments)..where((c) => c.noteId.equals(noteId))).get();
  }

  /// Insert or update a comment
  Future<void> insertOrUpdateComment(CommentsCompanion companion) {
    return into(comments).insertOnConflictUpdate(companion);
  }

  /// Delete a comment by ID
  Future<void> deleteCommentById(String id) {
    return (delete(comments)..where((c) => c.id.equals(id))).go();
  }

  /// Delete all comments for a note
  Future<void> deleteCommentsForNote(String noteId) {
    return (delete(comments)..where((c) => c.noteId.equals(noteId))).go();
  }
}

/// Data Access Object for Notes
@DriftAccessor(tables: [Notes])
class NoteDao extends DatabaseAccessor<AppDatabase> with _$NoteDaoMixin {
  NoteDao(super.db);

  /// Get a specific note by ID
  Future<Note?> getNoteById(String id) {
    return (select(notes)..where((n) => n.id.equals(id))).getSingleOrNull();
  }

  /// Insert or update a note
  Future<void> insertOrUpdateNote(NotesCompanion companion) {
    return into(notes).insertOnConflictUpdate(companion);
  }

  /// Delete a note by ID
  Future<void> deleteNoteById(String id) {
    return (delete(notes)..where((n) => n.id.equals(id))).go();
  }
}

/// Data Access Object for Note Index Entries
@DriftAccessor(tables: [NoteIndexEntries])
class NoteIndexEntryDao extends DatabaseAccessor<AppDatabase>
    with _$NoteIndexEntryDaoMixin {
  NoteIndexEntryDao(super.db);

  /// Watch all note index entries ordered by modification date (newest first)
  Stream<List<NoteIndexEntry>> watchAllNoteIndexEntries() {
    return (select(noteIndexEntries)
          ..orderBy([
            (n) => OrderingTerm(
                expression: n.dateModified, mode: OrderingMode.desc)
          ]))
        .watch();
  }

  /// Insert or update a note index entry
  Future<void> insertOrUpdateNoteIndexEntry(
      NoteIndexEntriesCompanion companion) {
    return into(noteIndexEntries).insertOnConflictUpdate(companion);
  }

  /// Delete a note index entry by ID
  Future<void> deleteNoteIndexEntryById(String id) {
    return (delete(noteIndexEntries)..where((n) => n.id.equals(id))).go();
  }
}

/// Data Access Object for Hydration Cursors
@DriftAccessor(tables: [HydrationCursors])
class CursorDao extends DatabaseAccessor<AppDatabase> with _$CursorDaoMixin {
  CursorDao(super.db);

  /// Get cursor for a specific resource type
  Future<String?> getCursor(String resourceType) async {
    final cursor = await (select(hydrationCursors)
          ..where((c) => c.resourceType.equals(resourceType)))
        .getSingleOrNull();
    return cursor?.cursor;
  }

  /// Store cursor for a specific resource type
  Future<void> storeCursor(String resourceType, String cursor) {
    return into(hydrationCursors).insertOnConflictUpdate(
      HydrationCursorsCompanion(
        resourceType: Value(resourceType),
        cursor: Value(cursor),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Clear cursor for a specific resource type
  Future<void> clearCursor(String resourceType) {
    return (delete(hydrationCursors)
          ..where((c) => c.resourceType.equals(resourceType)))
        .go();
  }
}

/// Create database connection based on platform
QueryExecutor _openConnection(
    {DriftWebOptions? web, DriftNativeOptions? native}) {
  // For web, explicitly configure IndexedDB storage
  return driftDatabase(
    name: 'personal_notes_app',
    web: web,
    native: native,
  );
}
