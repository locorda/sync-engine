// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: prefer_single_quotes

const List<String> bootstrapMappings = [
  r"""
@base <https://w3id.org/solid-crdt-sync/mappings/client-installation-v1#> .
@prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
@prefix crdt: <https://w3id.org/solid-crdt-sync/vocab/crdt-mechanics#> .
@prefix algo: <https://w3id.org/solid-crdt-sync/vocab/crdt-algorithms#> .
@prefix sync: <https://w3id.org/solid-crdt-sync/vocab/sync#> .
@prefix mc: <https://w3id.org/solid-crdt-sync/vocab/merge-contract#> .
@prefix mappings: <https://w3id.org/solid-crdt-sync/mappings/> .

# Standard mapping for client installation documents
# Enables collaborative lifecycle management and dormancy detection

<> a mc:DocumentMapping;
   # Import existing statement mapping for tombstones and clock mappings
   mc:imports ( mappings:core-v1 ) ;
   # Define specific mappings for client installation properties
   mc:classMapping ( <#client-installation> ) .

<#client-installation> a mc:ClassMapping;
   mc:appliesToClass crdt:ClientInstallation;
   mc:rule
     [ mc:predicate crdt:belongsToWebID; algo:mergeWith algo:Immutable ],
     [ mc:predicate crdt:applicationId; algo:mergeWith algo:Immutable ],
     [ mc:predicate crdt:createdAt; algo:mergeWith algo:Immutable ],
     [ mc:predicate crdt:lastActiveAt; algo:mergeWith algo:LWW_Register;
       rdfs:comment "Convention: Only the installation itself should update its own activity timestamp" ],
     [ mc:predicate crdt:maxInactivityPeriod; algo:mergeWith algo:LWW_Register;
       rdfs:comment "Convention: Only the installation itself should update its own inactivity threshold" ] .
""",

  r"""
@base <https://w3id.org/solid-crdt-sync/mappings/core-v1#> .
@prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
@prefix foaf: <http://xmlns.com/foaf/0.1/> .
@prefix crdt: <https://w3id.org/solid-crdt-sync/vocab/crdt-mechanics#> .
@prefix algo: <https://w3id.org/solid-crdt-sync/vocab/crdt-algorithms#> .
@prefix sync: <https://w3id.org/solid-crdt-sync/vocab/sync#> .
@prefix mc: <https://w3id.org/solid-crdt-sync/vocab/merge-contract#> .
@prefix idx: <https://w3id.org/solid-crdt-sync/vocab/idx#> .
@prefix mappings: <https://w3id.org/solid-crdt-sync/mappings/> .

# Core merge contract mappings for CRDT framework infrastructure
# This DocumentMapping provides essential merge rules that most applications need

<> a mc:DocumentMapping;
   # Define class mappings for framework components
   mc:classMapping ( <#managed-document> <#statement> <#property-statement> <#resource-statement> <#versioned-clock> <#blank-node-mapping> ) ;
   # Define predicate mappings for framework components (ordered list)
   mc:predicateMapping ( <#clock-mappings> <#lifecycle-mappings> <#traversal-boundaries> <#standard-rdf> ) .

# ManagedDocument is the wrapper for all CRDT-managed resources
<#managed-document> a mc:ClassMapping;
   mc:appliesToClass sync:ManagedDocument;
   mc:rule
     [ mc:predicate foaf:primaryTopic; algo:mergeWith algo:Immutable ],  # The resource being managed
     [ mc:predicate sync:isGovernedBy; algo:mergeWith algo:LWW_Register; mc:disableBlankNodePathIdentification true ],  # Merge contract list - rdf:List, currently only LWW_Register possible (append-only)
     [ mc:predicate sync:managedResourceType; algo:mergeWith algo:Immutable ],  # Resource type for discovery
     [ mc:predicate idx:belongsToIndexShard; algo:mergeWith algo:OR_Set ],  # Index shard memberships
     [ mc:predicate sync:hasStatement; algo:mergeWith algo:OR_Set ],
     [ mc:predicate sync:hasBlankNodeMapping; algo:mergeWith algo:OR_Set ] .  # Blank node canonical mappings

# Merge contract for RDF reified statements used as tombstones in CRDT sets
<#statement> a mc:ClassMapping;
   mc:appliesToClass rdf:Statement;
   mc:rule
     # The subject, predicate, and object of the reified statement are immutable identifiers
     [ mc:predicate rdf:subject; algo:mergeWith algo:LWW_Register ],
     [ mc:predicate rdf:predicate; algo:mergeWith algo:LWW_Register ],
     [ mc:predicate rdf:object; algo:mergeWith algo:LWW_Register ] .

# Standard mapping for predicates of Hybrid Logical Clock entries (fragment-identified nodes)  
<#clock-mappings> a mc:PredicateMapping;
   mc:rule
     [ mc:predicate crdt:installationIri; algo:mergeWith algo:OR_Set],
     [ mc:predicate crdt:forClockEntry; algo:mergeWith algo:Immutable ],
     [ mc:predicate crdt:hasClockEntry; algo:mergeWith algo:OR_Set ],
     [ mc:predicate crdt:clockHash; algo:mergeWith algo:LWW_Register ],
     [ mc:predicate crdt:logicalTime; algo:mergeWith algo:G_Register ],
     [ mc:predicate crdt:physicalTime; algo:mergeWith algo:G_Register ] .

# Merge contract for ResourceStatement used for resource-level framework metadata
<#resource-statement> a mc:ClassMapping;
   mc:appliesToClass sync:ResourceStatement;
   mc:rule
     # The resource identifier is the immutable identity of this statement
     [ mc:predicate sync:resource; algo:mergeWith algo:LWW_Register; mc:isIdentifying true ] .

# Merge contract for PropertyStatement used for property-level framework metadata
# (e.g. last-write versioned clock for LWW/FWW conflict resolution).
# Identified by the (sync:resource, sync:property) pair.
<#property-statement> a mc:ClassMapping;
   mc:appliesToClass sync:PropertyStatement;
   mc:rule
     [ mc:predicate sync:resource; algo:mergeWith algo:Immutable; mc:isIdentifying true ],
     [ mc:predicate sync:property; algo:mergeWith algo:Immutable; mc:isIdentifying true ],
     # crdt:vclk is the last-write versioned-clock pointer. LWW here is a placeholder:
     # the merger uses vector-clock domination on the referenced crdt:VersionedClock,
     # falling back to max(physicalTime) within the vclk on 'concurrent'.
     [ mc:predicate crdt:vclk; algo:mergeWith algo:LWW_Register ] .

# Merge contract for VersionedClock - immutable, content-addressed HLC snapshot.
# Its IRI is a hash over the contained (forClockEntry, logicalTime) pairs, so
# value-identical vclks share an IRI and are automatically deduplicated.
<#versioned-clock> a mc:ClassMapping;
   mc:appliesToClass crdt:VersionedClock;
   mc:rule
     # The contained clock entries are part of the content-addressed identity:
     # no path identification needed for the embedded blank nodes (the whole
     # vclk is Immutable, so per-entry blank-node merging never occurs).
     [ mc:predicate crdt:hasClockEntry; algo:mergeWith algo:Immutable; mc:disableBlankNodePathIdentification true ] .

# Merge contract for BlankNodeMapping - framework-reserved fragments for identified blank nodes
<#blank-node-mapping> a mc:ClassMapping;
   mc:appliesToClass sync:BlankNodeMapping;
   mc:rule
     # The blank node reference itself uses LWW and stops traversal into app data
     [ mc:predicate sync:blankNode; algo:mergeWith algo:LWW_Register; mc:stopTraversal true ] .

# Standard mapping for lifecycle semantics across all CRDT contexts
<#lifecycle-mappings> a mc:PredicateMapping;
   mc:rule
     # Global lifecycle semantics - applies to all contexts where lifecycle properties are used
     # Uses temporal ordering: document/value is deleted if max(crdt:deletedAt) > max(crdt:createdAt)
     # Solves zombie deletion problems during document recreation scenarios
     [ mc:predicate crdt:createdAt; algo:mergeWith algo:OR_Set ],  # Creation/recreation timestamps
     [ mc:predicate crdt:deletedAt; algo:mergeWith algo:OR_Set ] . # Deletion timestamps

# Framework/app data separation boundaries
<#traversal-boundaries> a mc:PredicateMapping;
   mc:rule
     # Standard semantic web predicate for document primary topic
     [ mc:predicate foaf:primaryTopic; mc:stopTraversal true ],
     # Standard RDF reification predicates create traversal boundaries
     [ mc:predicate rdf:subject; mc:stopTraversal true ],
     [ mc:predicate rdf:predicate; mc:stopTraversal true ],
     [ mc:predicate rdf:object; mc:stopTraversal true ],
     # PropertyStatement identifiers create traversal boundaries (same role as rdf:subject/predicate)
     [ mc:predicate sync:resource; mc:stopTraversal true ],
     [ mc:predicate sync:property; mc:stopTraversal true ],
     # Versioned-clock references and their entries stay on the framework side
     [ mc:predicate crdt:vclk; mc:stopTraversal true ],
     [ mc:predicate crdt:forClockEntry; mc:stopTraversal true ],
     [ mc:predicate crdt:hasClockEntry; mc:stopTraversal true ] .

<#standard-rdf> a mc:PredicateMapping;
 mc:rule
  [ mc:predicate rdf:type; algo:mergeWith algo:LWW_Register ],  
  [ mc:predicate rdf:first; algo:mergeWith algo:LWW_Register ], 
  [ mc:predicate rdf:rest; algo:mergeWith algo:LWW_Register ] .
""",

  r"""
@base <https://w3id.org/solid-crdt-sync/mappings/index-v1#> .
@prefix crdt: <https://w3id.org/solid-crdt-sync/vocab/crdt-mechanics#> .
@prefix algo: <https://w3id.org/solid-crdt-sync/vocab/crdt-algorithms#> .
@prefix sync: <https://w3id.org/solid-crdt-sync/vocab/sync#> .
@prefix mc: <https://w3id.org/solid-crdt-sync/vocab/merge-contract#> .
@prefix idx: <https://w3id.org/solid-crdt-sync/vocab/idx#> .
@prefix mappings: <https://w3id.org/solid-crdt-sync/mappings/> .

# CRDT mappings for index documents (FullIndex, GroupIndexTemplate, GroupIndex)
# Used by framework for index metadata synchronization

<> a mc:DocumentMapping;
   # Import base CRDT framework
   mc:imports ( mappings:core-v1 ) ;
   # Define index-specific class mappings
   mc:classMapping ( <#full-index> <#group-index-template> <#group-index> <#indexed-property> <#grouping-rule> <#grouping-rule-property> <#modulo-hash-sharding> <#regex-transform> ) .

# FullIndex documents
<#full-index> a mc:ClassMapping;
   mc:appliesToClass idx:FullIndex;
   mc:rule
     [ mc:predicate idx:indexesClass; algo:mergeWith algo:Immutable ],
     [ mc:predicate idx:indexedProperty; algo:mergeWith algo:OR_Set ],
     [ mc:predicate idx:hasShard; algo:mergeWith algo:OR_Set ],
     [ mc:predicate idx:populationState; algo:mergeWith algo:LWW_Register ],
     # No path node identification for shardingAlgorithm because it should be treated as atomic and is immutable anyways
     [ mc:predicate idx:shardingAlgorithm; algo:mergeWith algo:Immutable; mc:disableBlankNodePathIdentification true ],
     [ mc:predicate idx:readBy; algo:mergeWith algo:OR_Set ] .

# Shard documents
<#shard> a mc:ClassMapping;
   mc:appliesToClass idx:Shard;
   mc:rule
     [ mc:predicate idx:containsEntry; algo:mergeWith algo:OR_Set ] .

# GroupIndexTemplate documents
<#group-index-template> a mc:ClassMapping;
   mc:appliesToClass idx:GroupIndexTemplate;
   mc:rule
     [ mc:predicate idx:indexesClass; algo:mergeWith algo:Immutable ],
     [ mc:predicate idx:indexedProperty; algo:mergeWith algo:OR_Set ],
     # No path node identification for shardingAlgorithm because it should be treated as atomic and is immutable anyways
     [ mc:predicate idx:shardingAlgorithm; algo:mergeWith algo:Immutable; mc:disableBlankNodePathIdentification true ],
     [ mc:predicate idx:groupedBy; algo:mergeWith algo:Immutable ],
     [ mc:predicate idx:readBy; algo:mergeWith algo:OR_Set ],
     [ mc:predicate idx:populationState; algo:mergeWith algo:LWW_Register ],
     [ mc:predicate idx:hasPopulatingShard; algo:mergeWith algo:OR_Set ] .

# GroupIndex documents
<#group-index> a mc:ClassMapping;
   mc:appliesToClass idx:GroupIndex;
   mc:rule
     [ mc:predicate idx:indexesClass; algo:mergeWith algo:Immutable ],
     [ mc:predicate idx:basedOn; algo:mergeWith algo:Immutable ],
     [ mc:predicate idx:hasShard; algo:mergeWith algo:OR_Set ],
     [ mc:predicate idx:readBy; algo:mergeWith algo:OR_Set ],
     [ mc:predicate idx:populationState; algo:mergeWith algo:LWW_Register ] .

# IndexedProperty configuration objects within indices
<#indexed-property> a mc:ClassMapping;
   mc:appliesToClass idx:IndexedProperty;
   mc:rule
     [ mc:predicate idx:trackedProperty; algo:mergeWith algo:Immutable; mc:isIdentifying true ],  # Which property to index
     [ mc:predicate idx:readBy; algo:mergeWith algo:OR_Set ] .      # Which installations read this property

# GroupingRule configuration for partitioned indices
<#grouping-rule> a mc:ClassMapping;
   mc:appliesToClass idx:GroupingRule;
   mc:rule
     [ mc:predicate idx:property; algo:mergeWith algo:OR_Set ],           # GroupingRuleProperty instances
     [ mc:predicate idx:groupTemplate; algo:mergeWith algo:Immutable ] .  # Template for group IRI construction

# GroupingRuleProperty configuration within grouping rules
# Identification key: (sourceProperty, hierarchyLevel) - both required for unique identification
<#grouping-rule-property> a mc:ClassMapping;
   mc:appliesToClass idx:GroupingRuleProperty;
   mc:rule
     [ mc:predicate idx:sourceProperty; algo:mergeWith algo:Immutable; mc:isIdentifying true ],  # Source property to extract from (identifying)
     [ mc:predicate idx:hierarchyLevel; algo:mergeWith algo:Immutable; mc:isIdentifying true ],  # Hierarchy level (identifying, default: 1)
     [ mc:predicate idx:transform; algo:mergeWith algo:Immutable; mc:disableBlankNodePathIdentification true ],       # Transform list (part of grouping identity)
     [ mc:predicate idx:missingValue; algo:mergeWith algo:LWW_Register ] . # Default value for missing properties

# ModuloHashSharding algorithm configuration
<#modulo-hash-sharding> a mc:ClassMapping;
   mc:appliesToClass idx:ModuloHashSharding;
   mc:rule
     [ mc:predicate idx:hashAlgorithm; algo:mergeWith algo:Immutable ],
     [ mc:predicate idx:numberOfShards; algo:mergeWith algo:Immutable ],
     [ mc:predicate idx:configVersion; algo:mergeWith algo:LWW_Register ],
     [ mc:predicate idx:autoScaleThreshold; algo:mergeWith algo:LWW_Register ] .

# RegexTransform configuration within transform lists
<#regex-transform> a mc:ClassMapping;
   mc:appliesToClass idx:RegexTransform;
   mc:rule
     [ mc:predicate idx:pattern; algo:mergeWith algo:LWW_Register ],       # Regex pattern (atomic within blank node)
     [ mc:predicate idx:replacement; algo:mergeWith algo:LWW_Register ] .  # Replacement template (atomic within blank node)
""",

  r"""
@base <https://w3id.org/solid-crdt-sync/mappings/shard-v1#> .
@prefix crdt: <https://w3id.org/solid-crdt-sync/vocab/crdt-mechanics#> .
@prefix algo: <https://w3id.org/solid-crdt-sync/vocab/crdt-algorithms#> .
@prefix sync: <https://w3id.org/solid-crdt-sync/vocab/sync#> .
@prefix mc: <https://w3id.org/solid-crdt-sync/vocab/merge-contract#> .
@prefix idx: <https://w3id.org/solid-crdt-sync/vocab/idx#> .
@prefix mappings: <https://w3id.org/solid-crdt-sync/mappings/> .

# CRDT mappings for shard documents
# Used by framework for shard synchronization and entry management

<> a mc:DocumentMapping;
   # Import base CRDT framework
   mc:imports ( mappings:core-v1 ) ;
   # Define shard-specific class mappings
   mc:classMapping ( <#shard> ) ;
   # Define predicate mappings for shard entry properties (since ShardEntry is not explicitly typed)
   mc:predicateMapping ( <#shard-entry-mappings> ) .

# Shard documents
<#shard> a mc:ClassMapping;
   mc:appliesToClass idx:Shard;
   mc:rule
     [ mc:predicate idx:isShardOf; algo:mergeWith algo:Immutable ],
     [ mc:predicate idx:populationState; algo:mergeWith algo:LWW_Register ],
     [ mc:predicate idx:containsEntry; algo:mergeWith algo:OR_Set ] .

# Predicate mappings for ShardEntry properties (since ShardEntry is not explicitly typed)
<#shard-entry-mappings> a mc:PredicateMapping;
   mc:rule
     [ mc:predicate idx:resource; algo:mergeWith algo:Immutable ],           # Resource IRI
     [ mc:predicate crdt:clockHash; algo:mergeWith algo:LWW_Register ] .  # Clock hash for change detection
""",

];
