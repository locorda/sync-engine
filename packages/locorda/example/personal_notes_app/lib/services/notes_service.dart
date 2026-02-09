/// Business logic for managing notes with CRDT sync.
library;

import 'dart:math';

import 'package:personal_notes_app/models/note_group_key.dart';
import 'package:rxdart/rxdart.dart';
import 'package:locorda_core/locorda_core.dart';

import '../models/note.dart';
import '../models/note_index_entry.dart';
import '../storage/repositories.dart';

/// Service for managing notes with offline-first CRDT synchronization.
///
/// This service demonstrates the add-on architecture where:
/// - Repository handles all local queries, operations AND sync coordination
/// - Service focuses purely on business logic
/// - Repository is "sync-aware storage" that handles CRDT processing automatically
class NotesService {
  final NoteRepository _noteRepository;

  // Reactive filter state
  final _categoryFilterController = BehaviorSubject<String?>.seeded(null);
  final _monthFilterController = BehaviorSubject<NoteGroupKey?>.seeded(null);

  NotesService(this._noteRepository);

  /// Reactive stream of filtered note index entries based on current filters
  Stream<List<NoteIndexEntry>> get filteredNoteIndexEntries {
    return Rx.combineLatest2<String?, NoteGroupKey?, (String?, NoteGroupKey?)>(
      _categoryFilterController.stream,
      _monthFilterController.stream,
      (categoryId, monthFilter) => (categoryId, monthFilter),
    ).switchMap((filters) {
      final (categoryId, monthFilter) = filters;

      // Apply both category and month filters
      return _noteRepository.watchAllNoteIndexEntries().map((entries) {
        var filtered = entries;

        // Filter by category if specified
        if (categoryId != null) {
          filtered = filtered
              .where((entry) => entry.categoryId == categoryId)
              .toList();
        }

        // Filter by month if specified
        if (monthFilter != null) {
          final year = monthFilter.createdMonth.year;
          final month = monthFilter.createdMonth.month;
          filtered = filtered.where((entry) {
            return entry.dateCreated.year == year &&
                entry.dateCreated.month == month;
          }).toList();
        }

        return filtered;
      });
    });
  }

  /// Get current category filter
  String? get currentCategoryFilter => _categoryFilterController.valueOrNull;

  /// Set category filter (null means show all notes)
  void setCategoryFilter(String? categoryId) {
    _categoryFilterController.add(categoryId);
  }

  /// Stream of current category filter state
  Stream<String?> get categoryFilterStream => _categoryFilterController.stream;

  /// Set month filter and ensure subscription to the month group
  Future<void> setMonthFilter(NoteGroupKey? monthFilter) async {
    if (monthFilter != null) {
      // Determine fetch policy based on month
      final isPrefetchNeeded = monthFilter == NoteGroupKey.currentMonth ||
          monthFilter == NoteGroupKey.previousMonth;

      await _noteRepository.configureMonthGroupSubscription(
          monthFilter,
          isPrefetchNeeded
              ? ItemFetchPolicy.prefetch
              : ItemFetchPolicy.onRequest);
    }
    _monthFilterController.add(monthFilter);
  }

  /// Initialize default subscriptions for current and previous month
  /// Returns the month that was set as the initial filter
  Future<NoteGroupKey> initializeDefaultSubscriptions() async {
    // Configure subscriptions to current and previous month with prefetch (business logic)
    await _noteRepository.configureMonthGroupSubscription(
        NoteGroupKey.currentMonth, ItemFetchPolicy.prefetch);
    await _noteRepository.configureMonthGroupSubscription(
        NoteGroupKey.previousMonth, ItemFetchPolicy.prefetch);

    // Set initial month filter to current month
    final initialMonth = NoteGroupKey.currentMonth;
    _monthFilterController.add(initialMonth);
    return initialMonth;
  }

  /// Get a specific note by ID
  Future<Note?> getNote(String id) async {
    return await _noteRepository.getNote(id);
  }

  /// Save a note (create or update)
  Future<void> saveNote(Note note) async {
    // Repository handles sync coordination automatically
    await _noteRepository.saveNote(note);
  }

  /// Delete a note
  Future<void> deleteNote(String id) async {
    // Repository handles deletion (including future CRDT deletion)
    await _noteRepository.deleteNote(id);
  }

  /// Create a new note with generated ID
  Note createNote({
    String title = '',
    String content = '',
    Set<String>? tags,
  }) {
    return Note(
      id: _generateId(),
      title: title,
      content: content,
      tags: tags ?? <String>{},
    );
  }

  /// Generate a unique ID for new notes
  String _generateId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = Random().nextInt(999999);
    return 'note_${timestamp}_$random';
  }

  /// Dispose of resources and close streams
  void dispose() {
    _categoryFilterController.close();
  }
}
