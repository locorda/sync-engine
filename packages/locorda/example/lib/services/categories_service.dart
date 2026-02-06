/// Business logic for managing categories with CRDT sync.
library;

import 'dart:async';
import 'dart:math';

import '../models/category.dart';
import '../models/category_display_settings.dart';
import '../storage/repositories.dart';

/// Service for managing categories with offline-first CRDT synchronization.
///
/// This service demonstrates the add-on architecture where:
/// - Repository handles all local queries, operations AND sync coordination
/// - Service focuses purely on business logic and cross-entity operations
/// - Repositories are "sync-aware storage" that handle CRDT processing automatically
///
/// Categories use FullIndex with prefetch policy for immediate availability.
class CategoriesService {
  final CategoryRepository _categoryRepository;

  CategoriesService(this._categoryRepository);

  /// Watch all categories sorted by name (non-archived only)
  Stream<List<Category>> getAllCategories() {
    // Query from repository - fast and flexible
    return _categoryRepository.getAllCategories().map(_deduplicateById);
  }

  /// Watch all categories including archived ones, sorted by name
  Stream<List<Category>> getAllCategoriesIncludingArchived() {
    return _categoryRepository
        .getAllCategoriesIncludingArchived()
        .map(_deduplicateById);
  }

  List<Category> _deduplicateById(List<Category> categories) {
    final byId = <String, Category>{};
    for (final category in categories) {
      final existing = byId[category.id];
      if (existing == null || category.modifiedAt.isAfter(existing.modifiedAt)) {
        byId[category.id] = category;
      }
    }
    return byId.values.toList();
  }

  /// Get a specific category by ID
  Future<Category?> getCategory(String id) async {
    // Query from repository - immediate response
    return await _categoryRepository.getCategory(id);
  }

  /// Save a category (create or update)
  Future<void> saveCategory(Category category) async {
    // Repository handles sync coordination automatically
    await _categoryRepository.saveCategory(category);
  }

  /// Archive a category (soft delete) - sets archived flag to true
  ///
  /// Soft delete - marks category as archived but keeps it referenceable.
  /// This is the recommended approach for categories since they may be
  /// referenced by external applications.
  Future<void> archiveCategory(String id) async {
    await _categoryRepository.archiveCategory(id);
  }

  /// Create a new category with generated ID
  Category createCategory({
    required String name,
    String? description,
    String? color,
    String? icon,
  }) {
    CategoryDisplaySettings? settings;
    if (color != null || icon != null) {
      settings = CategoryDisplaySettings(color: color, icon: icon);
    }

    return Category(
      id: _generateCategoryId(),
      name: name,
      description: description,
      settings: settings,
    );
  }

  /// Generate a unique ID for new categories
  String _generateCategoryId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = Random().nextInt(999999);
    return 'category_${timestamp}_$random';
  }
}
