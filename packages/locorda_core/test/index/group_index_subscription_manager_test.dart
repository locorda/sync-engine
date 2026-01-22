import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_core/src/index/group_index_subscription_manager.dart';
import 'package:test/test.dart';

void main() {
  group('GroupIndexGraphSubscriptionManager', () {
    late SyncEngineConfig config;
    late GroupIndexGraphSubscriptionManager manager;

    // Test vocabulary
    final testTypeIri = const IriTerm('https://example.org/TestDocument');
    final categoryPredicate = const IriTerm('https://example.org/category');
    final createdAtPredicate =
        const IriTerm('https://test.example/vocab#createdAt');

    setUp(() {
      // Create a test config with a GroupIndex
      config = SyncEngineConfig(
        resources: [
          ResourceConfigData(
            typeIri: testTypeIri,
            crdtMapping: Uri.parse('http://example.org/crdt/document'),
            indices: [
              GroupIndexData(
                localName: 'document-groups',
                groupingProperties: [
                  GroupingProperty(categoryPredicate),
                ],
              ),
            ],
          ),
        ],
      );

      manager = GroupIndexGraphSubscriptionManager(config: config);
    });

    group('getGroupIdentifiers', () {
      test('successfully generates group identifiers from valid graph',
          () async {
        final groupKeySubject = const IriTerm('https://example.org/groupkey/1');
        final groupKeyGraph = RdfGraph(triples: [
          Triple(
              groupKeySubject, categoryPredicate, LiteralTerm.string('work')),
        ]);

        final groupIdentifiers = await manager.getGroupIdentifiers(
          'document-groups',
          groupKeyGraph,
        );

        expect(groupIdentifiers, isNotEmpty);
        expect(groupIdentifiers.first, equals('work'));
      });

      test('generates group identifiers with transforms', () async {
        // Create a separate config with date transforms
        final dateConfig = SyncEngineConfig(
          resources: [
            ResourceConfigData(
              typeIri: testTypeIri,
              crdtMapping: Uri.parse('http://example.org/crdt/document'),
              indices: [
                GroupIndexData(
                  localName: 'date-groups',
                  groupingProperties: [
                    GroupingProperty(
                      createdAtPredicate,
                      transforms: [
                        RegexTransform(
                          r'^([0-9]{4})-([0-9]{2})-([0-9]{2}).*',
                          r'${1}-${2}',
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ],
        );

        final dateManager =
            GroupIndexGraphSubscriptionManager(config: dateConfig);

        final groupKeySubject = const IriTerm('https://example.org/groupkey/2');
        final groupKeyGraph = RdfGraph(triples: [
          Triple(groupKeySubject, createdAtPredicate,
              LiteralTerm.string('2023-10-05T10:30:00Z')),
        ]);

        final groupIdentifiers = await dateManager.getGroupIdentifiers(
          'date-groups',
          groupKeyGraph,
        );

        expect(groupIdentifiers, isNotEmpty);
        expect(groupIdentifiers.single, equals('2023-10'));
      });

      test('throws exception for unknown index name', () async {
        final groupKeySubject = const IriTerm('https://example.org/groupkey/3');
        final groupKeyGraph = RdfGraph(triples: [
          Triple(
              groupKeySubject, categoryPredicate, LiteralTerm.string('work')),
        ]);

        expect(
          () => manager.getGroupIdentifiers('unknown-index', groupKeyGraph),
          throwsA(isA<GroupIndexGraphSubscriptionException>()),
        );
      });

      test('throws exception when no group identifiers generated', () async {
        // Use a graph that doesn't contain the required property
        final groupKeySubject = const IriTerm('https://example.org/groupkey/4');
        final groupKeyGraph = RdfGraph(triples: [
          Triple(groupKeySubject, const IriTerm('https://example.org/other'),
              LiteralTerm.string('value')),
        ]);

        expect(
          () => manager.getGroupIdentifiers('document-groups', groupKeyGraph),
          throwsA(isA<GroupIndexGraphSubscriptionException>()),
        );
      });

      test('handles multiple grouping properties', () async {
        // Create config with multiple grouping properties
        final multiConfig = SyncEngineConfig(
          resources: [
            ResourceConfigData(
              typeIri: testTypeIri,
              crdtMapping: Uri.parse('http://example.org/crdt/document'),
              indices: [
                GroupIndexData(
                  localName: 'multi-groups',
                  groupingProperties: [
                    GroupingProperty(categoryPredicate),
                    GroupingProperty(
                        const IriTerm('https://example.org/priority')),
                  ],
                ),
              ],
            ),
          ],
        );

        final multiManager =
            GroupIndexGraphSubscriptionManager(config: multiConfig);

        final groupKeySubject = const IriTerm('https://example.org/groupkey/5');
        final groupKeyGraph = RdfGraph(triples: [
          Triple(
              groupKeySubject, categoryPredicate, LiteralTerm.string('work')),
          Triple(groupKeySubject, const IriTerm('https://example.org/priority'),
              LiteralTerm.string('high')),
        ]);

        final groupIdentifiers = await multiManager.getGroupIdentifiers(
          'multi-groups',
          groupKeyGraph,
        );

        expect(groupIdentifiers, isNotEmpty);
        // Should contain combined group key based on lexicographic IRI ordering
        expect(groupIdentifiers.first, contains('work'));
        expect(groupIdentifiers.first, contains('high'));
      });

      test('handles hierarchical grouping properties', () async {
        // Create config with hierarchical grouping
        final hierarchyConfig = SyncEngineConfig(
          resources: [
            ResourceConfigData(
              typeIri: testTypeIri,
              crdtMapping: Uri.parse('http://example.org/crdt/document'),
              indices: [
                GroupIndexData(
                  localName: 'hierarchy-groups',
                  groupingProperties: [
                    GroupingProperty(
                      createdAtPredicate,
                      hierarchyLevel: 1,
                      transforms: [
                        RegexTransform(r'^([0-9]{4})-([0-9]{2})-([0-9]{2}).*',
                            r'${1}'), // Year
                      ],
                    ),
                    GroupingProperty(
                      categoryPredicate,
                      hierarchyLevel: 2,
                    ),
                  ],
                ),
              ],
            ),
          ],
        );

        final hierarchyManager =
            GroupIndexGraphSubscriptionManager(config: hierarchyConfig);

        final groupKeySubject = const IriTerm('https://example.org/groupkey/6');
        final groupKeyGraph = RdfGraph(triples: [
          Triple(groupKeySubject, createdAtPredicate,
              LiteralTerm.string('2023-10-05T10:30:00Z')),
          Triple(
              groupKeySubject, categoryPredicate, LiteralTerm.string('work')),
        ]);

        final groupIdentifiers = await hierarchyManager.getGroupIdentifiers(
          'hierarchy-groups',
          groupKeyGraph,
        );

        expect(groupIdentifiers, isNotEmpty);
        expect(groupIdentifiers.first, equals('2023/work')); // Year/category
      });

      test('handles empty graph', () async {
        final emptyGraph = RdfGraph(triples: []);

        expect(
          () => manager.getGroupIdentifiers('document-groups', emptyGraph),
          throwsA(isA<GroupIndexGraphSubscriptionException>()),
        );
      });
    });
  });
}
