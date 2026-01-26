/// Service for managing installation identity and lifecycle.
library;

import 'package:locorda_core/locorda_core.dart';
import 'package:locorda_core/src/vocab/generated/_index.dart';
import 'package:locorda_core/src/hlc_service.dart';
import 'package:locorda_core/src/rdf/rdf_extensions.dart';
import 'package:locorda_rdf_core/core.dart';
import 'package:uuid/uuid.dart';

/// Factory function for generating installation IDs.
///
/// Returns a simple string identifier (not a full IRI).
/// Default implementation generates a UUID v4.
typedef InstallationIdFactory = String Function();

/// Settings keys for installation management
class InstallationSettings {
  static const installationIri = 'installation_iri';
  static const installationLocalId = 'installation_local_id';
  static const installationDocumentSaved = 'installation_document_saved';
}

/// Service for managing installation identity and document lifecycle.
///
/// Responsibilities:
/// - Generate and persist unique installation IRI on first run
/// - Track whether installation document has been saved
/// - Provide installation IRI for HLC operations
class InstallationService {
  final Storage _storage;
  final IriTerm installationIri;
  final String installationLocalId;
  final bool installationDocumentSaved;
  final IriTermFactory _iriFactory;
  final PhysicalTimestampFactory _physicalTimestampFactory;

  InstallationService._({
    required Storage storage,
    required this.installationIri,
    required this.installationLocalId,
    required this.installationDocumentSaved,
    required IriTermFactory iriTermFactory,
    required PhysicalTimestampFactory physicalTimestampFactory,
  })  : _storage = storage,
        _iriFactory = iriTermFactory,
        _physicalTimestampFactory = physicalTimestampFactory;

  /// Initialize installation service by loading or creating installation identity.
  ///
  /// On first run:
  /// - Generates installation ID via factory (default: UUID v4)
  /// - Creates local IRI using LocalResourceLocator
  /// - Stores installation IRI in settings
  ///
  /// On subsequent runs:
  /// - Loads existing installation IRI from settings
  /// - Loads installation document saved flag
  static Future<InstallationService> create({
    required Storage storage,
    required LocalResourceLocator resourceLocator,
    InstallationIdFactory? installationIdFactory,
    IriTermFactory iriTermFactory = IriTerm.validated,
    required PhysicalTimestampFactory physicalTimestampFactory,
  }) async {
    installationIdFactory ??= () => const Uuid().v4();
    // Load settings in single request
    final settings = await storage.getSettings([
      InstallationSettings.installationIri,
      InstallationSettings.installationLocalId,
      InstallationSettings.installationDocumentSaved,
    ]);

    final IriTerm installationIri;
    final String installationLocalId;

    if (settings.containsKey(InstallationSettings.installationIri)) {
      // Load existing installation IRI and localId
      installationIri =
          iriTermFactory(settings[InstallationSettings.installationIri]!);
      installationLocalId = settings[InstallationSettings.installationLocalId]!;
    } else {
      // Generate new installation ID and IRI with 'installation' fragment
      installationLocalId = installationIdFactory();
      installationIri =
          createInstallationIri(resourceLocator, installationLocalId);

      // Persist both installation IRI and localId
      await storage.setSetting(
        InstallationSettings.installationLocalId,
        installationLocalId,
      );
      await storage.setSetting(
        InstallationSettings.installationIri,
        installationIri.value,
      );
    }

    final installationDocumentSaved =
        settings[InstallationSettings.installationDocumentSaved] == 'true';

    return InstallationService._(
        storage: storage,
        installationIri: installationIri,
        installationLocalId: installationLocalId,
        installationDocumentSaved: installationDocumentSaved,
        iriTermFactory: iriTermFactory,
        physicalTimestampFactory: physicalTimestampFactory);
  }

  static IriTerm createInstallationIri(
      LocalResourceLocator resourceLocator, String installationLocalId) {
    return resourceLocator.toIri(ResourceIdentifier(
      CrdtClientInstallation.classIri,
      installationLocalId,
      'installation',
    ));
  }

  /// Mark installation document as saved.
  ///
  /// Should be called after successfully saving the installation document
  /// through the normal saveDocument flow.
  Future<void> markInstallationDocumentSaved() async {
    await _storage.setSetting(
      InstallationSettings.installationDocumentSaved,
      'true',
    );
  }

  Future<void> ensureDocumentSaved(SyncEngine sync) async {
    // Initialize installation document if needed
    if (!installationDocumentSaved) {
      final iri = installationIri;
      final now = _physicalTimestampFactory();
      final clientInstallation = RdfGraph.fromTriples([
        Triple(iri, Rdf.type, CrdtClientInstallation.classIri),
        // Created timestamp
        Triple(
          iri,
          CrdtClientInstallation.createdAt,
          LiteralTermExtensions.dateTime(now),
        ),
        // Last active timestamp
        Triple(
          iri,
          CrdtClientInstallation.lastActiveAt,
          LiteralTermExtensions.dateTime(now),
        ),
        // Default max inactivity period (6 months)
        Triple(
          iri,
          CrdtClientInstallation.maxInactivityPeriod,
          LiteralTerm(
            'P6M',
            datatype: _iriFactory('http://www.w3.org/2001/XMLSchema#duration'),
          ),
        ),
      ]);
      await sync.save(CrdtClientInstallation.classIri, clientInstallation);
      await markInstallationDocumentSaved();
    }
  }
}
