import 'package:locorda_objects/src/config/locorda_config_util.dart';
import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_rdf_mapper/mapper.dart';
import 'package:test/test.dart';

import 'package:locorda_objects/src/mapping/local_resource_iri_service.dart';

// Mock types for testing
class TestNote {}

class TestCategory {}

class TestUser {}

void main() {
  group('LocalResourceIriService', () {
    late LocalResourceIriService service;
    late ResourceTypeCache mockResourceTypeCache;
    late RootIriConfig mockConfig;

    setUp(() {
      service = LocalResourceIriService(
          LocalResourceLocator(iriTermFactory: IriTerm.validated));
      mockResourceTypeCache = ResourceTypeCache({
        TestNote: const IriTerm('http://example.org/Note'),
        TestCategory: const IriTerm('http://example.org/Category'),
        TestUser: const IriTerm('http://example.org/User'),
      });
      mockConfig = const RootIriConfig();
    });

    group('Programming Constraints (StateError)', () {
      test(
          'should throw StateError when creating resource mapper after setup complete',
          () {
        // Complete setup first
        service.createResourceIriMapper<TestNote>(mockConfig);
        service.finishSetupAndValidate(mockResourceTypeCache);

        // Now try to create another mapper - should throw immediately
        expect(
          () => service.createResourceIriMapper<TestCategory>(mockConfig),
          throwsA(isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('cannot be created after setup is complete'),
          )),
        );
      });

      test(
          'should throw StateError when creating reference mapper after setup complete',
          () {
        // Complete setup first
        service.createResourceIriMapper<TestNote>(mockConfig);
        service.finishSetupAndValidate(mockResourceTypeCache);

        // Now try to create a reference mapper - should throw immediately
        expect(
          () => service.createResourceRefMapper<String>(TestCategory),
          throwsA(isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('cannot be created after setup is complete'),
          )),
        );
      });
    });

    group('Configuration Validation', () {
      test('should collect validation error for duplicate type registration',
          () {
        // Register same type twice
        service.createResourceIriMapper<TestNote>(mockConfig);
        service.createResourceIriMapper<TestNote>(mockConfig);

        final result = service.validate(mockResourceTypeCache);

        expect(result.isValid, isFalse);
        expect(result.errors, hasLength(1));
        expect(result.errors.first.message, contains('already registered'));
        expect(
            (result.errors.first.details as Map?)?['type'], equals(TestNote));
      });

      test('should collect validation error for unreferenced types', () {
        // Create reference without registering the target type
        service.createResourceRefMapper<String>(TestUser);

        final result = service.validate(mockResourceTypeCache);

        expect(result.isValid, isFalse);
        expect(result.errors, hasLength(1));
        expect(result.errors.first.message,
            contains('was not registered as a resource type'));
        expect((result.errors.first.details as Map?)?['referencedType'],
            equals(TestUser));
      });

      test(
          'should collect validation error for missing IRI in resource type cache',
          () {
        service.createResourceIriMapper<TestNote>(mockConfig);

        // Pass cache missing the registered type
        final incompleteCacheCache = ResourceTypeCache(<Type, IriTerm>{});
        final result = service.validate(incompleteCacheCache);

        expect(result.isValid, isFalse);
        expect(result.errors, hasLength(1));
        expect(result.errors.first.message,
            contains('Missing IRI term for registered type'));
        expect(
            (result.errors.first.details as Map?)?['type'], equals(TestNote));
      });

      test('should collect multiple validation errors', () {
        // Create multiple validation issues
        service.createResourceIriMapper<TestNote>(mockConfig);
        service.createResourceIriMapper<TestNote>(mockConfig); // Duplicate
        service.createResourceRefMapper<String>(TestUser); // Unreferenced

        final result = service.validate(mockResourceTypeCache);

        expect(result.isValid, isFalse);
        expect(result.errors, hasLength(2)); // Duplicate + unreferenced

        final errorMessages = result.errors.map((e) => e.message).toList();
        expect(errorMessages.any((msg) => msg.contains('already registered')),
            isTrue);
        expect(errorMessages.any((msg) => msg.contains('was not registered')),
            isTrue);
      });
    });

    group('State Machine Behavior', () {
      test('should succeed validation with proper setup', () {
        service.createResourceIriMapper<TestNote>(mockConfig);
        service.createResourceIriMapper<TestCategory>(mockConfig);
        service.createResourceRefMapper<String>(TestNote);

        final result = service.validate(mockResourceTypeCache);

        expect(result.isValid, isTrue);
        expect(result.errors, isEmpty);
        expect(result.warnings, isEmpty);
      });

      test('should transition to runtime state only on successful validation',
          () {
        service.createResourceIriMapper<TestNote>(mockConfig);

        final result = service.finishSetupAndValidate(mockResourceTypeCache);

        expect(result.isValid, isTrue);

        // Should now throw StateError for new mapper creation
        expect(
          () => service.createResourceIriMapper<TestCategory>(mockConfig),
          throwsA(isA<StateError>()),
        );
      });

      test('should remain in setup state if validation fails', () {
        service.createResourceIriMapper<TestNote>(mockConfig);
        service.createResourceIriMapper<TestNote>(
            mockConfig); // Duplicate - validation error

        final result = service.finishSetupAndValidate(mockResourceTypeCache);

        expect(result.isValid, isFalse);

        // Should still be in setup state - no StateError thrown
        expect(
          () => service.createResourceIriMapper<TestCategory>(mockConfig),
          returnsNormally,
        );
      });
    });

    group('IRI Mapper Creation', () {
      test('should create resource IRI mapper with correct scheme', () {
        final mapper = service.createResourceIriMapper<TestNote>(mockConfig);
        service.finishSetupAndValidate(mockResourceTypeCache);

        // Test forward mapping (tuple to IRI)
        final iri = mapper.toRdfTerm(('note123',), MockSerializationContext());
        expect(
            iri.value,
            equals(
                'tag:locorda.org,2025:l:aHR0cDovL2V4YW1wbGUub3JnL05vdGU=:bm90ZTEyMw==#it'));

        // Test reverse mapping (IRI to tuple)
        final tuple = mapper.fromRdfTerm(
            IriTerm.validated(
                'tag:locorda.org,2025:l:aHR0cDovL2V4YW1wbGUub3JnL05vdGU=:bm90ZTQ1Ng==#it'),
            MockDeserializationContext());
        expect(tuple, equals(('note456',)));
      });

      test('should create reference IRI mapper with same scheme as resource',
          () {
        final resourceMapper =
            service.createResourceIriMapper<TestNote>(mockConfig);
        final refMapper = service.createResourceRefMapper<String>(TestNote);
        service.finishSetupAndValidate(mockResourceTypeCache);

        // Both should generate the same IRI for the same ID
        final resourceIri =
            resourceMapper.toRdfTerm(('note123',), MockSerializationContext());
        final refIri =
            refMapper.toRdfTerm('note123', MockSerializationContext());

        expect(resourceIri.value, equals(refIri.value));
        expect(
            resourceIri.value,
            equals(
                'tag:locorda.org,2025:l:aHR0cDovL2V4YW1wbGUub3JnL05vdGU=:bm90ZTEyMw==#it'));
      });

      test('should validate IRI patterns in reverse mapping', () {
        final mapper = service.createResourceIriMapper<TestNote>(mockConfig);
        service.finishSetupAndValidate(mockResourceTypeCache);

        expect(
          () => mapper.fromRdfTerm(
              const IriTerm('http://invalid.com/wrong/pattern'),
              MockDeserializationContext()),
          throwsA(isA<UnsupportedIriException>().having(
            (e) => e.toString(),
            'message',
            contains('Does not belong to base IRI tag:locorda.org,2025:l:'),
          )),
        );
      });
    });
  });
}

// Mock classes for testing
class MockSerializationContext implements SerializationContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MockDeserializationContext implements DeserializationContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
