import 'package:locorda/locorda.dart';
import 'package:locorda_objects/src/config/locorda_config_util.dart';
import 'package:locorda_objects/src/config/locorda_config_validator.dart';
import 'package:locorda_core/src/config/validation.dart';
import 'package:test/test.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_rdf_mapper/mapper.dart';

import '../test_models.dart';

void main() {
  group('SyncConfig Validation', () {
    late RdfMapper mockMapper;

    setUp(() {
      mockMapper = createTestMapper();
    });

    group('Resource Uniqueness Validation', () {
      test('should pass with unique Dart types', () {
        final config = LocordaConfig(
          resources: [
            ResourceConfig(
              type: TestDocument,
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
            ),
            ResourceConfig(
              type: TestCategory,
              crdtMapping: Uri.parse('https://example.com/category.ttl'),
            ),
          ],
        );

        final result = validate(config, mockMapper);
        expect(result.isValid, isTrue);
        expect(result.errors, isEmpty);
      });

      test('should fail with duplicate Dart types', () {
        final config = LocordaConfig(
          resources: [
            ResourceConfig(
              type: TestDocument,
              crdtMapping: Uri.parse('https://example.com/document1.ttl'),
            ),
            ResourceConfig(
              type: TestDocument, // Duplicate!
              crdtMapping: Uri.parse('https://example.com/document2.ttl'),
            ),
          ],
        );

        final result = validate(config, mockMapper);
        expect(result.isValid, isFalse);
        expect(result.errors, hasLength(1));
        expect(
            result.errors.first.message, contains('Duplicate resource type'));
        expect(result.errors.first.message, contains('TestDocument'));
      });

      test('should fail with RDF type IRI collisions', () {
        final config = LocordaConfig(
          resources: [
            ResourceConfig(
              type: ConflictingTypeA,
              crdtMapping: Uri.parse('https://example.com/typeA.ttl'),
            ),
            ResourceConfig(
              type: ConflictingTypeB,
              crdtMapping: Uri.parse('https://example.com/typeB.ttl'),
            ),
          ],
        );

        final result = validate(config, mockMapper);
        expect(result.isValid, isFalse);
        expect(result.errors, hasLength(1));
        expect(result.errors.first.message, contains('RDF type IRI collision'));
        expect(result.errors.first.message, contains('ConflictingTypeA'));
        expect(result.errors.first.message, contains('ConflictingTypeB'));
      });

      test('should fail when type has no RDF IRI mapping', () {
        final config = LocordaConfig(
          resources: [
            ResourceConfig(
              type: UnmappedType,
              crdtMapping: Uri.parse('https://example.com/unmapped.ttl'),
            ),
          ],
        );

        final result = validate(config, mockMapper);
        expect(result.isValid, isFalse);
        expect(result.errors, hasLength(2));
        final last = result.errors.last;
        final first = result.errors.first;
        expect(first.message,
            contains('Type UnmappedType is not registered in RdfMapper'));
        expect(last.message, contains('No RDF type IRI found'));
        expect(last.message, contains('UnmappedType'));
        expect(last.message, contains('@PodResource'));
      });
    });

    group('CRDT Mapping Validation', () {
      test('should fail with relative URI', () {
        final config = LocordaConfig(
          resources: [
            ResourceConfig(
              type: TestDocument,
              crdtMapping: Uri.parse('mappings/document.ttl'), // Relative!
            ),
          ],
        );

        final result = validate(config, mockMapper);
        expect(result.isValid, isFalse);
        expect(result.errors.any((e) => e.message.contains('must be absolute')),
            isTrue);
      });

      test('should warn about HTTP (non-HTTPS) URI', () {
        final config = LocordaConfig(
          resources: [
            ResourceConfig(
              type: TestDocument,
              crdtMapping: Uri.parse(
                  'http://example.com/document.ttl'), // HTTP not HTTPS!
            ),
          ],
        );

        final result = validate(config, mockMapper);
        expect(result.isValid, isTrue);
        expect(result.warnings, isNotEmpty);
        expect(
            result.warnings.any((e) => e.message.contains('should use HTTPS')),
            isTrue);
      });
    });

    group('Index Configuration Validation', () {
      test('should fail with empty index local name', () {
        final config = LocordaConfig(
          resources: [
            ResourceConfig(
              type: TestDocument,
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [
                FullIndexConfig(localName: ''), // Empty local name!
              ],
            ),
          ],
        );

        final result = validate(config, mockMapper);
        expect(result.isValid, isFalse);
        expect(
            result.errors
                .any((e) => e.message.contains('local name cannot be empty')),
            isTrue);
      });

      test('should fail with duplicate local names for same index item type',
          () {
        final testIndexItem = IndexItemConfig(TestDocument, {});

        final config = LocordaConfig(
          resources: [
            ResourceConfig(
              type: TestDocument,
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [
                FullIndexConfig(localName: 'shared', item: testIndexItem),
              ],
            ),
            ResourceConfig(
              type: TestCategory,
              crdtMapping: Uri.parse('https://example.com/category.ttl'),
              indices: [
                FullIndexConfig(
                    localName: 'shared',
                    item: testIndexItem), // Same local name, same item type!
              ],
            ),
          ],
        );

        final result = validate(config, mockMapper);
        expect(result.isValid, isFalse);
        expect(
            result.errors
                .any((e) => e.message.contains('Duplicate index local name')),
            isTrue);
      });

      test('should fail when GroupIndex has no grouping properties', () {
        // Test that the constructor itself prevents creating invalid GroupIndex
        expect(
          () => GroupIndexConfig(
            TestDocumentGroupKey,
            item: IndexItemConfig(TestDocument, {}),
            groupingProperties: [], // Empty!
          ),
          throwsA(isA<AssertionError>()),
        );

        // The validation would catch this if the constructor allowed it
        // But since the constructor prevents it, we test the constructor behavior instead
      });
    });

    group('GroupIndex Configuration Validation', () {
      test('should pass with valid single-property GroupIndex', () {
        final config = LocordaConfig(
          resources: [
            ResourceConfig(
              type: TestDocument,
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [
                GroupIndexConfig(
                  TestDocumentGroupKey,
                  groupingProperties: [
                    GroupingPropertyData(TestVocab.testCategory),
                  ],
                ),
              ],
            ),
          ],
        );

        final result = validate(config, mockMapper);
        expect(result.isValid, isTrue);
        expect(result.errors, isEmpty);
      });

      test(
          'should fail with invalid regex pattern and call RegexTransform validation',
          () {
        final config = LocordaConfig(
          resources: [
            ResourceConfig(
              type: TestDocument,
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [
                GroupIndexConfig(
                  TestDocumentGroupKey,
                  localName: 'invalid-regex',
                  groupingProperties: [
                    GroupingPropertyData(
                      TestVocab.testCategory,
                      transforms: [
                        RegexTransformData(
                          r'^(work|personal)$', // Contains alternation - should fail!
                          r'${1}',
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ],
        );

        final result = validate(config, mockMapper);
        expect(result.isValid, isFalse);
        expect(
            result.errors.any((e) =>
                e.message.contains('alternation') &&
                e.message.contains('RegexTransform')),
            isTrue,
            reason:
                'Should call RegexTransform validation and report alternation error');
      });

      test(
          'should fail with invalid replacement syntax through RegexTransform validation',
          () {
        final config = LocordaConfig(
          resources: [
            ResourceConfig(
              type: TestDocument,
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [
                GroupIndexConfig(
                  TestDocumentGroupKey,
                  localName: 'invalid-replacement',
                  groupingProperties: [
                    GroupingPropertyData(
                      TestVocab.testCategory,
                      transforms: [
                        RegexTransformData(
                          r'^([a-z]+)$',
                          r'$1', // Should be ${1}!
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ],
        );

        final result = validate(config, mockMapper);
        expect(result.isValid, isFalse);
        expect(
            result.errors.any((e) => e.message.contains('replacement')), isTrue,
            reason:
                'RegexTransform validation should catch invalid replacement syntax');
      });

      test('should fail with duplicate groupKeyType and localName combinations',
          () {
        final config = LocordaConfig(
          resources: [
            ResourceConfig(
              type: TestDocument,
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [
                GroupIndexConfig(
                  TestDocumentGroupKey,
                  localName: 'shared-name',
                  groupingProperties: [
                    GroupingPropertyData(TestVocab.testCategory),
                  ],
                ),
              ],
            ),
            ResourceConfig(
              type: TestCategory,
              crdtMapping: Uri.parse('https://example.com/category.ttl'),
              indices: [
                GroupIndexConfig(
                  TestDocumentGroupKey, // Same groupKeyType!
                  localName: 'shared-name', // Same localName!
                  groupingProperties: [
                    GroupingPropertyData(TestVocab.testCategory),
                  ],
                ),
              ],
            ),
          ],
        );

        final result = validate(config, mockMapper);
        expect(result.isValid, isFalse);
        expect(
            result.errors.any((e) =>
                e.message.contains('Duplicate') &&
                e.message.contains('groupKeyType') &&
                e.message.contains('localName')),
            isTrue,
            reason:
                'Should validate uniqueness of groupKeyType and localName combination');
      });

      test('should allow same groupKeyType with different localNames', () {
        final config = LocordaConfig(
          resources: [
            ResourceConfig(
              type: TestDocument,
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [
                GroupIndexConfig(
                  TestDocumentGroupKey,
                  localName: 'by-category',
                  groupingProperties: [
                    GroupingPropertyData(TestVocab.testCategory),
                  ],
                ),
              ],
            ),
            ResourceConfig(
              type: TestCategory,
              crdtMapping: Uri.parse('https://example.com/category.ttl'),
              indices: [
                GroupIndexConfig(
                  TestDocumentGroupKey, // Same groupKeyType is OK
                  localName: 'different-name', // Different localName
                  groupingProperties: [
                    GroupingPropertyData(TestVocab.testCategory),
                  ],
                ),
              ],
            ),
          ],
        );

        final result = validate(config, mockMapper);
        expect(result.isValid, isTrue);
        expect(result.errors, isEmpty);
      });

      test('should allow same localName with different groupKeyTypes', () {
        final config = LocordaConfig(
          resources: [
            ResourceConfig(
              type: TestDocument,
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [
                GroupIndexConfig(
                  TestDocumentGroupKey,
                  localName: 'by-category',
                  groupingProperties: [
                    GroupingPropertyData(TestVocab.testCategory),
                  ],
                ),
              ],
            ),
            ResourceConfig(
              type: TestCategory,
              crdtMapping: Uri.parse('https://example.com/category.ttl'),
              indices: [
                GroupIndexConfig(
                  MultiPropertyGroupKey, // Different groupKeyType
                  localName: 'by-category', // Same localName is OK
                  groupingProperties: [
                    GroupingPropertyData(TestVocab.testCategory),
                    GroupingPropertyData(
                        const IriTerm('https://test.example/vocab#priority')),
                  ],
                ),
              ],
            ),
          ],
        );

        final result = validate(config, mockMapper);
        expect(result.isValid, isTrue);
        expect(result.errors, isEmpty);
      });

      test('should fail when dartType has no mapper in registry', () {
        final config = LocordaConfig(
          resources: [
            ResourceConfig(
              type: UnmappedType, // This type has no mapper!
              crdtMapping: Uri.parse('https://example.com/unmapped.ttl'),
              indices: [
                GroupIndexConfig(
                  TestDocumentGroupKey,
                  localName: 'unmapped-dart-type',
                  groupingProperties: [
                    GroupingPropertyData(TestVocab.testCategory),
                  ],
                ),
              ],
            ),
          ],
        );

        final result = validate(config, mockMapper);
        expect(result.isValid, isFalse);
        expect(
            result.errors.any((e) =>
                e.message.contains('No RDF type IRI found') &&
                e.message.contains('UnmappedType')),
            isTrue,
            reason: 'Should validate dartType has mapper in registry');
      });

      test('should fail when groupKeyType has no mapper in registry', () {
        // Create a type that doesn't have a mapper registered
        final config = LocordaConfig(
          resources: [
            ResourceConfig(
              type: TestDocument,
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [
                GroupIndexConfig(
                  UnmappedType, // This groupKeyType has no mapper!
                  localName: 'unmapped-group-key',
                  groupingProperties: [
                    GroupingPropertyData(TestVocab.testCategory),
                  ],
                ),
              ],
            ),
          ],
        );

        final result = validate(config, mockMapper);
        expect(result.isValid, isFalse);
        expect(
            result.errors.any((e) =>
                e.message.contains('UnmappedType') &&
                e.message.contains('mapper')),
            isTrue,
            reason: 'Should validate groupKeyType has mapper in registry');
      });

      test('should fail when itemType has no mapper in registry', () {
        final config = LocordaConfig(
          resources: [
            ResourceConfig(
              type: TestDocument,
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [
                GroupIndexConfig(
                  TestDocumentGroupKey,
                  localName: 'unmapped-item-type',
                  item: IndexItemConfig(
                      UnmappedType, {}), // This itemType has no mapper!
                  groupingProperties: [
                    GroupingPropertyData(TestVocab.testCategory),
                  ],
                ),
              ],
            ),
          ],
        );

        final result = validate(config, mockMapper);
        expect(result.isValid, isFalse);
        expect(
            result.errors.any((e) =>
                e.message.contains('UnmappedType') &&
                e.message.contains('mapper')),
            isTrue,
            reason: 'Should validate itemType has mapper in registry');
      });

      test('should validate all types have proper mappers when all are valid',
          () {
        final config = LocordaConfig(
          resources: [
            ResourceConfig(
              type: TestDocument, // Has mapper
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [
                GroupIndexConfig(
                  TestDocumentGroupKey, // Has mapper
                  localName: 'all-mapped',
                  item: IndexItemConfig(TestDocument, {}), // Has mapper
                  groupingProperties: [
                    GroupingPropertyData(TestVocab.testCategory),
                  ],
                ),
              ],
            ),
          ],
        );

        final result = validate(config, mockMapper);
        expect(result.isValid, isTrue);
        expect(result.errors, isEmpty,
            reason: 'All types have mappers, should pass validation');
      });

      test('should validate hierarchy levels are properly ordered', () {
        final config = LocordaConfig(
          resources: [
            ResourceConfig(
              type: TestDocument,
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [
                GroupIndexConfig(
                  MultiPropertyGroupKey,
                  localName: 'hierarchical',
                  groupingProperties: [
                    GroupingPropertyData(TestVocab.testCategory,
                        hierarchyLevel: 1),
                    GroupingPropertyData(
                        const IriTerm('https://test.example/vocab#priority'),
                        hierarchyLevel: 2),
                    GroupingPropertyData(
                        const IriTerm('https://test.example/vocab#department'),
                        hierarchyLevel: 3),
                  ],
                ),
              ],
            ),
          ],
        );

        final result = validate(config, mockMapper);
        expect(result.isValid, isTrue);
        expect(result.errors, isEmpty);
      });

      test('should warn about hierarchy level gaps', () {
        final config = LocordaConfig(
          resources: [
            ResourceConfig(
              type: TestDocument,
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [
                GroupIndexConfig(
                  MultiPropertyGroupKey,
                  localName: 'level-gap',
                  groupingProperties: [
                    GroupingPropertyData(TestVocab.testCategory,
                        hierarchyLevel: 1),
                    GroupingPropertyData(
                        const IriTerm('https://test.example/vocab#priority'),
                        hierarchyLevel: 3), // Gap! Missing level 2
                  ],
                ),
              ],
            ),
          ],
        );

        final result = validate(config, mockMapper);
        expect(result.isValid, isTrue);
        expect(result.warnings, isNotEmpty);
        expect(
            result.warnings
                .any((w) => w.message.contains('Hierarchy level gap')),
            isTrue);
      });

      test(
          'should allow duplicate hierarchy levels (valid Cartesian product scenario)',
          () {
        final config = LocordaConfig(
          resources: [
            ResourceConfig(
              type: TestDocument,
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [
                GroupIndexConfig(
                  MultiPropertyGroupKey,
                  localName: 'duplicate-levels-ok',
                  groupingProperties: [
                    GroupingPropertyData(TestVocab.testCategory,
                        hierarchyLevel: 1),
                    GroupingPropertyData(
                        const IriTerm('https://test.example/vocab#priority'),
                        hierarchyLevel:
                            1), // Same level = Cartesian product (valid)
                    GroupingPropertyData(
                        const IriTerm('https://test.example/vocab#department'),
                        hierarchyLevel: 2),
                  ],
                ),
              ],
            ),
          ],
        );

        final result = validate(config, mockMapper);
        expect(result.isValid, isTrue);
        expect(result.errors, isEmpty);
        // Multiple properties at same level are valid (Cartesian product)
      });

      test('should fail with zero or negative hierarchy levels', () {
        final config = LocordaConfig(
          resources: [
            ResourceConfig(
              type: TestDocument,
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [
                GroupIndexConfig(
                  TestDocumentGroupKey,
                  localName: 'invalid-level',
                  groupingProperties: [
                    GroupingPropertyData(TestVocab.testCategory,
                        hierarchyLevel: 0), // Invalid!
                  ],
                ),
              ],
            ),
          ],
        );

        final result = validate(config, mockMapper);
        expect(result.isValid, isFalse);
        expect(
            result.errors.any(
                (e) => e.message.contains('hierarchy level must be positive')),
            isTrue);
      });

      test('should fail with empty missing value', () {
        final config = LocordaConfig(
          resources: [
            ResourceConfig(
              type: TestDocument,
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [
                GroupIndexConfig(
                  TestDocumentGroupKey,
                  localName: 'empty-missing-value',
                  groupingProperties: [
                    GroupingPropertyData(
                      TestVocab.testCategory,
                      missingValue: '', // Empty!
                    ),
                  ],
                ),
              ],
            ),
          ],
        );

        final result = validate(config, mockMapper);
        expect(result.isValid, isFalse);
        expect(
            result.errors.any(
                (e) => e.message.contains('missing value cannot be empty')),
            isTrue);
      });

      test('should validate complex multi-transform scenario', () {
        final config = LocordaConfig(
          resources: [
            ResourceConfig(
              type: TestDocument,
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [
                GroupIndexConfig(
                  TestDocumentGroupKey,
                  localName: 'multi-transform',
                  groupingProperties: [
                    GroupingPropertyData(
                      const IriTerm('https://schema.org/dateCreated'),
                      transforms: [
                        // Multiple transforms for different date formats
                        RegexTransformData(
                          r'^([0-9]{4})-([0-9]{2})-([0-9]{2})$',
                          r'${1}-${2}',
                        ),
                        RegexTransformData(
                          r'^([0-9]{2})/([0-9]{2})/([0-9]{4})$',
                          r'${3}-${1}',
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ],
        );

        final result = validate(config, mockMapper);
        expect(result.isValid, isTrue);
        expect(result.errors, isEmpty);
      });
    });

    group('Regex Transform Validation Integration', () {
      test('should call RegexTransform validation for all transforms', () {
        final config = LocordaConfig(
          resources: [
            ResourceConfig(
              type: TestDocument,
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [
                GroupIndexConfig(
                  TestDocumentGroupKey,
                  localName: 'multiple-invalid-transforms',
                  groupingProperties: [
                    GroupingPropertyData(
                      TestVocab.testCategory,
                      transforms: [
                        RegexTransformData(r'^(a|b)$', r'${1}'), // Alternation
                        RegexTransformData(
                            r'[[:alpha:]]', r'${0}'), // Named character class
                        RegexTransformData(
                            r'^(.*)$', r'$1'), // Invalid replacement
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ],
        );

        final result = validate(config, mockMapper);
        expect(result.isValid, isFalse);

        // Should have errors for all three invalid transforms
        expect(result.errors.length, greaterThanOrEqualTo(3));
        expect(result.errors.any((e) => e.message.contains('alternation')),
            isTrue);
        expect(result.errors.any((e) => e.message.contains('named character')),
            isTrue);
        expect(
            result.errors.any((e) => e.message
                .contains('RegexTransform replacement contains invalid')),
            isTrue);
      });

      test(
          'should validate transform syntax according to GROUP-INDEXING.md spec',
          () {
        // Test patterns from the compatible regex subset
        final validPatterns = [
          r'[a-z]',
          r'[A-Z]',
          r'[0-9]',
          r'[abc]',
          r'[^abc]',
          r'[a-zA-Z]',
          r'[0-9a-fA-F]',
          r'.',
          r'^start',
          r'end$',
          r'a*',
          r'b+',
          r'c?',
          r'd{3}',
          r'e{2,5}',
          r'f{1,}',
          r'(abc)',
          r'(a)(b)(c)',
          r'\.',
          r'\^',
          r'\$'
        ];

        for (final pattern in validPatterns) {
          final config = LocordaConfig(
            resources: [
              ResourceConfig(
                type: TestDocument,
                crdtMapping: Uri.parse('https://example.com/document.ttl'),
                indices: [
                  GroupIndexConfig(
                    TestDocumentGroupKey,
                    localName: 'valid-pattern-test',
                    groupingProperties: [
                      GroupingPropertyData(
                        TestVocab.testCategory,
                        transforms: [
                          RegexTransformData(pattern, r'${0}'),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ],
          );

          final result = validate(config, mockMapper);
          expect(result.isValid, isTrue,
              reason:
                  'Pattern $pattern should be valid per GROUP-INDEXING.md spec');
        }
      });

      test('should reject forbidden patterns from GROUP-INDEXING.md spec', () {
        final forbiddenPatterns = [
          // Alternation patterns
          r'(a|b)', r'cat|dog', r'^(yes|no)$',
          // Named character classes
          r'[[:alpha:]]', r'[[:digit:]]', r'[[:alnum:]]', r'[[:space:]]'
        ];

        for (final pattern in forbiddenPatterns) {
          final config = LocordaConfig(
            resources: [
              ResourceConfig(
                type: TestDocument,
                crdtMapping: Uri.parse('https://example.com/document.ttl'),
                indices: [
                  GroupIndexConfig(
                    TestDocumentGroupKey,
                    localName: 'forbidden-pattern-test',
                    groupingProperties: [
                      GroupingPropertyData(
                        TestVocab.testCategory,
                        transforms: [
                          RegexTransformData(pattern, r'${0}'),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ],
          );

          final result = validate(config, mockMapper);
          expect(result.isValid, isFalse,
              reason:
                  'Pattern $pattern should be forbidden per GROUP-INDEXING.md spec');
        }
      });

      test('should validate replacement syntax per GROUP-INDEXING.md spec', () {
        // Test each replacement with a pattern that has enough capture groups
        final testCases = [
          (r'${1}', r'^(.*)$'), // 1 group needed
          (r'${2}', r'^(.*)(.*)$'), // 2 groups needed
          (r'${0}', r'^(.*)$'), // 0 refers to whole match
          (r'${1}${2}', r'^(.*)(.*)$'), // 2 groups needed
          (r'prefix-${1}-suffix', r'^(.*)$'), // 1 group needed
          (r'${1}1', r'^(.*)$'), // 1 group needed
          (
            r'${11}',
            r'^(.{1})(.{1})(.{1})(.{1})(.{1})(.{1})(.{1})(.{1})(.{1})(.{1})(.{1})(.*)$'
          ), // 11 groups needed
          (r'$$', r'^(.*)$'), // No groups needed, just literal $
        ];

        for (final (replacement, pattern) in testCases) {
          final config = LocordaConfig(
            resources: [
              ResourceConfig(
                type: TestDocument,
                crdtMapping: Uri.parse('https://example.com/document.ttl'),
                indices: [
                  GroupIndexConfig(
                    TestDocumentGroupKey,
                    localName: 'valid-replacement-test',
                    groupingProperties: [
                      GroupingPropertyData(
                        TestVocab.testCategory,
                        transforms: [
                          RegexTransformData(pattern, replacement),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ],
          );

          final result = validate(config, mockMapper);
          expect(result.isValid, isTrue,
              reason:
                  'Replacement $replacement with pattern $pattern should be valid per GROUP-INDEXING.md spec');
        }
      });
    });

    group('Mapper Registry Validation', () {
      test('should comprehensively validate all type mappers exist', () {
        // Test with a fully valid configuration
        final config = LocordaConfig(
          resources: [
            ResourceConfig(
              type: TestDocument, // Has global mapper
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [
                FullIndexConfig(
                  localName: 'full-documents',
                  item: IndexItemConfig(TestDocument, {}), // Has global mapper
                ),
                GroupIndexConfig(
                  TestDocumentGroupKey, // Has local mapper
                  localName: 'grouped-documents',
                  item: IndexItemConfig(TestDocument, {}), // Has global mapper
                  groupingProperties: [
                    GroupingPropertyData(TestVocab.testCategory),
                  ],
                ),
              ],
            ),
            ResourceConfig(
              type: TestCategory, // Has global mapper
              crdtMapping: Uri.parse('https://example.com/category.ttl'),
              indices: [
                GroupIndexConfig(
                  MultiPropertyGroupKey, // Has local mapper
                  localName: 'multi-prop-categories',
                  item: IndexItemConfig(TestCategory, {}), // Has global mapper
                  groupingProperties: [
                    GroupingPropertyData(TestVocab.testCategory),
                    GroupingPropertyData(
                        const IriTerm('https://test.example/vocab#priority')),
                  ],
                ),
              ],
            ),
          ],
        );

        final result = validate(config, mockMapper);
        expect(result.isValid, isTrue);
        expect(result.errors, isEmpty);
      });

      test('should fail when multiple types lack mappers', () {
        final config = LocordaConfig(
          resources: [
            ResourceConfig(
              type: UnmappedType, // No mapper
              crdtMapping: Uri.parse('https://example.com/unmapped1.ttl'),
              indices: [
                GroupIndexConfig(
                  UnmappedType, // No mapper for groupKeyType either
                  localName: 'unmapped-group',
                  item: IndexItemConfig(
                      UnmappedType, {}), // No mapper for itemType either
                  groupingProperties: [
                    GroupingPropertyData(TestVocab.testCategory),
                  ],
                ),
              ],
            ),
          ],
        );

        final result = validate(config, mockMapper);
        expect(result.isValid, isFalse);

        // Should have multiple errors for the missing mappers
        expect(result.errors.length, greaterThanOrEqualTo(1));
        expect(result.errors.any((e) => e.message.contains('UnmappedType')),
            isTrue);
      });

      test('should validate when all required mappers are present', () {
        // Test comprehensive mapper validation - resource types, group key types, item types
        final config = LocordaConfig(
          resources: [
            ResourceConfig(
              type: TestDocument, // Has mapper
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [
                GroupIndexConfig(
                  IriPropertyGroupKey, // Has mapper
                  localName: 'complex-group-key',
                  item: IndexItemConfig(TestDocument, {}), // Has mapper
                  groupingProperties: [
                    GroupingPropertyData(TestVocab.testCategory),
                  ],
                ),
              ],
            ),
          ],
        );

        final result = validate(config, mockMapper);
        expect(result.isValid, isTrue,
            reason: 'All required types should have mappers registered');
      });
    });

    group('Edge Cases and Error Handling', () {
      test('should fail with empty grouping properties list', () {
        // This should be caught by the constructor assertion
        expect(
          () => GroupIndexConfig(
            TestDocumentGroupKey,
            localName: 'empty-properties',
            groupingProperties: [], // Empty!
          ),
          throwsA(isA<AssertionError>()),
        );
      });

      test('should fail with null predicate in GroupingProperty', () {
        expect(
          () => GroupingPropertyData(
            const IriTerm(''), // Empty IRI
          ),
          returnsNormally, // Constructor should accept this, validation catches it
        );

        // The validation should catch empty predicate IRIs
        final config = LocordaConfig(
          resources: [
            ResourceConfig(
              type: TestDocument,
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [
                GroupIndexConfig(
                  TestDocumentGroupKey,
                  localName: 'empty-predicate',
                  groupingProperties: [
                    GroupingPropertyData(const IriTerm('')), // Empty predicate
                  ],
                ),
              ],
            ),
          ],
        );

        final result = validate(config, mockMapper);
        expect(result.isValid, isFalse);
        expect(
            result.errors.any((e) => e.message.contains('predicate')), isTrue);
      });

      test('should fail with malformed regex escape sequences', () {
        final config = LocordaConfig(
          resources: [
            ResourceConfig(
              type: TestDocument,
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [
                GroupIndexConfig(
                  TestDocumentGroupKey,
                  localName: 'malformed-regex',
                  groupingProperties: [
                    GroupingPropertyData(
                      TestVocab.testCategory,
                      transforms: [
                        RegexTransformData(
                          r'\', // Incomplete escape sequence
                          r'${0}',
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ],
        );

        final result = validate(config, mockMapper);
        expect(result.isValid, isFalse);
        expect(
            result.errors.any((e) => e.message.contains(
                'RegexTransform pattern ends with incomplete escape sequence')),
            isTrue);
      });

      test('should fail with invalid capture group references', () {
        final config = LocordaConfig(
          resources: [
            ResourceConfig(
              type: TestDocument,
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [
                GroupIndexConfig(
                  TestDocumentGroupKey,
                  localName: 'invalid-capture-group',
                  groupingProperties: [
                    GroupingPropertyData(
                      TestVocab.testCategory,
                      transforms: [
                        RegexTransformData(
                          r'^([a-z]+)$', // Only one capture group
                          r'${2}', // References non-existent group 2!
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ],
        );

        final result = validate(config, mockMapper);
        expect(result.isValid, isFalse);
        expect(result.errors.any((e) => e.message.contains('capture group')),
            isTrue);
      });

      test('should handle extremely large hierarchy levels', () {
        final config = LocordaConfig(
          resources: [
            ResourceConfig(
              type: TestDocument,
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [
                GroupIndexConfig(
                  TestDocumentGroupKey,
                  localName: 'large-hierarchy',
                  groupingProperties: [
                    GroupingPropertyData(
                      TestVocab.testCategory,
                      hierarchyLevel: 999999, // Very large level
                    ),
                  ],
                ),
              ],
            ),
          ],
        );

        final result = validate(config, mockMapper);
        expect(result.isValid, isTrue);
        expect(
            result.warnings.any((w) => w.message.contains('hierarchy level')),
            isFalse,
            reason:
                'Large hierarchy levels should be allowed but may generate warnings about depth');
      });

      test('should validate multiple transforms with different formats', () {
        final config = LocordaConfig(
          resources: [
            ResourceConfig(
              type: TestDocument,
              crdtMapping: Uri.parse('https://example.com/document.ttl'),
              indices: [
                GroupIndexConfig(
                  TestDocumentGroupKey,
                  localName: 'multi-format-dates',
                  groupingProperties: [
                    GroupingPropertyData(
                      const IriTerm('https://schema.org/dateCreated'),
                      transforms: [
                        // Handle multiple date formats per GROUP-INDEXING.md examples
                        RegexTransformData(
                            r'^([0-9]{4})-([0-9]{2})-([0-9]{2})$',
                            r'${1}-${2}'), // ISO
                        RegexTransformData(
                            r'^([0-9]{2})/([0-9]{2})/([0-9]{4})$',
                            r'${3}-${1}'), // US
                        RegexTransformData(
                            r'^([0-9]{2})\.([0-9]{2})\.([0-9]{4})$',
                            r'${3}-${1}'), // EU
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ],
        );

        final result = validate(config, mockMapper);
        expect(result.isValid, isTrue);
        expect(result.errors, isEmpty,
            reason:
                'Multiple date format transforms should be valid per GROUP-INDEXING.md spec');
      });
    });
  });
}

ValidationResult validate(LocordaConfig config, RdfMapper mockMapper) =>
    LocordaConfigValidator().validate(
        config, buildResourceTypeCache(mockMapper, config),
        mapper: mockMapper);
