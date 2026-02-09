import 'package:flutter_test/flutter_test.dart';
import 'package:personal_notes_app/models/note.dart';
import 'package:personal_notes_app/models/note_index_entry.dart';
import 'package:personal_notes_app/models/note_group_key.dart';
import 'package:personal_notes_app/storage/repositories.dart';
import 'package:locorda_core/locorda_core.dart';

/// Mock repository for testing
class MockNoteRepository implements NoteRepository {
  final List<Note> savedNotes = [];
  final List<Note> storedNotes = [];
  final List<NoteIndexEntry> storedIndexEntries = [];

  @override
  Future<void> saveNote(Note note) async {
    savedNotes.add(note);
    // Simulate storing the note
    storedNotes.removeWhere((n) => n.id == note.id);
    storedNotes.add(note);

    // Also create/update corresponding index entry
    final indexEntry = _createIndexEntryFromNote(note);
    storedIndexEntries.removeWhere((e) => e.id == note.id);
    storedIndexEntries.add(indexEntry);
  }

  @override
  Future<Note?> getNote(String id) async {
    try {
      return storedNotes.firstWhere((n) => n.id == id);
    } catch (e) {
      return null;
    }
  }

  @override
  Future<void> deleteNote(String id) async {
    storedNotes.removeWhere((n) => n.id == id);
    storedIndexEntries.removeWhere((e) => e.id == id);
  }

  // Reactive NoteIndexEntry methods
  @override
  Stream<List<NoteIndexEntry>> watchAllNoteIndexEntries() {
    return Stream.value(List.from(storedIndexEntries));
  }

  @override
  Future<void> configureMonthGroupSubscription(
      NoteGroupKey monthKey, ItemFetchPolicy fetchPolicy) async {
    // Mock implementation - do nothing for tests
  }

  @override
  void dispose() {}

  /// Helper method to create NoteIndexEntry from Note
  NoteIndexEntry _createIndexEntryFromNote(Note note) {
    return NoteIndexEntry(
      id: note.id,
      name: note.title,
      dateCreated: note.createdAt,
      dateModified: note.modifiedAt,
      keywords: note.tags,
      categoryId: note.categoryId,
    );
  }
}
