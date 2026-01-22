import 'package:locorda_core/locorda_core.dart';
import 'package:test/test.dart';
import 'package:locorda_rdf_core/core.dart';

void main() {
  group('SyncEngineConfigValidator', () {
    late SyncEngineConfigValidator validator;

    setUp(() {
      validator = SyncEngineConfigValidator();
    });

    group('Resource Uniqueness Validation', () {
      test('should pass with unique type IRIs', () {
        final config = SyncEngineConfig(
          resources: [
            ResourceConfigData(
              typeIri: const IriTerm('https://example.org/Document'),
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [],
            ),
            ResourceConfigData(
              typeIri: const IriTerm('https://example.org/Category'),
              crdtMapping: Uri.parse('https://example.com/category.ttl'),
              indices: [],
            ),
          ],
        );

        final result = validator.validate(config);
        expect(result.isValid, isTrue);
        expect(result.errors, isEmpty);
      });

      test('should fail with duplicate type IRIs', () {
        final duplicateIri = const IriTerm('https://example.org/Document');
        final config = SyncEngineConfig(
          resources: [
            ResourceConfigData(
              typeIri: duplicateIri,
              crdtMapping: Uri.parse('https://example.com/document1.ttl'),
              indices: [],
            ),
            ResourceConfigData(
              typeIri: duplicateIri, // Duplicate!
              crdtMapping: Uri.parse('https://example.com/document2.ttl'),
              indices: [],
            ),
          ],
        );

        final result = validator.validate(config);
        expect(result.isValid, isFalse);
        expect(result.errors, hasLength(1));
        expect(
            result.errors.first.message, contains('Duplicate resource type'));
      });
    });

    group('CRDT Mapping Validation', () {
      test('should pass with absolute HTTPS URIs', () {
        final config = SyncEngineConfig(
          resources: [
            ResourceConfigData(
              typeIri: const IriTerm('https://example.org/Document'),
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [],
            ),
          ],
        );

        final result = validator.validate(config);
        expect(result.isValid, isTrue);
        expect(result.errors, isEmpty);
      });

      test('should fail with relative URIs', () {
        final config = SyncEngineConfig(
          resources: [
            ResourceConfigData(
              typeIri: const IriTerm('https://example.org/Document'),
              crdtMapping: Uri.parse('document.ttl'), // Relative!
              indices: [],
            ),
          ],
        );

        final result = validator.validate(config);
        expect(result.isValid, isFalse);
        expect(result.errors.any((e) => e.message.contains('must be absolute')),
            isTrue);
      });

      test('should warn with HTTP URIs', () {
        final config = SyncEngineConfig(
          resources: [
            ResourceConfigData(
              typeIri: const IriTerm('https://example.org/Document'),
              crdtMapping: Uri.parse('http://example.com/document.ttl'), // HTTP
              indices: [],
            ),
          ],
        );

        final result = validator.validate(config);
        expect(result.isValid, isTrue);
        expect(result.warnings, isNotEmpty);
        expect(
            result.warnings.any((w) => w.message.contains('should use HTTPS')),
            isTrue);
      });
    });

    group('Index Configuration Validation', () {
      test('should fail with empty local name', () {
        final config = SyncEngineConfig(
          resources: [
            ResourceConfigData(
              typeIri: const IriTerm('https://example.org/Document'),
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [
                FullIndexData(
                  localName: '', // Empty!
                  item: IndexItemData({
                    const IriTerm('https://schema.org/name'),
                  }),
                ),
              ],
            ),
          ],
        );

        final result = validator.validate(config);
        expect(result.isValid, isFalse);
        expect(
            result.errors
                .any((e) => e.message.contains('local name cannot be empty')),
            isTrue);
      });

      test(
          'should fail with empty grouping properties (constructor validation)',
          () {
        // The GroupIndexGraphConfig constructor itself validates empty grouping properties
        expect(
          () => GroupIndexData(
            localName: 'empty-groups',
            groupingProperties: [], // Empty!
          ),
          throwsA(isA<AssertionError>()),
        );
      });
    });

    group('GroupingProperty Validation', () {
      test('should fail with empty predicate IRI', () {
        final config = SyncEngineConfig(
          resources: [
            ResourceConfigData(
              typeIri: const IriTerm('https://example.org/Document'),
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [
                GroupIndexData(
                  localName: 'test-groups',
                  groupingProperties: [
                    GroupingProperty(
                      const IriTerm(''), // Empty IRI!
                    ),
                  ],
                ),
              ],
            ),
          ],
        );

        final result = validator.validate(config);
        expect(result.isValid, isFalse);
        expect(result.errors.any((e) => e.message.contains('Invalid IRI')),
            isTrue);
      });

      test('should fail with zero hierarchy level', () {
        final config = SyncEngineConfig(
          resources: [
            ResourceConfigData(
              typeIri: const IriTerm('https://example.org/Document'),
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [
                GroupIndexData(
                  localName: 'test-groups',
                  groupingProperties: [
                    GroupingProperty(
                      const IriTerm('https://schema.org/category'),
                      hierarchyLevel: 0, // Invalid!
                    ),
                  ],
                ),
              ],
            ),
          ],
        );

        final result = validator.validate(config);
        expect(result.isValid, isFalse);
        expect(
            result.errors.any(
                (e) => e.message.contains('hierarchy level must be positive')),
            isTrue);
      });

      test('should fail with negative hierarchy level', () {
        final config = SyncEngineConfig(
          resources: [
            ResourceConfigData(
              typeIri: const IriTerm('https://example.org/Document'),
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [
                GroupIndexData(
                  localName: 'test-groups',
                  groupingProperties: [
                    GroupingProperty(
                      const IriTerm('https://schema.org/category'),
                      hierarchyLevel: -1, // Invalid!
                    ),
                  ],
                ),
              ],
            ),
          ],
        );

        final result = validator.validate(config);
        expect(result.isValid, isFalse);
        expect(
            result.errors.any(
                (e) => e.message.contains('hierarchy level must be positive')),
            isTrue);
      });

      test('should fail with empty missing value', () {
        final config = SyncEngineConfig(
          resources: [
            ResourceConfigData(
              typeIri: const IriTerm('https://example.org/Document'),
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [
                GroupIndexData(
                  localName: 'test-groups',
                  groupingProperties: [
                    GroupingProperty(
                      const IriTerm('https://schema.org/category'),
                      missingValue: '', // Empty string!
                    ),
                  ],
                ),
              ],
            ),
          ],
        );

        final result = validator.validate(config);
        expect(result.isValid, isFalse);
        expect(
            result.errors.any(
                (e) => e.message.contains('missing value cannot be empty')),
            isTrue);
      });

      test('should pass with null missing value', () {
        final config = SyncEngineConfig(
          resources: [
            ResourceConfigData(
              typeIri: const IriTerm('https://example.org/Document'),
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [
                GroupIndexData(
                  localName: 'test-groups',
                  groupingProperties: [
                    GroupingProperty(
                      const IriTerm('https://schema.org/category'),
                      missingValue: null, // OK
                    ),
                  ],
                ),
              ],
            ),
          ],
        );

        final result = validator.validate(config);
        expect(result.isValid, isTrue);
        expect(result.errors, isEmpty);
      });
    });

    group('Regex Transform Validation', () {
      test('should fail with malformed regex patterns', () {
        final config = SyncEngineConfig(
          resources: [
            ResourceConfigData(
              typeIri: const IriTerm('https://example.org/Document'),
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [
                GroupIndexData(
                  localName: 'date-groups',
                  groupingProperties: [
                    GroupingProperty(
                      const IriTerm('https://schema.org/dateCreated'),
                      transforms: [
                        RegexTransform(
                          r'[invalid', // Malformed regex!
                          r'\${1}',
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ],
        );

        final result = validator.validate(config);
        expect(result.isValid, isFalse);
        expect(result.errors.any((e) => e.message.contains('pattern')), isTrue);
      });

      test('should fail with invalid capture group references', () {
        final config = SyncEngineConfig(
          resources: [
            ResourceConfigData(
              typeIri: const IriTerm('https://example.org/Document'),
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [
                GroupIndexData(
                  localName: 'date-groups',
                  groupingProperties: [
                    GroupingProperty(
                      const IriTerm('https://schema.org/dateCreated'),
                      transforms: [
                        RegexTransform(
                          r'([0-9]{4})', // Only 1 capture group
                          r'\${2}', // But referencing group 2!
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ],
        );

        final result = validator.validate(config);
        expect(result.isValid, isFalse);
        expect(result.errors.any((e) => e.message.contains('capture group')),
            isTrue);
      });

      test('should pass with valid regex transforms', () {
        final config = SyncEngineConfig(
          resources: [
            ResourceConfigData(
              typeIri: const IriTerm('https://example.org/Document'),
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [
                GroupIndexData(
                  localName: 'date-groups',
                  groupingProperties: [
                    GroupingProperty(
                      const IriTerm('https://schema.org/dateCreated'),
                      transforms: [
                        RegexTransform(
                          r'^([0-9]{4})-([0-9]{2})-([0-9]{2}).*',
                          r'\${1}-\${2}', // Valid capture group references
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ],
        );

        final result = validator.validate(config);
        expect(result.isValid, isTrue);
        expect(result.errors, isEmpty);
      });
    });

    group('Hierarchy Level Validation', () {
      test('should warn about hierarchy level gaps', () {
        final config = SyncEngineConfig(
          resources: [
            ResourceConfigData(
              typeIri: const IriTerm('https://example.org/Document'),
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [
                GroupIndexData(
                  localName: 'test-groups',
                  groupingProperties: [
                    GroupingProperty(
                      const IriTerm('https://schema.org/category'),
                      hierarchyLevel: 1,
                    ),
                    GroupingProperty(
                      const IriTerm('https://schema.org/priority'),
                      hierarchyLevel: 3, // Gap! (missing level 2)
                    ),
                  ],
                ),
              ],
            ),
          ],
        );

        final result = validator.validate(config);
        expect(result.isValid, isTrue);
        expect(
            result.warnings
                .any((w) => w.message.contains('Hierarchy level gap')),
            isTrue);
      });

      test('should pass with consecutive hierarchy levels', () {
        final config = SyncEngineConfig(
          resources: [
            ResourceConfigData(
              typeIri: const IriTerm('https://example.org/Document'),
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [
                GroupIndexData(
                  localName: 'test-groups',
                  groupingProperties: [
                    GroupingProperty(
                      const IriTerm('https://schema.org/category'),
                      hierarchyLevel: 1,
                    ),
                    GroupingProperty(
                      const IriTerm('https://schema.org/priority'),
                      hierarchyLevel: 2, // Consecutive
                    ),
                  ],
                ),
              ],
            ),
          ],
        );

        final result = validator.validate(config);
        expect(result.isValid, isTrue);
        expect(result.warnings.any((w) => w.message.contains('gap')), isFalse);
      });
    });

    group('Complex Configuration Validation', () {
      test('should validate multiple resources with various indices', () {
        final config = SyncEngineConfig(
          resources: [
            ResourceConfigData(
              typeIri: const IriTerm('https://example.org/Document'),
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [
                FullIndexData(
                  localName: 'full-index',
                  item: IndexItemData({
                    const IriTerm('https://schema.org/name'),
                    const IriTerm('https://schema.org/dateCreated'),
                  }),
                ),
                GroupIndexData(
                  localName: 'category-groups',
                  groupingProperties: [
                    GroupingProperty(
                      const IriTerm('https://schema.org/category'),
                    ),
                  ],
                ),
              ],
            ),
            ResourceConfigData(
              typeIri: const IriTerm('https://example.org/Category'),
              crdtMapping: Uri.parse('https://example.com/category.ttl'),
              indices: [
                GroupIndexData(
                  localName: 'date-groups',
                  groupingProperties: [
                    GroupingProperty(
                      const IriTerm('https://schema.org/dateCreated'),
                      transforms: [
                        RegexTransform(
                          r'^([0-9]{4})-([0-9]{2})-([0-9]{2}).*',
                          r'\${1}', // Extract year
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ],
        );

        final result = validator.validate(config);
        expect(result.isValid, isTrue);
        expect(result.errors, isEmpty);
      });
    });
  });
}
