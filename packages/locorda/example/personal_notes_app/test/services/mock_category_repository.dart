import 'package:flutter_test/flutter_test.dart';
import 'package:personal_notes_app/models/category.dart';
import 'package:personal_notes_app/storage/repositories.dart';

/// Mock repository for testing
class MockCategoryRepository implements CategoryRepository {
  final List<Category> savedCategories = [];
  final List<Category> storedCategories = [];

  @override
  Future<void> saveCategory(Category category) async {
    savedCategories.add(category);
    // Simulate storing the category
    storedCategories.removeWhere((c) => c.id == category.id);
    storedCategories.add(category);
  }

  @override
  Stream<List<Category>> getAllCategories() =>
      Stream.value(storedCategories.where((c) => !c.archived).toList());

  @override
  Stream<List<Category>> getAllCategoriesIncludingArchived() =>
      Stream.value(List.from(storedCategories));

  @override
  Future<Category?> getCategory(String id) async {
    try {
      return storedCategories.firstWhere((c) => c.id == id);
    } catch (e) {
      return null;
    }
  }

  @override
  Future<void> archiveCategory(String id) async {
    final categoryIndex = storedCategories.indexWhere((c) => c.id == id);
    if (categoryIndex != -1) {
      final category = storedCategories[categoryIndex];
      storedCategories[categoryIndex] = category.copyWith(archived: true);
    }
  }

  @override
  void dispose() {}
}
