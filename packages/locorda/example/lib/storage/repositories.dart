/// Repository layer for business logic operations.
library;

import 'dart:async';
import 'package:drift/drift.dart';
import 'package:locorda/locorda.dart';
import 'package:logging/logging.dart';
import '../models/category.dart' as models;
import '../models/category_display_settings.dart' as models;
import '../models/note.dart' as models;
import '../models/comment.dart' as models;
import '../models/note_index_entry.dart' as models;
import '../models/note_group_key.dart';
import 'database.dart';

final _log = Logger('CategoryRepository');

/// Repository for Category business logic operations.
///
/// This layer handles business logic, model conversion between
/// Drift entities and application models, AND sync coordination.
/// Repository becomes "sync-aware storage" following add-on architecture.
class CategoryRepository {
  final CategoryDao _categoryDao;
  final ObjectSyncEngine _syncSystem;
  final StreamSubscription _hydrationSubscription;

  static const String _resourceType = 'category';

  /// Private constructor - use [create] factory method instead
  CategoryRepository._(
    this._categoryDao,
    this._syncSystem,
    this._hydrationSubscription,
  );

  /// Create and initialize a CategoryRepository with hydration from sync storage.
  ///
  /// This factory method:
  /// 1. Sets up hydration subscription for live updates
  /// 2. Performs initial catch-up from last cursor position
  /// 3. Returns a fully initialized repository
  static Future<CategoryRepository> create(
    CategoryDao categoryDao,
    CursorDao cursorDao,
    ObjectSyncEngine syncSystem,
  ) async {
    final subscription = await syncSystem.hydrateWithCallbacks<models.Category>(
      getCurrentCursor: () => cursorDao.getCursor(_resourceType),
      onUpdate: (category) => _handleCategoryUpdate(categoryDao, category),
      onDelete: (categoryId) => _handleCategoryDelete(categoryDao, categoryId),
      onCursorUpdate: (cursor) => cursorDao.storeCursor(_resourceType, cursor),
    );

    final repository =
        CategoryRepository._(categoryDao, syncSystem, subscription);
    return repository;
  }

  /// Handle category update from sync storage
  static Future<void> _handleCategoryUpdate(
      CategoryDao categoryDao, models.Category category) async {
    final companion = _categoryToDriftCompanion(category);
    await categoryDao.insertOrUpdateCategory(companion);
  }

  /// Handle category deletion from sync storage
  static Future<void> _handleCategoryDelete(
      CategoryDao categoryDao, String id) async {
    await categoryDao.deleteCategoryById(id);
  }

  /// Watch all categories ordered by name (non-archived only)
  Stream<List<models.Category>> getAllCategories() {
    return _categoryDao.getAllCategories().map(
        (driftCategories) => driftCategories.map(_categoryFromDrift).toList());
  }

  /// Watch all categories including archived ones, ordered by name
  Stream<List<models.Category>> getAllCategoriesIncludingArchived() {
    return _categoryDao.getAllCategoriesIncludingArchived().map(
        (driftCategories) => driftCategories.map(_categoryFromDrift).toList());
  }

  /// Get a specific category by ID
  Future<models.Category?> getCategory(String id) async {
    final driftCategory = await _categoryDao.getCategoryById(id);
    return driftCategory != null ? _categoryFromDrift(driftCategory) : null;
  }

  /// Save a category (insert or update) with sync coordination
  Future<void> saveCategory(models.Category category) async {
    // Use sync system - local storage will be updated via hydration stream
    await _syncSystem.save<models.Category>(category);
  }

  /// Archive a category (soft delete) - sets archived flag to true
  ///
  /// Soft delete - marks category as archived but keeps it referenceable.
  /// This is the recommended approach for categories since they may be
  /// referenced by external applications.
  Future<void> archiveCategory(String id) async {
    final category = await getCategory(id);
    if (category != null) {
      final archivedCategory = category.copyWith(
        archived: true,
        modifiedAt: DateTime.now(),
      );
      await saveCategory(archivedCategory);
    }
  }

  /// Dispose resources when repository is no longer needed
  void dispose() {
    _hydrationSubscription.cancel();
  }

  /// Convert Drift Category to app Category model
  models.Category _categoryFromDrift(Category drift) {
    models.CategoryDisplaySettings? settings;
    if (drift.color != null || drift.icon != null) {
      settings =
          models.CategoryDisplaySettings(color: drift.color, icon: drift.icon);
    }

    return models.Category(
      id: drift.id,
      name: drift.name,
      description: drift.description,
      settings: settings,
      createdAt: drift.createdAt,
      modifiedAt: drift.modifiedAt,
      archived: drift.archived,
    );
  }

