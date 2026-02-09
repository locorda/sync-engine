import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_notes_app/models/category.dart';
import 'package:personal_notes_app/models/note.dart';
import 'package:personal_notes_app/screens/note_editor_screen.dart';
import 'package:personal_notes_app/services/categories_service.dart';
import 'package:personal_notes_app/services/notes_service.dart';

import '../services/mock_category_repository.dart';
import '../services/mock_note_repository.dart';

void main() {
  testWidgets('NoteEditorScreen handles missing category selection',
      (WidgetTester tester) async {
    final mockCategoryRepo = MockCategoryRepository();
    final mockNoteRepo = MockNoteRepository();
    final categoriesService = CategoriesService(mockCategoryRepo);
    final notesService = NotesService(mockNoteRepo);

    mockCategoryRepo.storedCategories.add(Category(
      id: 'category_existing',
      name: 'Existing',
    ));

    final note = Note(
      id: 'note_1',
      title: 'Title',
      content: 'Content',
      categoryId: 'category_missing',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: NoteEditorScreen(
          notesService: notesService,
          categoriesService: categoriesService,
          note: note,
        ),
      ),
    );

    await tester.pump();

    expect(find.byType(DropdownButtonFormField<String?>), findsOneWidget);
  });
}
