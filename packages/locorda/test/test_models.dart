/// Test model classes for configuration validation tests.
library;

import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_rdf_mapper/mapper.dart';

/// Test vocabulary constants
class TestVocab {
  static const baseIri = 'https://test.example/vocab#';
  static const testDocument = IriTerm('${baseIri}TestDocument');
  static const testCategory = IriTerm('${baseIri}TestCategory');
  static const testNote = IriTerm('${baseIri}TestNote');
  static const note = IriTerm('${baseIri}Note');
  static const noteIndex = IriTerm('${baseIri}NoteIndex');
  static const sameTypeIri = IriTerm('${baseIri}SameType');
}

/// Test document model
class TestDocument {
  final String id;
  final String title;
  final String category;
  TestDocument({required this.id, required this.title, required this.category});
}

class TestDocumentGroupKey {
  final String category;
  TestDocumentGroupKey({required this.category});
}

class DateTimeGroupKey {
  final DateTime createdAt;
  DateTimeGroupKey({required this.createdAt});
}

/// Group key with multiple grouping properties for complex testing
class MultiPropertyGroupKey {
  final String category;
  final String priority;
  final String department;
  MultiPropertyGroupKey({
    required this.category,
    required this.priority,
    required this.department,
  });
}

/// Group key with IRI properties to test filesystem safety
class IriPropertyGroupKey {
  final String category;
  final Uri resourceIri;
  final Uri relatedDocument;
  IriPropertyGroupKey({
    required this.category,
    required this.resourceIri,
    required this.relatedDocument,
  });
}

/// Test category model
class TestCategory {
  final String id;
  final String name;

  TestCategory({required this.id, required this.name});
}

/// Test note model
class TestNote {
  final String id;
  final String content;

  TestNote({required this.id, required this.content});
}

/// Note model for testing IndexConverter
class Note {
  final String id;
  final String title;
  final String content;
  final DateTime createdAt;
  final DateTime updatedAt;

  Note({
    required this.id,
    required this.title,
    required this.content,
    required this.createdAt,
    required this.updatedAt,
  });
}

/// Note index item for testing IndexConverter
class NoteIndex {
  final String title;
  final DateTime createdAt;

  NoteIndex({
    required this.title,
    required this.createdAt,
  });
}

/// Two classes that would have the same RDF type IRI (for collision testing)
class ConflictingTypeA {
  final String id;
  ConflictingTypeA({required this.id});
}

class ConflictingTypeB {
  final String id;
  ConflictingTypeB({required this.id});
}

/// Type without any RDF mapping (for missing type IRI testing)
class UnmappedType {
  final String id;
  UnmappedType({required this.id});
}

/// Create a mock RDF mapper for testing type IRI resolution
RdfMapper createTestMapper() {
  // We'll use a real RdfMapper but override the getTypeIri function in tests
  return RdfMapper(
    registry: RdfMapperRegistry()
      ..registerMapper(MockResourceMapper<TestDocument>(TestVocab.testDocument))
      ..registerMapper(TestDocumentGroupKeyMapper())
      ..registerMapper(MultiPropertyGroupKeyMapper())
      ..registerMapper(IriPropertyGroupKeyMapper())
      ..registerMapper(MockResourceMapper<TestCategory>(TestVocab.testCategory))
      ..registerMapper(MockResourceMapper<TestNote>(TestVocab.testNote))
      ..registerMapper(MockResourceMapper<Note>(TestVocab.note))
      ..registerMapper(MockResourceMapper<NoteIndex>(TestVocab.noteIndex))
      ..registerMapper(
          MockResourceMapper<ConflictingTypeA>(TestVocab.sameTypeIri))
      ..registerMapper(
          MockResourceMapper<ConflictingTypeB>(TestVocab.sameTypeIri))
      ..registerMapper(DateTimeGroupKeyMapper())
    // Note: UnmappedType is intentionally not registered
    ,
    rdfCore: RdfCore.withStandardCodecs(),
  );
}

/// Mock function that simulates type IRI resolution for testing
IriTerm? mockGetTypeIri(Type dartType) {
  // Map of Dart types to their RDF type IRIs for testing
  const typeMap = <Type, IriTerm>{
    TestDocument: TestVocab.testDocument,
    TestCategory: TestVocab.testCategory,
    TestNote: TestVocab.testNote,
    ConflictingTypeA: TestVocab.sameTypeIri,
    ConflictingTypeB: TestVocab.sameTypeIri, // Same IRI for collision testing
    // UnmappedType is intentionally not included
  };

  return typeMap[dartType];
}

/// Mock resource serializer for testing
class MockResourceMapper<T> implements GlobalResourceMapper<T> {
  final IriTerm typeIri;
  MockResourceMapper(this.typeIri);

