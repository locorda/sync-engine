/// Context object providing framework services to mapper initializers.
///
/// This is passed to user-provided mapper initializer functions, allowing
/// them to access framework-managed services like IRI strategies, auth
/// providers, and type index resolvers.
library;

import 'package:locorda_rdf_mapper/mapper.dart';
import 'package:locorda_core/locorda_core.dart';

/// Provides framework services to mapper initializer functions.
///
/// When users provide a `mapperInitializer` function to `Locorda.setup()`,
/// it receives this context object containing all the framework-managed
/// services needed to configure RDF mapping for Solid Pods.
class SolidMappingContext {
  IriTermMapper<(String id,)> Function<T>(RootIriConfig) resourceIriFactory;
  IriTermMapper<(String id,)> Function<T>(Type) indexItemIriFactory;
  IriTermMapper<String> Function<T>(Type) resourceRefFactory;
  RdfMapper baseRdfMapper;
  SolidMappingContext({
    required this.resourceIriFactory,
    required this.resourceRefFactory,
    required this.indexItemIriFactory,
    required this.baseRdfMapper,
  });
}
