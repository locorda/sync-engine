// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: prefer_single_quotes

const List<String> bootstrapMappings = [
  r"""
@base <https://locorda.dev/example/minimal/> .
@prefix ca: <https://w3id.org/solid-crdt-sync/vocab/crdt-algorithms#> .
@prefix dcterms: <http://purl.org/dc/terms/> .
@prefix mappings: <https://w3id.org/solid-crdt-sync/mappings/> .
@prefix mc: <https://w3id.org/solid-crdt-sync/vocab/merge-contract#> .
@prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .

GRAPH <mappings/task-v1#> {
  <mappings/task-v1#> a mc:DocumentMapping;
      mc:classMapping (
          [
              a mc:ClassMapping ;
              mc:appliesToClass <vocab#Task> ;
              mc:rule [ mc:predicate <vocab#id> ; ca:mergeWith ca:LWW_Register ],
                  [ mc:predicate dcterms:title ; ca:mergeWith ca:LWW_Register ],
                  [ mc:predicate <vocab#completed> ; ca:mergeWith ca:LWW_Register ],
                  [ mc:predicate <vocab#createdAt> ; ca:mergeWith ca:LWW_Register ]
          ]
      );
      mc:imports (mappings:core-v1);
      mc:predicateMapping () .
}
""",

];
