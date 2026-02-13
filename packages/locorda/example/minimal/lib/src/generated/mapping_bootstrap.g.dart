// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: prefer_single_quotes

const List<String> bootstrapMappings = [
  r"""
@prefix ca: <https://w3id.org/solid-crdt-sync/vocab/crdt-algorithms#> .
@prefix mappings: <https://w3id.org/solid-crdt-sync/mappings/> .
@prefix mc: <https://w3id.org/solid-crdt-sync/vocab/merge-contract#> .
@prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
@prefix schema: <https://schema.org/> .
@prefix task: <https://locorda.dev/example/minimal/vocabulary/task#> .

GRAPH <https://locorda.dev/example/minimal/mappings/task-v1#> {
  <https://locorda.dev/example/minimal/mappings/task-v1#> a mc:DocumentMapping;
      mc:classMapping (
          [
              a mc:ClassMapping ;
              mc:appliesToClass task:Task ;
              mc:rule (
                      [ mc:predicate schema:name ; ca:mergeWith ca:LWW_Register ]
                      [ mc:predicate task:completed ; ca:mergeWith ca:LWW_Register ]
                      [ mc:predicate schema:dateCreated ; ca:mergeWith ca:Immutable ]
                  )
          ]
      );
      mc:imports (mappings:core-v1);
      mc:predicateMapping () .
}
""",

];
