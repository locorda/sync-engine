import 'package:locorda_core/locorda_core.dart';

import 'package:locorda_objects/src/config/locorda_config_util.dart'
    show ResourceTypeCache;
import 'package:locorda_objects/src/mapping/local_resource_iri_service.dart'
    show LocalResourceIriService;
import 'package:locorda_objects/src/mapping/solid_mapping_context.dart'
    show SolidMappingContext;
import 'package:locorda_rdf_core/core.dart';
import 'package:locorda_rdf_mapper/mapper.dart';

RdfMapper createTestMapper(
    {required Map<Type, IriTerm> resourceTypes,
    IriTermFactory? iriTermFactory,
    RdfCore? rdfCore,
    required RdfMapper Function(
            RdfMapper rdfMapper,
            IriTermMapper<(String id,)> Function<T>(Type) indexItemIriFactory,
            IriTermMapper<(String id,)> Function<T>(RootIriConfig)
                resourceIriFactory,
            IriTermMapper<String> Function<T>(Type) resourceRefFactory)
        initRdfMapper}) {
  // Initialize mapper exactly as in Locorda.setup()
  iriTermFactory ??= IriTerm.validated;
  rdfCore ??= RdfCore.withStandardCodecs();

  final localResourceLocator =
      LocalResourceLocator(iriTermFactory: iriTermFactory);
  final iriService = LocalResourceIriService(localResourceLocator);

  final context = SolidMappingContext(
    resourceIriFactory: iriService.createResourceIriMapper,
    resourceRefFactory: iriService.createResourceRefMapper,
    indexItemIriFactory: iriService.createIndexItemIriMapper,
    baseRdfMapper: RdfMapper(
      registry: RdfMapperRegistry(),
      iriTermFactory: iriTermFactory,
      rdfCore: rdfCore,
    ),
  );

  RdfMapper mapper = initRdfMapper(
    context.baseRdfMapper,
    context.indexItemIriFactory,
    context.resourceIriFactory,
    context.resourceRefFactory,
  );
  final validation = iriService.finishSetupAndValidate(
    ResourceTypeCache(resourceTypes),
  );
  validation.throwIfInvalid();
  return mapper;
}