  /// Convert app Category model to Drift CategoriesCompanion
  static CategoriesCompanion _categoryToDriftCompanion(
      models.Category category) {
    return CategoriesCompanion(
      id: Value(category.id),
      name: Value(category.name),
      description: Value(category.description),
      color: Value(category.settings?.color),
      icon: Value(category.settings?.icon),
      createdAt: Value(category.createdAt),
      modifiedAt: Value(category.modifiedAt),
      archived: Value(category.archived),
    );
  }
}

/// Repository for Note business logic operations.
///
/// This layer handles business logic, model conversion between
/// Drift entities and application models, AND sync coordination.
/// Repository becomes "sync-aware storage" following add-on architecture.
///
/// Handles both full Note resources and lightweight NoteIndexEntry resources.
class NoteRepository {
  final NoteDao _noteDao;
  final CommentDao _commentDao;
  final NoteIndexEntryDao _noteIndexDao;
  final ObjectSyncEngine _syncSystem;
  final StreamSubscription _dataHydrationSubscription;
  final StreamSubscription _indexHydrationSubscription;

  static const String _resourceType = 'note';
  static const String _indexResourceType = 'noteIndexEntry';

  /// Private constructor - use [create] factory method instead
  NoteRepository._(
    this._noteDao,
    this._commentDao,
    this._noteIndexDao,
    this._syncSystem,
    this._dataHydrationSubscription,
    this._indexHydrationSubscription,
  );

  /// Create and initialize a NoteRepository with hydration from sync storage.
  ///
  /// This factory method:
  /// 1. Sets up hydration subscriptions for both Note and NoteIndexEntry
  /// 2. Performs initial catch-up from last cursor position for both types
  /// 3. Returns a fully initialized repository
  static Future<NoteRepository> create(
    NoteDao noteDao,
    CommentDao commentDao,
    NoteIndexEntryDao noteIndexDao,
    CursorDao cursorDao,
    ObjectSyncEngine syncSystem,
  ) async {
    // Setup data hydration for full Note resources
    final dataSubscription = await syncSystem.hydrateWithCallbacks<models.Note>(
      getCurrentCursor: () => cursorDao.getCursor(_resourceType),
      onUpdate: (note) => _handleNoteUpdate(noteDao, commentDao, note),
      onDelete: (noteId) => _handleNoteDelete(noteDao, commentDao, noteId),
      onCursorUpdate: (cursor) => cursorDao.storeCursor(_resourceType, cursor),
    );

    // Setup index hydration for NoteIndexEntry resources
    final indexSubscription =
        await syncSystem.hydrateWithCallbacks<models.NoteIndexEntry>(
      getCurrentCursor: () => cursorDao.getCursor(_indexResourceType),
      onUpdate: (noteEntry) =>
          _handleNoteIndexEntryUpdate(noteIndexDao, noteEntry),
      onDelete: (noteId) => _handleNoteIndexEntryDelete(noteIndexDao, noteId),
      onCursorUpdate: (cursor) =>
          cursorDao.storeCursor(_indexResourceType, cursor),
    );

    final repository = NoteRepository._(
      noteDao,
      commentDao,
      noteIndexDao,
      syncSystem,
      dataSubscription,
      indexSubscription,
    );

    return repository;
  }

  /// Handle note update from sync storage
  static Future<void> _handleNoteUpdate(
      NoteDao noteDao, CommentDao commentDao, models.Note note) async {
    final companion = _noteToDriftCompanion(note);
    await noteDao.insertOrUpdateNote(companion);

    // Update comments - delete old ones and insert new ones
    await commentDao.deleteCommentsForNote(note.id);
    for (final comment in note.comments) {
      final commentCompanion = _commentToDriftCompanion(comment, note.id);
      await commentDao.insertOrUpdateComment(commentCompanion);
    }
  }

  /// Handle note deletion from sync storage
  static Future<void> _handleNoteDelete(
      NoteDao noteDao, CommentDao commentDao, String id) async {
    await commentDao.deleteCommentsForNote(id);
    await noteDao.deleteNoteById(id);
  }

  /// Handle note index entry update from sync storage
  static Future<void> _handleNoteIndexEntryUpdate(
      NoteIndexEntryDao noteIndexDao, models.NoteIndexEntry noteEntry) async {
    final companion = _noteIndexEntryToDriftCompanion(noteEntry);
    await noteIndexDao.insertOrUpdateNoteIndexEntry(companion);
  }

  /// Handle note index entry deletion from sync storage
  static Future<void> _handleNoteIndexEntryDelete(
      NoteIndexEntryDao noteIndexDao, String id) async {
    await noteIndexDao.deleteNoteIndexEntryById(id);
  }

