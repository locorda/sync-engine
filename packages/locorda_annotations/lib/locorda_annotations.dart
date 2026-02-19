/// CRDT merge strategy annotations for locorda code generation.
///
/// This library provides annotations to specify how properties should be merged
/// in CRDT scenarios. The annotations work with RDF mapping and are used by
/// the locorda generator to create proper merge logic.
library locorda_annotations;

export 'src/crdt_annotations.dart'
    show CrdtImmutable, CrdtLwwRegister, CrdtOrSet, McIdentifying;
export 'src/resource.dart'
    show
        MergeContract,
        MergeContracts,
        RootResource,
        SubResource,
        GroupKey,
        IndexItem,
        FullIndex,
        GroupingProperty,
        RegexTransform,
        RootIriStrategy,
        SubIriStrategy,
        IndexItemIriStrategy;
export 'src/resource_ref.dart' show RootResourceRef, resourceRefFactoryKey;
