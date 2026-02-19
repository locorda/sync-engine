/// Solid Pod resource annotation for RDF classes stored in Solid Pods.
library;

import 'package:locorda_rdf_mapper_annotations/annotations.dart';

const resourceRefFactoryKey = r'$resourceRefFactory';

class RootResourceRef extends IriMapping {
  const RootResourceRef(Type cls)
      : super.namedFactory(resourceRefFactoryKey, cls);
}
