import 'package:locorda/locorda.dart';
import 'package:locorda_objects/src/config/locorda_config_util.dart';
import 'package:test/test.dart';
import 'package:locorda_rdf_core/core.dart';

// Test model classes
class TestNote {
  final String title;
  final String content;
  TestNote(this.title, this.content);
}

class TestNoteIndex {
  final String title;
  TestNoteIndex(this.title);
}

class TestContact {
  final String name;
  final String email;
  TestContact(this.name, this.email);
}

class TestContactIndex {
  final String name;
  TestContactIndex(this.name);
}

void main() {
  group('SyncConfig.findIndexConfigForType', () {
    late LocordaConfig config;
    late ResourceConfig noteResourceConfig;
    late ResourceConfig contactResourceConfig;
    late FullIndexConfig noteIndex;
    late FullIndexConfig contactIndex;

    setUp(() {
      // Set up test configurations
      final noteIndexItem = IndexItemConfig(
          TestNoteIndex, {const IriTerm('http://example.org/title')});
      noteIndex = FullIndexConfig(
        localName: 'note-title-index',
        item: noteIndexItem,
      );

      final contactIndexItem = IndexItemConfig(
          TestContactIndex, {const IriTerm('http://example.org/name')});
      contactIndex = FullIndexConfig(
        localName: 'contact-name-index',
        item: contactIndexItem,
      );

      noteResourceConfig = ResourceConfig(
        type: TestNote,
        crdtMapping: Uri.parse('http://example.org/note-mapping'),
        indices: [noteIndex],
      );

      contactResourceConfig = ResourceConfig(
        type: TestContact,
        crdtMapping: Uri.parse('http://example.org/contact-mapping'),
        indices: [contactIndex],
      );

      config = LocordaConfig(
        resources: [noteResourceConfig, contactResourceConfig],
      );
    });

    test('should find correct index config for matching type and local name',
        () {
      final result =
          findIndexConfigForType<TestNoteIndex>(config, 'note-title-index');

      expect(result, isNotNull);
      final (resourceConfig, indexConfig) = result!;
      expect(resourceConfig, equals(noteResourceConfig));
      expect(indexConfig, equals(noteIndex));
    });

    test('should find correct index config for different resource type', () {
      final result = findIndexConfigForType<TestContactIndex>(
          config, 'contact-name-index');

      expect(result, isNotNull);
      final (resourceConfig, indexConfig) = result!;
      expect(resourceConfig, equals(contactResourceConfig));
      expect(indexConfig, equals(contactIndex));
    });

    test('should return null for non-existent type', () {
      final result = findIndexConfigForType<String>(config, 'note-title-index');

      expect(result, isNull);
    });

    test('should return null for non-existent local name', () {
      final result =
          findIndexConfigForType<TestNoteIndex>(config, 'non-existent-index');

      expect(result, isNull);
    });

    test('should return null for mismatched type and local name combination',
        () {
      // Wrong type for contact index
      final result =
          findIndexConfigForType<TestNoteIndex>(config, 'contact-name-index');

      expect(result, isNull);
    });

    test('should handle resource with multiple indices', () {
      // Add another index to the note resource
      final noteTagsIndexItem =
          IndexItemConfig(String, {const IriTerm('http://example.org/tags')});
      final noteTagsIndex = FullIndexConfig(
        localName: 'note-tags-index',
        item: noteTagsIndexItem,
      );

      final multiIndexResourceConfig = ResourceConfig(
        type: TestNote,
        crdtMapping: Uri.parse('http://example.org/note-mapping'),
        indices: [noteIndex, noteTagsIndex],
      );

      final multiIndexConfig = LocordaConfig(
        resources: [multiIndexResourceConfig, contactResourceConfig],
      );

      // Should find the correct index even with multiple indices
      final noteIndexResult = findIndexConfigForType<TestNoteIndex>(
          multiIndexConfig, 'note-title-index');
      expect(noteIndexResult, isNotNull);
      expect(noteIndexResult!.$2, equals(noteIndex));

      final tagsIndexResult =
          findIndexConfigForType<String>(multiIndexConfig, 'note-tags-index');
      expect(tagsIndexResult, isNotNull);
      expect(tagsIndexResult!.$2, equals(noteTagsIndex));
    });

    test('should handle resource with no indices', () {
      final noIndexResourceConfig = ResourceConfig(
        type: String,
        crdtMapping: Uri.parse('http://example.org/string-mapping'),
        indices: [], // No indices
      );

      final noIndexConfig = LocordaConfig(
        resources: [noIndexResourceConfig, noteResourceConfig],
      );

      // Should still find note index
      final noteResult = findIndexConfigForType<TestNoteIndex>(
          noIndexConfig, 'note-title-index');
      expect(noteResult, isNotNull);

      // Should not find anything for the resource with no indices
      final stringResult =
          findIndexConfigForType<String>(noIndexConfig, 'any-index');
      expect(stringResult, isNull);
    });

    test('should handle index with null item', () {
      final nullItemIndex = FullIndexConfig(
        localName: 'null-item-index',
        item: null, // No item specified
      );

      final nullItemResourceConfig = ResourceConfig(
        type: TestNote,
        crdtMapping: Uri.parse('http://example.org/note-mapping'),
        indices: [nullItemIndex],
      );

      final nullItemConfig = LocordaConfig(
        resources: [nullItemResourceConfig],
      );

      // Should not find anything since item is null
      final result = findIndexConfigForType<TestNoteIndex>(
          nullItemConfig, 'null-item-index');
      expect(result, isNull);
    });

    test('should handle empty configuration', () {
      final emptyConfig = LocordaConfig(resources: []);

      final result =
          findIndexConfigForType<TestNoteIndex>(emptyConfig, 'any-index');
      expect(result, isNull);
    });

    test('should distinguish between different local names for same type', () {
      // Create two indices with same item type but different local names
      final noteIndexItem1 = IndexItemConfig(
          TestNoteIndex, {const IriTerm('http://example.org/title')});
      final noteIndexItem2 = IndexItemConfig(
          TestNoteIndex, {const IriTerm('http://example.org/content')});

      final noteIndex1 = FullIndexConfig(
        localName: 'note-title-index',
        item: noteIndexItem1,
      );

      final noteIndex2 = FullIndexConfig(
        localName: 'note-content-index',
        item: noteIndexItem2,
      );

      final multiSameTypeResourceConfig = ResourceConfig(
        type: TestNote,
        crdtMapping: Uri.parse('http://example.org/note-mapping'),
        indices: [noteIndex1, noteIndex2],
      );

      final multiSameTypeConfig = LocordaConfig(
        resources: [multiSameTypeResourceConfig],
      );

      // Should find the correct index based on local name
      final titleResult = findIndexConfigForType<TestNoteIndex>(
          multiSameTypeConfig, 'note-title-index');
      expect(titleResult, isNotNull);
      expect(titleResult!.$2, equals(noteIndex1));

      final contentResult = findIndexConfigForType<TestNoteIndex>(
          multiSameTypeConfig, 'note-content-index');
      expect(contentResult, isNotNull);
      expect(contentResult!.$2, equals(noteIndex2));
    });
  });
}
