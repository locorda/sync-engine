// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: prefer_single_quotes

const List<String> bootstrapMappings = [
  r"""
@base <https://locorda.dev/example/personal_notes_app/> .
@prefix ca: <https://w3id.org/solid-crdt-sync/vocab/crdt-algorithms#> .
@prefix mappings: <https://w3id.org/solid-crdt-sync/mappings/> .
@prefix mc: <https://w3id.org/solid-crdt-sync/vocab/merge-contract#> .
@prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
@prefix schema: <https://schema.org/> .

GRAPH <mappings/category-v1#> {
  <mappings/category-v1#> a mc:DocumentMapping;
      rdfs:comment "Defines how note categories should merge when conflicts occur during sync.";
      rdfs:label "Notes Category CRDT Document Mapping v1";
      mc:classMapping (
          [
              a mc:ClassMapping ;
              mc:appliesToClass <vocabulary/personal-notes#Category> ;
              mc:rule [ mc:predicate <vocabulary/personal-notes#id> ; ca:mergeWith ca:LWW_Register ],
                  [ mc:predicate schema:name ; ca:mergeWith ca:LWW_Register ],
                  [ mc:predicate schema:description ; ca:mergeWith ca:LWW_Register ],
                  [
                      mc:predicate <vocabulary/personal-notes#displaySettings> ;
                      ca:mergeWith ca:LWW_Register
                  ],
                  [ mc:predicate schema:dateCreated ; ca:mergeWith ca:Immutable ],
                  [ mc:predicate schema:dateModified ; ca:mergeWith ca:LWW_Register ],
                  [
                      mc:predicate <vocabulary/personal-notes#archived> ;
                      ca:mergeWith ca:LWW_Register
                  ]
          ]
          [
              a mc:ClassMapping ;
              mc:appliesToClass <vocabulary/personal-notes#CategoryDisplaySettings> ;
              mc:rule [
                      mc:predicate <vocabulary/personal-notes#categoryColor> ;
                      ca:mergeWith ca:LWW_Register
                  ],
                  [
                      mc:predicate <vocabulary/personal-notes#categoryIcon> ;
                      ca:mergeWith ca:LWW_Register
                  ]
          ]
      );
      mc:imports (mappings:core-v1);
      mc:predicateMapping () .
}
""",
  r"""
@base <https://locorda.dev/example/personal_notes_app/> .
@prefix ca: <https://w3id.org/solid-crdt-sync/vocab/crdt-algorithms#> .
@prefix mappings: <https://w3id.org/solid-crdt-sync/mappings/> .
@prefix mc: <https://w3id.org/solid-crdt-sync/vocab/merge-contract#> .
@prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
@prefix schema: <https://schema.org/> .

GRAPH <mappings/note-v1#> {
  <mappings/note-v1#> a mc:DocumentMapping;
      rdfs:comment "Defines how personal notes should merge when conflicts occur during sync.";
      rdfs:label "Personal Note CRDT Document Mapping v1";
      mc:classMapping (
          [
              a mc:ClassMapping ;
              mc:appliesToClass <vocabulary/personal-notes#Comment> ;
              mc:rule [ mc:predicate <vocabulary/personal-notes#id> ; ca:mergeWith ca:LWW_Register ],
                  [ mc:predicate schema:text ; ca:mergeWith ca:LWW_Register ],
                  [ mc:predicate schema:dateCreated ; ca:mergeWith ca:Immutable ]
          ]
          [
              a mc:ClassMapping ;
              mc:appliesToClass <vocabulary/personal-notes#Note> ;
              mc:rule [ mc:predicate <vocabulary/personal-notes#id> ; ca:mergeWith ca:LWW_Register ],
                  [ mc:predicate schema:name ; ca:mergeWith ca:LWW_Register ],
                  [ mc:predicate schema:text ; ca:mergeWith ca:LWW_Register ],
                  [ mc:predicate schema:keywords ; ca:mergeWith ca:OR_Set ],
                  [
                      mc:predicate <vocabulary/personal-notes#belongsToCategory> ;
                      ca:mergeWith ca:LWW_Register
                  ],
                  [ mc:predicate schema:dateCreated ; ca:mergeWith ca:Immutable ],
                  [ mc:predicate schema:dateModified ; ca:mergeWith ca:LWW_Register ],
                  [ mc:predicate schema:relatedLink ; ca:mergeWith ca:OR_Set ],
                  [ mc:predicate schema:comment ; ca:mergeWith ca:OR_Set ]
          ]
          [
              a mc:ClassMapping ;
              mc:appliesToClass <vocabulary/personal-notes#Weblink> ;
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