  @override
  T fromRdfResource(IriTerm term, DeserializationContext context) {
    throw UnimplementedError();
  }

  @override
  (IriTerm, Iterable<Triple>) toRdfResource(
      T value, SerializationContext context,
      {RdfSubject? parentSubject}) {
    throw UnimplementedError();
  }
}

class TestDocumentGroupKeyMapper
    implements LocalResourceMapper<TestDocumentGroupKey> {
  @override
  IriTerm? get typeIri => null;

  @override
  TestDocumentGroupKey fromRdfResource(
      BlankNodeTerm subject, DeserializationContext context) {
    final reader = context.reader(subject);
    final String category =
        reader.require(TestVocab.testCategory); // Assuming it's a string
    return TestDocumentGroupKey(category: category);
  }

  @override
  (BlankNodeTerm, Iterable<Triple>) toRdfResource(
      TestDocumentGroupKey resource, SerializationContext context,
      {RdfSubject? parentSubject}) {
    final subject = BlankNodeTerm();
    return context
        .resourceBuilder(subject)
        .addValue(TestVocab.testCategory, resource.category)
        .build();
  }
}

class MultiPropertyGroupKeyMapper
    implements LocalResourceMapper<MultiPropertyGroupKey> {
  @override
  IriTerm? get typeIri => null;

  @override
  MultiPropertyGroupKey fromRdfResource(
      BlankNodeTerm subject, DeserializationContext context) {
    final reader = context.reader(subject);
    final String category = reader.require(TestVocab.testCategory);
    final String priority = reader.require(const IriTerm(
        'https://test.example/vocab#priority')); // Assuming it's a string
    final String department = reader.require(const IriTerm(
        'https://test.example/vocab#department')); // Assuming it's a string
    return MultiPropertyGroupKey(
      category: category,
      priority: priority,
      department: department,
    );
  }

  @override
  (BlankNodeTerm, Iterable<Triple>) toRdfResource(
      MultiPropertyGroupKey resource, SerializationContext context,
      {RdfSubject? parentSubject}) {
    final subject = BlankNodeTerm();
    return context
        .resourceBuilder(subject)
        .addValue(TestVocab.testCategory, resource.category)
        .addValue(const IriTerm('https://test.example/vocab#priority'),
            resource.priority)
        .addValue(const IriTerm('https://test.example/vocab#department'),
            resource.department)
        .build();
  }
}

class IriPropertyGroupKeyMapper
    implements LocalResourceMapper<IriPropertyGroupKey> {
  @override
  IriTerm? get typeIri => null;

  @override
  IriPropertyGroupKey fromRdfResource(
      BlankNodeTerm subject, DeserializationContext context) {
    final reader = context.reader(subject);
    final String category = reader.require(TestVocab.testCategory);
    final Uri resourceIri = Uri.parse(reader
        .require(const IriTerm('https://test.example/vocab#resourceIri')));
    final Uri relatedDocument = Uri.parse(reader
        .require(const IriTerm('https://test.example/vocab#relatedDocument')));
    return IriPropertyGroupKey(
      category: category,
      resourceIri: resourceIri,
      relatedDocument: relatedDocument,
    );
  }

  @override
  (BlankNodeTerm, Iterable<Triple>) toRdfResource(
      IriPropertyGroupKey resource, SerializationContext context,
      {RdfSubject? parentSubject}) {
    final subject = BlankNodeTerm();
    return context
        .resourceBuilder(subject)
        .addValue(TestVocab.testCategory, resource.category)
        .addValue(const IriTerm('https://test.example/vocab#resourceIri'),
            resource.resourceIri.toString())
        .addValue(const IriTerm('https://test.example/vocab#relatedDocument'),
            resource.relatedDocument.toString())
        .build();
  }
}

class DateTimeGroupKeyMapper implements LocalResourceMapper<DateTimeGroupKey> {
  @override
  IriTerm? get typeIri => null;

  @override
  DateTimeGroupKey fromRdfResource(
      BlankNodeTerm subject, DeserializationContext context) {
    final reader = context.reader(subject);
    final String createdAtStr = reader.require(const IriTerm(
        'https://test.example/vocab#createdAt')); // Assuming it's a string
    final DateTime createdAt = DateTime.parse(createdAtStr);
    return DateTimeGroupKey(createdAt: createdAt);
  }

  @override
  (BlankNodeTerm, Iterable<Triple>) toRdfResource(
      DateTimeGroupKey resource, SerializationContext context,
      {RdfSubject? parentSubject}) {
    final subject = BlankNodeTerm();
    return context
        .resourceBuilder(subject)
        .addValue(const IriTerm('https://test.example/vocab#createdAt'),
            resource.createdAt.toIso8601String())
        .build();
  }
}
