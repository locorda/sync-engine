// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: prefer_single_quotes

const List<String> bootstrapMappings = [
  r"""
@prefix ca: <https://w3id.org/solid-crdt-sync/vocab/crdt-algorithms#> .
@prefix mappings: <https://w3id.org/solid-crdt-sync/mappings/> .
@prefix mc: <https://w3id.org/solid-crdt-sync/vocab/merge-contract#> .
@prefix pn: <https://locorda.dev/example/personal_notes_app/vocabulary/personal-notes#> .
@prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
@prefix schema: <https://schema.org/> .

GRAPH <https://locorda.dev/example/personal_notes_app/mappings/category-v1#> {
  <https://locorda.dev/example/personal_notes_app/mappings/category-v1#> a mc:DocumentMapping;
      rdfs:comment "Defines how note categories should merge when conflicts occur during sync.";
      rdfs:label "Notes Category CRDT Document Mapping v1";
      mc:classMapping (
          [
              a mc:ClassMapping ;
              mc:appliesToClass pn:NotesCategory ;
              mc:rule [ mc:predicate schema:name ; ca:mergeWith ca:LWW_Register ],
                  [ mc:predicate schema:description ; ca:mergeWith ca:LWW_Register ],
                  [ mc:predicate pn:displaySettings ; ca:mergeWith ca:LWW_Register ],
                  [ mc:predicate schema:dateCreated ; ca:mergeWith ca:Immutable ],
                  [ mc:predicate schema:dateModified ; ca:mergeWith ca:LWW_Register ],
                  [ mc:predicate pn:archived ; ca:mergeWith ca:LWW_Register ]
          ]
      );
      mc:imports (mappings:core-v1);
      mc:predicateMapping (
          [
              mc:rule [ mc:predicate pn:categoryColor ; ca:mergeWith ca:LWW_Register ],
                  [ mc:predicate pn:categoryIcon ; ca:mergeWith ca:LWW_Register ] ;
              a mc:PredicateMapping
          ]
      ) .
}
""",

  r"""
@prefix ca: <https://w3id.org/solid-crdt-sync/vocab/crdt-algorithms#> .
@prefix mappings: <https://w3id.org/solid-crdt-sync/mappings/> .
@prefix mc: <https://w3id.org/solid-crdt-sync/vocab/merge-contract#> .
@prefix pn: <https://locorda.dev/example/personal_notes_app/vocabulary/personal-notes#> .
@prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
@prefix schema: <https://schema.org/> .

GRAPH <https://locorda.dev/example/personal_notes_app/mappings/note-v1#> {
  <https://locorda.dev/example/personal_notes_app/mappings/note-v1#> a mc:DocumentMapping;
      rdfs:comment "Defines how personal notes should merge when conflicts occur during sync.";
      rdfs:label "Personal Note CRDT Document Mapping v1";
      mc:classMapping (
          [
              a mc:ClassMapping ;
              mc:appliesToClass schema:Comment ;
              mc:rule [ mc:predicate schema:text ; ca:mergeWith ca:LWW_Register ],
                  [ mc:predicate schema:dateCreated ; ca:mergeWith ca:Immutable ]
          ]
          [
              a mc:ClassMapping ;
              mc:appliesToClass pn:PersonalNote ;
              mc:rule [ mc:predicate schema:name ; ca:mergeWith ca:LWW_Register ],
                  [ mc:predicate schema:text ; ca:mergeWith ca:LWW_Register ],
                  [ mc:predicate schema:keywords ; ca:mergeWith ca:OR_Set ],
                  [ mc:predicate pn:belongsToCategory ; ca:mergeWith ca:LWW_Register ],
                  [ mc:predicate schema:dateCreated ; ca:mergeWith ca:Immutable ],
                  [ mc:predicate schema:dateModified ; ca:mergeWith ca:LWW_Register ],
                  [ mc:predicate schema:relatedLink ; ca:mergeWith ca:OR_Set ],
                  [ mc:predicate schema:comment ; ca:mergeWith ca:OR_Set ]
          ]
          [
              a mc:ClassMapping ;
              mc:appliesToClass pn:Weblink ;
              mc:rule [ mc:predicate schema:url ; ca:mergeWith ca:Immutable ; mc:isIdentifying true ],
                  [ mc:predicate schema:name ; ca:mergeWith ca:LWW_Register ],
                  [ mc:predicate schema:description ; ca:mergeWith ca:LWW_Register ]
          ]
      );
      mc:imports (mappings:core-v1);
      mc:predicateMapping () .
}
""",

];