  /// Get a specific note by ID
  Future<models.Note?> getNote(String id) async {
    final note =
        await _syncSystem.ensure<models.Note>(id, loadFromLocal: (id) async {
      final driftNote = await _noteDao.getNoteById(id);
      if (driftNote == null) return null;

      // Load comments for this note
      final driftComments = await _commentDao.getCommentsForNote(id);
      return _noteFromDrift(driftNote, driftComments);
    });

    // Debug: Check if weblinks and comments are present
    if (note != null) {
      _log.info(
          '📝 Loaded note ${note.id}: tags=${note.tags.length}, weblinks=${note.weblinks.length}, comments=${note.comments.length}');
    }

    return note;
  }

  /// Save a note (insert or update) with sync coordination
  Future<void> saveNote(models.Note note) async {
    // Debug: Check what we're saving
    _log.info(
        '💾 Saving note ${note.id}: tags=${note.tags.length}, weblinks=${note.weblinks.length}, comments=${note.comments.length}');

    // Use sync system - local storage will be updated via hydration stream
    await _syncSystem.save<models.Note>(note);
  }

  /// Delete a note by ID (hard deletion - entire document)
  Future<void> deleteNote(String id) async {
    final note = await getNote(id);
    if (note != null) {
      // Use sync system - local storage will be updated via hydration stream
      await _syncSystem.deleteDocument<models.Note>(id);
    }
  }

  /// Convert Drift Note to app Note model
  models.Note _noteFromDrift(Note drift, List<Comment> driftComments) =>
      models.Note(
        id: drift.id,
        title: drift.title,
        content: drift.content,
        tags: drift.tags,
        weblinks: drift.weblinks,
        comments: driftComments.map(_commentFromDrift).toSet(),
        categoryId: drift.categoryId,
        createdAt: drift.createdAt,
        modifiedAt: drift.modifiedAt,
        other: drift.otherTriples,
      );

  /// Convert app Note model to Drift NotesCompanion
  static NotesCompanion _noteToDriftCompanion(models.Note note) =>
      NotesCompanion(
        id: Value(note.id),
        title: Value(note.title),
        content: Value(note.content),
        tags: Value(note.tags),
        weblinks: Value(note.weblinks),
        otherTriples: Value(note.other),
        categoryId: Value(note.categoryId),
        createdAt: Value(note.createdAt),
        modifiedAt: Value(note.modifiedAt),
      );

  /// Convert Drift Comment to app Comment model
  models.Comment _commentFromDrift(Comment drift) => models.Comment(
        id: drift.id,
        content: drift.content,
        createdAt: drift.createdAt,
      );

  /// Convert app Comment model to Drift CommentsCompanion
  static CommentsCompanion _commentToDriftCompanion(
          models.Comment comment, String noteId) =>
      CommentsCompanion(
        id: Value(comment.id),
        noteId: Value(noteId),
        content: Value(comment.content),
        createdAt: Value(comment.createdAt),
      );

  /// Convert Drift NoteIndexEntry to app NoteIndexEntry model
  models.NoteIndexEntry _noteIndexEntryFromDrift(NoteIndexEntry drift) =>
      models.NoteIndexEntry(
        id: drift.id,
        name: drift.name,
        dateCreated: drift.dateCreated,
        dateModified: drift.dateModified,
        keywords: drift.keywords ?? <String>{}, // Handle null with empty set
        categoryId: drift.categoryId,
      );

  /// Convert app NoteIndexEntry model to Drift NoteIndexEntriesCompanion
  static NoteIndexEntriesCompanion _noteIndexEntryToDriftCompanion(
          models.NoteIndexEntry noteEntry) =>
      NoteIndexEntriesCompanion(
        id: Value(noteEntry.id),
        name: Value(noteEntry.name),
        dateCreated: Value(noteEntry.dateCreated),
        dateModified: Value(noteEntry.dateModified),
        keywords: Value(
            noteEntry.keywords), // Now properly handled by StringSetConverter
        categoryId: Value(noteEntry.categoryId),
      );

  /// Watch all note index entries reactively
  Stream<List<models.NoteIndexEntry>> watchAllNoteIndexEntries() {
    return _noteIndexDao.watchAllNoteIndexEntries().map(
        (driftEntries) => driftEntries.map(_noteIndexEntryFromDrift).toList());
  }

  /// Configure subscription to a specific month group for note index entries
  Future<void> configureMonthGroupSubscription(
      NoteGroupKey monthKey, ItemFetchPolicy fetchPolicy) async {
    await _syncSystem.configureGroupIndexSubscription(monthKey, fetchPolicy);
  }

  /// Dispose resources when repository is no longer needed
  void dispose() {
    _dataHydrationSubscription.cancel();
    _indexHydrationSubscription.cancel();
  }
}
