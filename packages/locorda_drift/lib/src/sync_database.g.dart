// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'sync_database.dart';

// ignore_for_file: type=lint
mixin _$SyncDocumentDaoMixin on DatabaseAccessor<SyncDatabase> {
  $SyncIrisTable get syncIris => attachedDatabase.syncIris;
  $SyncDocumentsTable get syncDocuments => attachedDatabase.syncDocuments;
  SyncDocumentDaoManager get managers => SyncDocumentDaoManager(this);
}

class SyncDocumentDaoManager {
  final _$SyncDocumentDaoMixin _db;
  SyncDocumentDaoManager(this._db);
  $$SyncIrisTableTableManager get syncIris =>
      $$SyncIrisTableTableManager(_db.attachedDatabase, _db.syncIris);
  $$SyncDocumentsTableTableManager get syncDocuments =>
      $$SyncDocumentsTableTableManager(_db.attachedDatabase, _db.syncDocuments);
}

mixin _$SyncPropertyChangeDaoMixin on DatabaseAccessor<SyncDatabase> {
  $SyncIrisTable get syncIris => attachedDatabase.syncIris;
  $SyncDocumentsTable get syncDocuments => attachedDatabase.syncDocuments;
  $SyncPropertyChangesTable get syncPropertyChanges =>
      attachedDatabase.syncPropertyChanges;
  SyncPropertyChangeDaoManager get managers =>
      SyncPropertyChangeDaoManager(this);
}

class SyncPropertyChangeDaoManager {
  final _$SyncPropertyChangeDaoMixin _db;
  SyncPropertyChangeDaoManager(this._db);
  $$SyncIrisTableTableManager get syncIris =>
      $$SyncIrisTableTableManager(_db.attachedDatabase, _db.syncIris);
  $$SyncDocumentsTableTableManager get syncDocuments =>
      $$SyncDocumentsTableTableManager(_db.attachedDatabase, _db.syncDocuments);
  $$SyncPropertyChangesTableTableManager get syncPropertyChanges =>
      $$SyncPropertyChangesTableTableManager(
          _db.attachedDatabase, _db.syncPropertyChanges);
}

mixin _$IndexDaoMixin on DatabaseAccessor<SyncDatabase> {
  $SyncIrisTable get syncIris => attachedDatabase.syncIris;
  $IndexEntriesTable get indexEntries => attachedDatabase.indexEntries;
  $GroupIndexSubscriptionsTable get groupIndexSubscriptions =>
      attachedDatabase.groupIndexSubscriptions;
  $IndexIriIdSetVersionsTable get indexIriIdSetVersions =>
      attachedDatabase.indexIriIdSetVersions;
  IndexDaoManager get managers => IndexDaoManager(this);
}

class IndexDaoManager {
  final _$IndexDaoMixin _db;
  IndexDaoManager(this._db);
  $$SyncIrisTableTableManager get syncIris =>
      $$SyncIrisTableTableManager(_db.attachedDatabase, _db.syncIris);
  $$IndexEntriesTableTableManager get indexEntries =>
      $$IndexEntriesTableTableManager(_db.attachedDatabase, _db.indexEntries);
  $$GroupIndexSubscriptionsTableTableManager get groupIndexSubscriptions =>
      $$GroupIndexSubscriptionsTableTableManager(
          _db.attachedDatabase, _db.groupIndexSubscriptions);
  $$IndexIriIdSetVersionsTableTableManager get indexIriIdSetVersions =>
      $$IndexIriIdSetVersionsTableTableManager(
          _db.attachedDatabase, _db.indexIriIdSetVersions);
}

mixin _$RemoteSyncStateDaoMixin on DatabaseAccessor<SyncDatabase> {
  $RemoteSettingsTable get remoteSettings => attachedDatabase.remoteSettings;
  $SyncIrisTable get syncIris => attachedDatabase.syncIris;
  $RemoteSyncStateTable get remoteSyncState => attachedDatabase.remoteSyncState;
  RemoteSyncStateDaoManager get managers => RemoteSyncStateDaoManager(this);
}

class RemoteSyncStateDaoManager {
  final _$RemoteSyncStateDaoMixin _db;
  RemoteSyncStateDaoManager(this._db);
  $$RemoteSettingsTableTableManager get remoteSettings =>
      $$RemoteSettingsTableTableManager(
          _db.attachedDatabase, _db.remoteSettings);
  $$SyncIrisTableTableManager get syncIris =>
      $$SyncIrisTableTableManager(_db.attachedDatabase, _db.syncIris);
  $$RemoteSyncStateTableTableManager get remoteSyncState =>
      $$RemoteSyncStateTableTableManager(
          _db.attachedDatabase, _db.remoteSyncState);
}

class $SyncIrisTable extends SyncIris with TableInfo<$SyncIrisTable, SyncIri> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncIrisTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _iriMeta = const VerificationMeta('iri');
  @override
  late final GeneratedColumn<String> iri = GeneratedColumn<String>(
      'iri', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways('UNIQUE'));
  @override
  List<GeneratedColumn> get $columns => [id, iri];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_iris';
  @override
  VerificationContext validateIntegrity(Insertable<SyncIri> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('iri')) {
      context.handle(
          _iriMeta, iri.isAcceptableOrUnknown(data['iri']!, _iriMeta));
    } else if (isInserting) {
      context.missing(_iriMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SyncIri map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncIri(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      iri: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}iri'])!,
    );
  }

  @override
  $SyncIrisTable createAlias(String alias) {
    return $SyncIrisTable(attachedDatabase, alias);
  }
}

class SyncIri extends DataClass implements Insertable<SyncIri> {
  final int id;
  final String iri;
  const SyncIri({required this.id, required this.iri});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['iri'] = Variable<String>(iri);
    return map;
  }

  SyncIrisCompanion toCompanion(bool nullToAbsent) {
    return SyncIrisCompanion(
      id: Value(id),
      iri: Value(iri),
    );
  }

  factory SyncIri.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncIri(
      id: serializer.fromJson<int>(json['id']),
      iri: serializer.fromJson<String>(json['iri']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'iri': serializer.toJson<String>(iri),
    };
  }

  SyncIri copyWith({int? id, String? iri}) => SyncIri(
        id: id ?? this.id,
        iri: iri ?? this.iri,
      );
  SyncIri copyWithCompanion(SyncIrisCompanion data) {
    return SyncIri(
      id: data.id.present ? data.id.value : this.id,
      iri: data.iri.present ? data.iri.value : this.iri,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncIri(')
          ..write('id: $id, ')
          ..write('iri: $iri')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, iri);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncIri && other.id == this.id && other.iri == this.iri);
}

class SyncIrisCompanion extends UpdateCompanion<SyncIri> {
  final Value<int> id;
  final Value<String> iri;
  const SyncIrisCompanion({
    this.id = const Value.absent(),
    this.iri = const Value.absent(),
  });
  SyncIrisCompanion.insert({
    this.id = const Value.absent(),
    required String iri,
  }) : iri = Value(iri);
  static Insertable<SyncIri> custom({
    Expression<int>? id,
    Expression<String>? iri,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (iri != null) 'iri': iri,
    });
  }

  SyncIrisCompanion copyWith({Value<int>? id, Value<String>? iri}) {
    return SyncIrisCompanion(
      id: id ?? this.id,
      iri: iri ?? this.iri,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (iri.present) {
      map['iri'] = Variable<String>(iri.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncIrisCompanion(')
          ..write('id: $id, ')
          ..write('iri: $iri')
          ..write(')'))
        .toString();
  }
}

class $SyncDocumentsTable extends SyncDocuments
    with TableInfo<$SyncDocumentsTable, SyncDocument> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncDocumentsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _documentIriIdMeta =
      const VerificationMeta('documentIriId');
  @override
  late final GeneratedColumn<int> documentIriId = GeneratedColumn<int>(
      'document_iri_id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'UNIQUE REFERENCES sync_iris (id)'));
  static const VerificationMeta _typeIriIdMeta =
      const VerificationMeta('typeIriId');
  @override
  late final GeneratedColumn<int> typeIriId = GeneratedColumn<int>(
      'type_iri_id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('REFERENCES sync_iris (id)'));
  static const VerificationMeta _documentContentMeta =
      const VerificationMeta('documentContent');
  @override
  late final GeneratedColumn<String> documentContent = GeneratedColumn<String>(
      'document_content', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _ourPhysicalClockMeta =
      const VerificationMeta('ourPhysicalClock');
  @override
  late final GeneratedColumn<int> ourPhysicalClock = GeneratedColumn<int>(
      'our_physical_clock', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        documentIriId,
        typeIriId,
        documentContent,
        ourPhysicalClock,
        updatedAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_documents';
  @override
  VerificationContext validateIntegrity(Insertable<SyncDocument> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('document_iri_id')) {
      context.handle(
          _documentIriIdMeta,
          documentIriId.isAcceptableOrUnknown(
              data['document_iri_id']!, _documentIriIdMeta));
    } else if (isInserting) {
      context.missing(_documentIriIdMeta);
    }
    if (data.containsKey('type_iri_id')) {
      context.handle(
          _typeIriIdMeta,
          typeIriId.isAcceptableOrUnknown(
              data['type_iri_id']!, _typeIriIdMeta));
    } else if (isInserting) {
      context.missing(_typeIriIdMeta);
    }
    if (data.containsKey('document_content')) {
      context.handle(
          _documentContentMeta,
          documentContent.isAcceptableOrUnknown(
              data['document_content']!, _documentContentMeta));
    } else if (isInserting) {
      context.missing(_documentContentMeta);
    }
    if (data.containsKey('our_physical_clock')) {
      context.handle(
          _ourPhysicalClockMeta,
          ourPhysicalClock.isAcceptableOrUnknown(
              data['our_physical_clock']!, _ourPhysicalClockMeta));
    } else if (isInserting) {
      context.missing(_ourPhysicalClockMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SyncDocument map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncDocument(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      documentIriId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}document_iri_id'])!,
      typeIriId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}type_iri_id'])!,
      documentContent: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}document_content'])!,
      ourPhysicalClock: attachedDatabase.typeMapping.read(
          DriftSqlType.int, data['${effectivePrefix}our_physical_clock'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $SyncDocumentsTable createAlias(String alias) {
    return $SyncDocumentsTable(attachedDatabase, alias);
  }
}

class SyncDocument extends DataClass implements Insertable<SyncDocument> {
  final int id;
  final int documentIriId;
  final int typeIriId;
  final String documentContent;
  final int ourPhysicalClock;
  final int updatedAt;
  const SyncDocument(
      {required this.id,
      required this.documentIriId,
      required this.typeIriId,
      required this.documentContent,
      required this.ourPhysicalClock,
      required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['document_iri_id'] = Variable<int>(documentIriId);
    map['type_iri_id'] = Variable<int>(typeIriId);
    map['document_content'] = Variable<String>(documentContent);
    map['our_physical_clock'] = Variable<int>(ourPhysicalClock);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  SyncDocumentsCompanion toCompanion(bool nullToAbsent) {
    return SyncDocumentsCompanion(
      id: Value(id),
      documentIriId: Value(documentIriId),
      typeIriId: Value(typeIriId),
      documentContent: Value(documentContent),
      ourPhysicalClock: Value(ourPhysicalClock),
      updatedAt: Value(updatedAt),
    );
  }

  factory SyncDocument.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncDocument(
      id: serializer.fromJson<int>(json['id']),
      documentIriId: serializer.fromJson<int>(json['documentIriId']),
      typeIriId: serializer.fromJson<int>(json['typeIriId']),
      documentContent: serializer.fromJson<String>(json['documentContent']),
      ourPhysicalClock: serializer.fromJson<int>(json['ourPhysicalClock']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'documentIriId': serializer.toJson<int>(documentIriId),
      'typeIriId': serializer.toJson<int>(typeIriId),
      'documentContent': serializer.toJson<String>(documentContent),
      'ourPhysicalClock': serializer.toJson<int>(ourPhysicalClock),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  SyncDocument copyWith(
          {int? id,
          int? documentIriId,
          int? typeIriId,
          String? documentContent,
          int? ourPhysicalClock,
          int? updatedAt}) =>
      SyncDocument(
        id: id ?? this.id,
        documentIriId: documentIriId ?? this.documentIriId,
        typeIriId: typeIriId ?? this.typeIriId,
        documentContent: documentContent ?? this.documentContent,
        ourPhysicalClock: ourPhysicalClock ?? this.ourPhysicalClock,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  SyncDocument copyWithCompanion(SyncDocumentsCompanion data) {
    return SyncDocument(
      id: data.id.present ? data.id.value : this.id,
      documentIriId: data.documentIriId.present
          ? data.documentIriId.value
          : this.documentIriId,
      typeIriId: data.typeIriId.present ? data.typeIriId.value : this.typeIriId,
      documentContent: data.documentContent.present
          ? data.documentContent.value
          : this.documentContent,
      ourPhysicalClock: data.ourPhysicalClock.present
          ? data.ourPhysicalClock.value
          : this.ourPhysicalClock,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncDocument(')
          ..write('id: $id, ')
          ..write('documentIriId: $documentIriId, ')
          ..write('typeIriId: $typeIriId, ')
          ..write('documentContent: $documentContent, ')
          ..write('ourPhysicalClock: $ourPhysicalClock, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, documentIriId, typeIriId, documentContent,
      ourPhysicalClock, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncDocument &&
          other.id == this.id &&
          other.documentIriId == this.documentIriId &&
          other.typeIriId == this.typeIriId &&
          other.documentContent == this.documentContent &&
          other.ourPhysicalClock == this.ourPhysicalClock &&
          other.updatedAt == this.updatedAt);
}

class SyncDocumentsCompanion extends UpdateCompanion<SyncDocument> {
  final Value<int> id;
  final Value<int> documentIriId;
  final Value<int> typeIriId;
  final Value<String> documentContent;
  final Value<int> ourPhysicalClock;
  final Value<int> updatedAt;
  const SyncDocumentsCompanion({
    this.id = const Value.absent(),
    this.documentIriId = const Value.absent(),
    this.typeIriId = const Value.absent(),
    this.documentContent = const Value.absent(),
    this.ourPhysicalClock = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  SyncDocumentsCompanion.insert({
    this.id = const Value.absent(),
    required int documentIriId,
    required int typeIriId,
    required String documentContent,
    required int ourPhysicalClock,
    required int updatedAt,
  })  : documentIriId = Value(documentIriId),
        typeIriId = Value(typeIriId),
        documentContent = Value(documentContent),
        ourPhysicalClock = Value(ourPhysicalClock),
        updatedAt = Value(updatedAt);
  static Insertable<SyncDocument> custom({
    Expression<int>? id,
    Expression<int>? documentIriId,
    Expression<int>? typeIriId,
    Expression<String>? documentContent,
    Expression<int>? ourPhysicalClock,
    Expression<int>? updatedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (documentIriId != null) 'document_iri_id': documentIriId,
      if (typeIriId != null) 'type_iri_id': typeIriId,
      if (documentContent != null) 'document_content': documentContent,
      if (ourPhysicalClock != null) 'our_physical_clock': ourPhysicalClock,
      if (updatedAt != null) 'updated_at': updatedAt,
    });
  }

  SyncDocumentsCompanion copyWith(
      {Value<int>? id,
      Value<int>? documentIriId,
      Value<int>? typeIriId,
      Value<String>? documentContent,
      Value<int>? ourPhysicalClock,
      Value<int>? updatedAt}) {
    return SyncDocumentsCompanion(
      id: id ?? this.id,
      documentIriId: documentIriId ?? this.documentIriId,
      typeIriId: typeIriId ?? this.typeIriId,
      documentContent: documentContent ?? this.documentContent,
      ourPhysicalClock: ourPhysicalClock ?? this.ourPhysicalClock,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (documentIriId.present) {
      map['document_iri_id'] = Variable<int>(documentIriId.value);
    }
    if (typeIriId.present) {
      map['type_iri_id'] = Variable<int>(typeIriId.value);
    }
    if (documentContent.present) {
      map['document_content'] = Variable<String>(documentContent.value);
    }
    if (ourPhysicalClock.present) {
      map['our_physical_clock'] = Variable<int>(ourPhysicalClock.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncDocumentsCompanion(')
          ..write('id: $id, ')
          ..write('documentIriId: $documentIriId, ')
          ..write('typeIriId: $typeIriId, ')
          ..write('documentContent: $documentContent, ')
          ..write('ourPhysicalClock: $ourPhysicalClock, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }
}

class $SyncPropertyChangesTable extends SyncPropertyChanges
    with TableInfo<$SyncPropertyChangesTable, SyncPropertyChange> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncPropertyChangesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _documentIdMeta =
      const VerificationMeta('documentId');
  @override
  late final GeneratedColumn<int> documentId = GeneratedColumn<int>(
      'document_id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('REFERENCES sync_documents (id)'));
  static const VerificationMeta _resourceIriIdMeta =
      const VerificationMeta('resourceIriId');
  @override
  late final GeneratedColumn<int> resourceIriId = GeneratedColumn<int>(
      'resource_iri_id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('REFERENCES sync_iris (id)'));
  static const VerificationMeta _propertyIriIdMeta =
      const VerificationMeta('propertyIriId');
  @override
  late final GeneratedColumn<int> propertyIriId = GeneratedColumn<int>(
      'property_iri_id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('REFERENCES sync_iris (id)'));
  static const VerificationMeta _changedAtMsMeta =
      const VerificationMeta('changedAtMs');
  @override
  late final GeneratedColumn<int> changedAtMs = GeneratedColumn<int>(
      'changed_at_ms', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _changeLogicalClockMeta =
      const VerificationMeta('changeLogicalClock');
  @override
  late final GeneratedColumn<int> changeLogicalClock = GeneratedColumn<int>(
      'change_logical_clock', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _isFrameworkPropertyMeta =
      const VerificationMeta('isFrameworkProperty');
  @override
  late final GeneratedColumn<bool> isFrameworkProperty = GeneratedColumn<bool>(
      'is_framework_property', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'CHECK ("is_framework_property" IN (0, 1))'),
      defaultValue: const Constant(false));
  @override
  List<GeneratedColumn> get $columns => [
        documentId,
        resourceIriId,
        propertyIriId,
        changedAtMs,
        changeLogicalClock,
        isFrameworkProperty
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_property_changes';
  @override
  VerificationContext validateIntegrity(Insertable<SyncPropertyChange> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('document_id')) {
      context.handle(
          _documentIdMeta,
          documentId.isAcceptableOrUnknown(
              data['document_id']!, _documentIdMeta));
    } else if (isInserting) {
      context.missing(_documentIdMeta);
    }
    if (data.containsKey('resource_iri_id')) {
      context.handle(
          _resourceIriIdMeta,
          resourceIriId.isAcceptableOrUnknown(
              data['resource_iri_id']!, _resourceIriIdMeta));
    } else if (isInserting) {
      context.missing(_resourceIriIdMeta);
    }
    if (data.containsKey('property_iri_id')) {
      context.handle(
          _propertyIriIdMeta,
          propertyIriId.isAcceptableOrUnknown(
              data['property_iri_id']!, _propertyIriIdMeta));
    } else if (isInserting) {
      context.missing(_propertyIriIdMeta);
    }
    if (data.containsKey('changed_at_ms')) {
      context.handle(
          _changedAtMsMeta,
          changedAtMs.isAcceptableOrUnknown(
              data['changed_at_ms']!, _changedAtMsMeta));
    } else if (isInserting) {
      context.missing(_changedAtMsMeta);
    }
    if (data.containsKey('change_logical_clock')) {
      context.handle(
          _changeLogicalClockMeta,
          changeLogicalClock.isAcceptableOrUnknown(
              data['change_logical_clock']!, _changeLogicalClockMeta));
    } else if (isInserting) {
      context.missing(_changeLogicalClockMeta);
    }
    if (data.containsKey('is_framework_property')) {
      context.handle(
          _isFrameworkPropertyMeta,
          isFrameworkProperty.isAcceptableOrUnknown(
              data['is_framework_property']!, _isFrameworkPropertyMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey =>
      {documentId, resourceIriId, propertyIriId, changeLogicalClock};
  @override
  SyncPropertyChange map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncPropertyChange(
      documentId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}document_id'])!,
      resourceIriId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}resource_iri_id'])!,
      propertyIriId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}property_iri_id'])!,
      changedAtMs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}changed_at_ms'])!,
      changeLogicalClock: attachedDatabase.typeMapping.read(
          DriftSqlType.int, data['${effectivePrefix}change_logical_clock'])!,
      isFrameworkProperty: attachedDatabase.typeMapping.read(
          DriftSqlType.bool, data['${effectivePrefix}is_framework_property'])!,
    );
  }

  @override
  $SyncPropertyChangesTable createAlias(String alias) {
    return $SyncPropertyChangesTable(attachedDatabase, alias);
  }
}

class SyncPropertyChange extends DataClass
    implements Insertable<SyncPropertyChange> {
  final int documentId;
  final int resourceIriId;
  final int propertyIriId;
  final int changedAtMs;
  final int changeLogicalClock;
  final bool isFrameworkProperty;
  const SyncPropertyChange(
      {required this.documentId,
      required this.resourceIriId,
      required this.propertyIriId,
      required this.changedAtMs,
      required this.changeLogicalClock,
      required this.isFrameworkProperty});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['document_id'] = Variable<int>(documentId);
    map['resource_iri_id'] = Variable<int>(resourceIriId);
    map['property_iri_id'] = Variable<int>(propertyIriId);
    map['changed_at_ms'] = Variable<int>(changedAtMs);
    map['change_logical_clock'] = Variable<int>(changeLogicalClock);
    map['is_framework_property'] = Variable<bool>(isFrameworkProperty);
    return map;
  }

  SyncPropertyChangesCompanion toCompanion(bool nullToAbsent) {
    return SyncPropertyChangesCompanion(
      documentId: Value(documentId),
      resourceIriId: Value(resourceIriId),
      propertyIriId: Value(propertyIriId),
      changedAtMs: Value(changedAtMs),
      changeLogicalClock: Value(changeLogicalClock),
      isFrameworkProperty: Value(isFrameworkProperty),
    );
  }

  factory SyncPropertyChange.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncPropertyChange(
      documentId: serializer.fromJson<int>(json['documentId']),
      resourceIriId: serializer.fromJson<int>(json['resourceIriId']),
      propertyIriId: serializer.fromJson<int>(json['propertyIriId']),
      changedAtMs: serializer.fromJson<int>(json['changedAtMs']),
      changeLogicalClock: serializer.fromJson<int>(json['changeLogicalClock']),
      isFrameworkProperty:
          serializer.fromJson<bool>(json['isFrameworkProperty']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'documentId': serializer.toJson<int>(documentId),
      'resourceIriId': serializer.toJson<int>(resourceIriId),
      'propertyIriId': serializer.toJson<int>(propertyIriId),
      'changedAtMs': serializer.toJson<int>(changedAtMs),
      'changeLogicalClock': serializer.toJson<int>(changeLogicalClock),
      'isFrameworkProperty': serializer.toJson<bool>(isFrameworkProperty),
    };
  }

  SyncPropertyChange copyWith(
          {int? documentId,
          int? resourceIriId,
          int? propertyIriId,
          int? changedAtMs,
          int? changeLogicalClock,
          bool? isFrameworkProperty}) =>
      SyncPropertyChange(
        documentId: documentId ?? this.documentId,
        resourceIriId: resourceIriId ?? this.resourceIriId,
        propertyIriId: propertyIriId ?? this.propertyIriId,
        changedAtMs: changedAtMs ?? this.changedAtMs,
        changeLogicalClock: changeLogicalClock ?? this.changeLogicalClock,
        isFrameworkProperty: isFrameworkProperty ?? this.isFrameworkProperty,
      );
  SyncPropertyChange copyWithCompanion(SyncPropertyChangesCompanion data) {
    return SyncPropertyChange(
      documentId:
          data.documentId.present ? data.documentId.value : this.documentId,
      resourceIriId: data.resourceIriId.present
          ? data.resourceIriId.value
          : this.resourceIriId,
      propertyIriId: data.propertyIriId.present
          ? data.propertyIriId.value
          : this.propertyIriId,
      changedAtMs:
          data.changedAtMs.present ? data.changedAtMs.value : this.changedAtMs,
      changeLogicalClock: data.changeLogicalClock.present
          ? data.changeLogicalClock.value
          : this.changeLogicalClock,
      isFrameworkProperty: data.isFrameworkProperty.present
          ? data.isFrameworkProperty.value
          : this.isFrameworkProperty,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncPropertyChange(')
          ..write('documentId: $documentId, ')
          ..write('resourceIriId: $resourceIriId, ')
          ..write('propertyIriId: $propertyIriId, ')
          ..write('changedAtMs: $changedAtMs, ')
          ..write('changeLogicalClock: $changeLogicalClock, ')
          ..write('isFrameworkProperty: $isFrameworkProperty')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(documentId, resourceIriId, propertyIriId,
      changedAtMs, changeLogicalClock, isFrameworkProperty);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncPropertyChange &&
          other.documentId == this.documentId &&
          other.resourceIriId == this.resourceIriId &&
          other.propertyIriId == this.propertyIriId &&
          other.changedAtMs == this.changedAtMs &&
          other.changeLogicalClock == this.changeLogicalClock &&
          other.isFrameworkProperty == this.isFrameworkProperty);
}

class SyncPropertyChangesCompanion extends UpdateCompanion<SyncPropertyChange> {
  final Value<int> documentId;
  final Value<int> resourceIriId;
  final Value<int> propertyIriId;
  final Value<int> changedAtMs;
  final Value<int> changeLogicalClock;
  final Value<bool> isFrameworkProperty;
  final Value<int> rowid;
  const SyncPropertyChangesCompanion({
    this.documentId = const Value.absent(),
    this.resourceIriId = const Value.absent(),
    this.propertyIriId = const Value.absent(),
    this.changedAtMs = const Value.absent(),
    this.changeLogicalClock = const Value.absent(),
    this.isFrameworkProperty = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncPropertyChangesCompanion.insert({
    required int documentId,
    required int resourceIriId,
    required int propertyIriId,
    required int changedAtMs,
    required int changeLogicalClock,
    this.isFrameworkProperty = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : documentId = Value(documentId),
        resourceIriId = Value(resourceIriId),
        propertyIriId = Value(propertyIriId),
        changedAtMs = Value(changedAtMs),
        changeLogicalClock = Value(changeLogicalClock);
  static Insertable<SyncPropertyChange> custom({
    Expression<int>? documentId,
    Expression<int>? resourceIriId,
    Expression<int>? propertyIriId,
    Expression<int>? changedAtMs,
    Expression<int>? changeLogicalClock,
    Expression<bool>? isFrameworkProperty,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (documentId != null) 'document_id': documentId,
      if (resourceIriId != null) 'resource_iri_id': resourceIriId,
      if (propertyIriId != null) 'property_iri_id': propertyIriId,
      if (changedAtMs != null) 'changed_at_ms': changedAtMs,
      if (changeLogicalClock != null)
        'change_logical_clock': changeLogicalClock,
      if (isFrameworkProperty != null)
        'is_framework_property': isFrameworkProperty,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncPropertyChangesCompanion copyWith(
      {Value<int>? documentId,
      Value<int>? resourceIriId,
      Value<int>? propertyIriId,
      Value<int>? changedAtMs,
      Value<int>? changeLogicalClock,
      Value<bool>? isFrameworkProperty,
      Value<int>? rowid}) {
    return SyncPropertyChangesCompanion(
      documentId: documentId ?? this.documentId,
      resourceIriId: resourceIriId ?? this.resourceIriId,
      propertyIriId: propertyIriId ?? this.propertyIriId,
      changedAtMs: changedAtMs ?? this.changedAtMs,
      changeLogicalClock: changeLogicalClock ?? this.changeLogicalClock,
      isFrameworkProperty: isFrameworkProperty ?? this.isFrameworkProperty,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (documentId.present) {
      map['document_id'] = Variable<int>(documentId.value);
    }
    if (resourceIriId.present) {
      map['resource_iri_id'] = Variable<int>(resourceIriId.value);
    }
    if (propertyIriId.present) {
      map['property_iri_id'] = Variable<int>(propertyIriId.value);
    }
    if (changedAtMs.present) {
      map['changed_at_ms'] = Variable<int>(changedAtMs.value);
    }
    if (changeLogicalClock.present) {
      map['change_logical_clock'] = Variable<int>(changeLogicalClock.value);
    }
    if (isFrameworkProperty.present) {
      map['is_framework_property'] = Variable<bool>(isFrameworkProperty.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncPropertyChangesCompanion(')
          ..write('documentId: $documentId, ')
          ..write('resourceIriId: $resourceIriId, ')
          ..write('propertyIriId: $propertyIriId, ')
          ..write('changedAtMs: $changedAtMs, ')
          ..write('changeLogicalClock: $changeLogicalClock, ')
          ..write('isFrameworkProperty: $isFrameworkProperty, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncSettingsTable extends SyncSettings
    with TableInfo<$SyncSettingsTable, SyncSetting> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncSettingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
      'key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
      'value', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_settings';
  @override
  VerificationContext validateIntegrity(Insertable<SyncSetting> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
          _keyMeta, key.isAcceptableOrUnknown(data['key']!, _keyMeta));
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
          _valueMeta, value.isAcceptableOrUnknown(data['value']!, _valueMeta));
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  SyncSetting map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncSetting(
      key: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}key'])!,
      value: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}value'])!,
    );
  }

  @override
  $SyncSettingsTable createAlias(String alias) {
    return $SyncSettingsTable(attachedDatabase, alias);
  }
}

class SyncSetting extends DataClass implements Insertable<SyncSetting> {
  final String key;
  final String value;
  const SyncSetting({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  SyncSettingsCompanion toCompanion(bool nullToAbsent) {
    return SyncSettingsCompanion(
      key: Value(key),
      value: Value(value),
    );
  }

  factory SyncSetting.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncSetting(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  SyncSetting copyWith({String? key, String? value}) => SyncSetting(
        key: key ?? this.key,
        value: value ?? this.value,
      );
  SyncSetting copyWithCompanion(SyncSettingsCompanion data) {
    return SyncSetting(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncSetting(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncSetting &&
          other.key == this.key &&
          other.value == this.value);
}

class SyncSettingsCompanion extends UpdateCompanion<SyncSetting> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const SyncSettingsCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncSettingsCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  })  : key = Value(key),
        value = Value(value);
  static Insertable<SyncSetting> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncSettingsCompanion copyWith(
      {Value<String>? key, Value<String>? value, Value<int>? rowid}) {
    return SyncSettingsCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncSettingsCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $IndexEntriesTable extends IndexEntries
    with TableInfo<$IndexEntriesTable, IndexEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $IndexEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _shardIriMeta =
      const VerificationMeta('shardIri');
  @override
  late final GeneratedColumn<int> shardIri = GeneratedColumn<int>(
      'shard_iri', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('REFERENCES sync_iris (id)'));
  static const VerificationMeta _indexIriIdMeta =
      const VerificationMeta('indexIriId');
  @override
  late final GeneratedColumn<int> indexIriId = GeneratedColumn<int>(
      'index_iri_id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('REFERENCES sync_iris (id)'));
  static const VerificationMeta _resourceIriIdMeta =
      const VerificationMeta('resourceIriId');
  @override
  late final GeneratedColumn<int> resourceIriId = GeneratedColumn<int>(
      'resource_iri_id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('REFERENCES sync_iris (id)'));
  static const VerificationMeta _resourceTypeIriIdMeta =
      const VerificationMeta('resourceTypeIriId');
  @override
  late final GeneratedColumn<int> resourceTypeIriId = GeneratedColumn<int>(
      'resource_type_iri_id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('REFERENCES sync_iris (id)'));
  static const VerificationMeta _clockHashMeta =
      const VerificationMeta('clockHash');
  @override
  late final GeneratedColumn<String> clockHash = GeneratedColumn<String>(
      'clock_hash', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _headerPropertiesMeta =
      const VerificationMeta('headerProperties');
  @override
  late final GeneratedColumn<String> headerProperties = GeneratedColumn<String>(
      'header_properties', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _ourPhysicalClockMeta =
      const VerificationMeta('ourPhysicalClock');
  @override
  late final GeneratedColumn<int> ourPhysicalClock = GeneratedColumn<int>(
      'our_physical_clock', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _isDeletedMeta =
      const VerificationMeta('isDeleted');
  @override
  late final GeneratedColumn<bool> isDeleted = GeneratedColumn<bool>(
      'is_deleted', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("is_deleted" IN (0, 1))'),
      defaultValue: const Constant(false));
  @override
  List<GeneratedColumn> get $columns => [
        shardIri,
        indexIriId,
        resourceIriId,
        resourceTypeIriId,
        clockHash,
        headerProperties,
        updatedAt,
        ourPhysicalClock,
        isDeleted
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'index_entries';
  @override
  VerificationContext validateIntegrity(Insertable<IndexEntry> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('shard_iri')) {
      context.handle(_shardIriMeta,
          shardIri.isAcceptableOrUnknown(data['shard_iri']!, _shardIriMeta));
    } else if (isInserting) {
      context.missing(_shardIriMeta);
    }
    if (data.containsKey('index_iri_id')) {
      context.handle(
          _indexIriIdMeta,
          indexIriId.isAcceptableOrUnknown(
              data['index_iri_id']!, _indexIriIdMeta));
    } else if (isInserting) {
      context.missing(_indexIriIdMeta);
    }
    if (data.containsKey('resource_iri_id')) {
      context.handle(
          _resourceIriIdMeta,
          resourceIriId.isAcceptableOrUnknown(
              data['resource_iri_id']!, _resourceIriIdMeta));
    } else if (isInserting) {
      context.missing(_resourceIriIdMeta);
    }
    if (data.containsKey('resource_type_iri_id')) {
      context.handle(
          _resourceTypeIriIdMeta,
          resourceTypeIriId.isAcceptableOrUnknown(
              data['resource_type_iri_id']!, _resourceTypeIriIdMeta));
    } else if (isInserting) {
      context.missing(_resourceTypeIriIdMeta);
    }
    if (data.containsKey('clock_hash')) {
      context.handle(_clockHashMeta,
          clockHash.isAcceptableOrUnknown(data['clock_hash']!, _clockHashMeta));
    } else if (isInserting) {
      context.missing(_clockHashMeta);
    }
    if (data.containsKey('header_properties')) {
      context.handle(
          _headerPropertiesMeta,
          headerProperties.isAcceptableOrUnknown(
              data['header_properties']!, _headerPropertiesMeta));
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('our_physical_clock')) {
      context.handle(
          _ourPhysicalClockMeta,
          ourPhysicalClock.isAcceptableOrUnknown(
              data['our_physical_clock']!, _ourPhysicalClockMeta));
    } else if (isInserting) {
      context.missing(_ourPhysicalClockMeta);
    }
    if (data.containsKey('is_deleted')) {
      context.handle(_isDeletedMeta,
          isDeleted.isAcceptableOrUnknown(data['is_deleted']!, _isDeletedMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {shardIri, resourceIriId};
  @override
  IndexEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return IndexEntry(
      shardIri: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}shard_iri'])!,
      indexIriId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}index_iri_id'])!,
      resourceIriId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}resource_iri_id'])!,
      resourceTypeIriId: attachedDatabase.typeMapping.read(
          DriftSqlType.int, data['${effectivePrefix}resource_type_iri_id'])!,
      clockHash: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}clock_hash'])!,
      headerProperties: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}header_properties']),
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}updated_at'])!,
      ourPhysicalClock: attachedDatabase.typeMapping.read(
          DriftSqlType.int, data['${effectivePrefix}our_physical_clock'])!,
      isDeleted: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}is_deleted'])!,
    );
  }

  @override
  $IndexEntriesTable createAlias(String alias) {
    return $IndexEntriesTable(attachedDatabase, alias);
  }
}

class IndexEntry extends DataClass implements Insertable<IndexEntry> {
  final int shardIri;

  /// Direct reference to the index this entry belongs to.
  /// This is immutable - an entry never changes which index it belongs to.
  final int indexIriId;

  /// The resource IRI this entry points to (e.g., /notes/note-123#note)
  final int resourceIriId;

  /// The type IRI of the resource (e.g., schema:Note)
  final int resourceTypeIriId;

  /// Clock hash from the resource's CRDT metadata
  final String clockHash;

  /// application specific RDF payload in turtle format
  final String? headerProperties;

  /// When this entry was last updated (milliseconds since epoch)
  final int updatedAt;

  /// Physical clock for cursor-based pagination
  final int ourPhysicalClock;

  /// Tombstone marker - true if entry was removed from index
  final bool isDeleted;
  const IndexEntry(
      {required this.shardIri,
      required this.indexIriId,
      required this.resourceIriId,
      required this.resourceTypeIriId,
      required this.clockHash,
      this.headerProperties,
      required this.updatedAt,
      required this.ourPhysicalClock,
      required this.isDeleted});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['shard_iri'] = Variable<int>(shardIri);
    map['index_iri_id'] = Variable<int>(indexIriId);
    map['resource_iri_id'] = Variable<int>(resourceIriId);
    map['resource_type_iri_id'] = Variable<int>(resourceTypeIriId);
    map['clock_hash'] = Variable<String>(clockHash);
    if (!nullToAbsent || headerProperties != null) {
      map['header_properties'] = Variable<String>(headerProperties);
    }
    map['updated_at'] = Variable<int>(updatedAt);
    map['our_physical_clock'] = Variable<int>(ourPhysicalClock);
    map['is_deleted'] = Variable<bool>(isDeleted);
    return map;
  }

  IndexEntriesCompanion toCompanion(bool nullToAbsent) {
    return IndexEntriesCompanion(
      shardIri: Value(shardIri),
      indexIriId: Value(indexIriId),
      resourceIriId: Value(resourceIriId),
      resourceTypeIriId: Value(resourceTypeIriId),
      clockHash: Value(clockHash),
      headerProperties: headerProperties == null && nullToAbsent
          ? const Value.absent()
          : Value(headerProperties),
      updatedAt: Value(updatedAt),
      ourPhysicalClock: Value(ourPhysicalClock),
      isDeleted: Value(isDeleted),
    );
  }

  factory IndexEntry.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return IndexEntry(
      shardIri: serializer.fromJson<int>(json['shardIri']),
      indexIriId: serializer.fromJson<int>(json['indexIriId']),
      resourceIriId: serializer.fromJson<int>(json['resourceIriId']),
      resourceTypeIriId: serializer.fromJson<int>(json['resourceTypeIriId']),
      clockHash: serializer.fromJson<String>(json['clockHash']),
      headerProperties: serializer.fromJson<String?>(json['headerProperties']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
      ourPhysicalClock: serializer.fromJson<int>(json['ourPhysicalClock']),
      isDeleted: serializer.fromJson<bool>(json['isDeleted']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'shardIri': serializer.toJson<int>(shardIri),
      'indexIriId': serializer.toJson<int>(indexIriId),
      'resourceIriId': serializer.toJson<int>(resourceIriId),
      'resourceTypeIriId': serializer.toJson<int>(resourceTypeIriId),
      'clockHash': serializer.toJson<String>(clockHash),
      'headerProperties': serializer.toJson<String?>(headerProperties),
      'updatedAt': serializer.toJson<int>(updatedAt),
      'ourPhysicalClock': serializer.toJson<int>(ourPhysicalClock),
      'isDeleted': serializer.toJson<bool>(isDeleted),
    };
  }

  IndexEntry copyWith(
          {int? shardIri,
          int? indexIriId,
          int? resourceIriId,
          int? resourceTypeIriId,
          String? clockHash,
          Value<String?> headerProperties = const Value.absent(),
          int? updatedAt,
          int? ourPhysicalClock,
          bool? isDeleted}) =>
      IndexEntry(
        shardIri: shardIri ?? this.shardIri,
        indexIriId: indexIriId ?? this.indexIriId,
        resourceIriId: resourceIriId ?? this.resourceIriId,
        resourceTypeIriId: resourceTypeIriId ?? this.resourceTypeIriId,
        clockHash: clockHash ?? this.clockHash,
        headerProperties: headerProperties.present
            ? headerProperties.value
            : this.headerProperties,
        updatedAt: updatedAt ?? this.updatedAt,
        ourPhysicalClock: ourPhysicalClock ?? this.ourPhysicalClock,
        isDeleted: isDeleted ?? this.isDeleted,
      );
  IndexEntry copyWithCompanion(IndexEntriesCompanion data) {
    return IndexEntry(
      shardIri: data.shardIri.present ? data.shardIri.value : this.shardIri,
      indexIriId:
          data.indexIriId.present ? data.indexIriId.value : this.indexIriId,
      resourceIriId: data.resourceIriId.present
          ? data.resourceIriId.value
          : this.resourceIriId,
      resourceTypeIriId: data.resourceTypeIriId.present
          ? data.resourceTypeIriId.value
          : this.resourceTypeIriId,
      clockHash: data.clockHash.present ? data.clockHash.value : this.clockHash,
      headerProperties: data.headerProperties.present
          ? data.headerProperties.value
          : this.headerProperties,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      ourPhysicalClock: data.ourPhysicalClock.present
          ? data.ourPhysicalClock.value
          : this.ourPhysicalClock,
      isDeleted: data.isDeleted.present ? data.isDeleted.value : this.isDeleted,
    );
  }

  @override
  String toString() {
    return (StringBuffer('IndexEntry(')
          ..write('shardIri: $shardIri, ')
          ..write('indexIriId: $indexIriId, ')
          ..write('resourceIriId: $resourceIriId, ')
          ..write('resourceTypeIriId: $resourceTypeIriId, ')
          ..write('clockHash: $clockHash, ')
          ..write('headerProperties: $headerProperties, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('ourPhysicalClock: $ourPhysicalClock, ')
          ..write('isDeleted: $isDeleted')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      shardIri,
      indexIriId,
      resourceIriId,
      resourceTypeIriId,
      clockHash,
      headerProperties,
      updatedAt,
      ourPhysicalClock,
      isDeleted);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is IndexEntry &&
          other.shardIri == this.shardIri &&
          other.indexIriId == this.indexIriId &&
          other.resourceIriId == this.resourceIriId &&
          other.resourceTypeIriId == this.resourceTypeIriId &&
          other.clockHash == this.clockHash &&
          other.headerProperties == this.headerProperties &&
          other.updatedAt == this.updatedAt &&
          other.ourPhysicalClock == this.ourPhysicalClock &&
          other.isDeleted == this.isDeleted);
}

class IndexEntriesCompanion extends UpdateCompanion<IndexEntry> {
  final Value<int> shardIri;
  final Value<int> indexIriId;
  final Value<int> resourceIriId;
  final Value<int> resourceTypeIriId;
  final Value<String> clockHash;
  final Value<String?> headerProperties;
  final Value<int> updatedAt;
  final Value<int> ourPhysicalClock;
  final Value<bool> isDeleted;
  final Value<int> rowid;
  const IndexEntriesCompanion({
    this.shardIri = const Value.absent(),
    this.indexIriId = const Value.absent(),
    this.resourceIriId = const Value.absent(),
    this.resourceTypeIriId = const Value.absent(),
    this.clockHash = const Value.absent(),
    this.headerProperties = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.ourPhysicalClock = const Value.absent(),
    this.isDeleted = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  IndexEntriesCompanion.insert({
    required int shardIri,
    required int indexIriId,
    required int resourceIriId,
    required int resourceTypeIriId,
    required String clockHash,
    this.headerProperties = const Value.absent(),
    required int updatedAt,
    required int ourPhysicalClock,
    this.isDeleted = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : shardIri = Value(shardIri),
        indexIriId = Value(indexIriId),
        resourceIriId = Value(resourceIriId),
        resourceTypeIriId = Value(resourceTypeIriId),
        clockHash = Value(clockHash),
        updatedAt = Value(updatedAt),
        ourPhysicalClock = Value(ourPhysicalClock);
  static Insertable<IndexEntry> custom({
    Expression<int>? shardIri,
    Expression<int>? indexIriId,
    Expression<int>? resourceIriId,
    Expression<int>? resourceTypeIriId,
    Expression<String>? clockHash,
    Expression<String>? headerProperties,
    Expression<int>? updatedAt,
    Expression<int>? ourPhysicalClock,
    Expression<bool>? isDeleted,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (shardIri != null) 'shard_iri': shardIri,
      if (indexIriId != null) 'index_iri_id': indexIriId,
      if (resourceIriId != null) 'resource_iri_id': resourceIriId,
      if (resourceTypeIriId != null) 'resource_type_iri_id': resourceTypeIriId,
      if (clockHash != null) 'clock_hash': clockHash,
      if (headerProperties != null) 'header_properties': headerProperties,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (ourPhysicalClock != null) 'our_physical_clock': ourPhysicalClock,
      if (isDeleted != null) 'is_deleted': isDeleted,
      if (rowid != null) 'rowid': rowid,
    });
  }

  IndexEntriesCompanion copyWith(
      {Value<int>? shardIri,
      Value<int>? indexIriId,
      Value<int>? resourceIriId,
      Value<int>? resourceTypeIriId,
      Value<String>? clockHash,
      Value<String?>? headerProperties,
      Value<int>? updatedAt,
      Value<int>? ourPhysicalClock,
      Value<bool>? isDeleted,
      Value<int>? rowid}) {
    return IndexEntriesCompanion(
      shardIri: shardIri ?? this.shardIri,
      indexIriId: indexIriId ?? this.indexIriId,
      resourceIriId: resourceIriId ?? this.resourceIriId,
      resourceTypeIriId: resourceTypeIriId ?? this.resourceTypeIriId,
      clockHash: clockHash ?? this.clockHash,
      headerProperties: headerProperties ?? this.headerProperties,
      updatedAt: updatedAt ?? this.updatedAt,
      ourPhysicalClock: ourPhysicalClock ?? this.ourPhysicalClock,
      isDeleted: isDeleted ?? this.isDeleted,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (shardIri.present) {
      map['shard_iri'] = Variable<int>(shardIri.value);
    }
    if (indexIriId.present) {
      map['index_iri_id'] = Variable<int>(indexIriId.value);
    }
    if (resourceIriId.present) {
      map['resource_iri_id'] = Variable<int>(resourceIriId.value);
    }
    if (resourceTypeIriId.present) {
      map['resource_type_iri_id'] = Variable<int>(resourceTypeIriId.value);
    }
    if (clockHash.present) {
      map['clock_hash'] = Variable<String>(clockHash.value);
    }
    if (headerProperties.present) {
      map['header_properties'] = Variable<String>(headerProperties.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (ourPhysicalClock.present) {
      map['our_physical_clock'] = Variable<int>(ourPhysicalClock.value);
    }
    if (isDeleted.present) {
      map['is_deleted'] = Variable<bool>(isDeleted.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('IndexEntriesCompanion(')
          ..write('shardIri: $shardIri, ')
          ..write('indexIriId: $indexIriId, ')
          ..write('resourceIriId: $resourceIriId, ')
          ..write('resourceTypeIriId: $resourceTypeIriId, ')
          ..write('clockHash: $clockHash, ')
          ..write('headerProperties: $headerProperties, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('ourPhysicalClock: $ourPhysicalClock, ')
          ..write('isDeleted: $isDeleted, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $GroupIndexSubscriptionsTable extends GroupIndexSubscriptions
    with TableInfo<$GroupIndexSubscriptionsTable, GroupIndexSubscription> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $GroupIndexSubscriptionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _groupIndexIriIdMeta =
      const VerificationMeta('groupIndexIriId');
  @override
  late final GeneratedColumn<int> groupIndexIriId = GeneratedColumn<int>(
      'group_index_iri_id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('REFERENCES sync_iris (id)'));
  static const VerificationMeta _groupIndexTemplateIriIdMeta =
      const VerificationMeta('groupIndexTemplateIriId');
  @override
  late final GeneratedColumn<int> groupIndexTemplateIriId =
      GeneratedColumn<int>('group_index_template_iri_id', aliasedName, false,
          type: DriftSqlType.int,
          requiredDuringInsert: true,
          defaultConstraints:
              GeneratedColumn.constraintIsAlways('REFERENCES sync_iris (id)'));
  static const VerificationMeta _indexedTypeIriIdMeta =
      const VerificationMeta('indexedTypeIriId');
  @override
  late final GeneratedColumn<int> indexedTypeIriId = GeneratedColumn<int>(
      'indexed_type_iri_id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('REFERENCES sync_iris (id)'));
  static const VerificationMeta _itemFetchPolicyMeta =
      const VerificationMeta('itemFetchPolicy');
  @override
  late final GeneratedColumn<String> itemFetchPolicy = GeneratedColumn<String>(
      'item_fetch_policy', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
      'created_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [
        groupIndexIriId,
        groupIndexTemplateIriId,
        indexedTypeIriId,
        itemFetchPolicy,
        createdAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'group_index_subscriptions';
  @override
  VerificationContext validateIntegrity(
      Insertable<GroupIndexSubscription> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('group_index_iri_id')) {
      context.handle(
          _groupIndexIriIdMeta,
          groupIndexIriId.isAcceptableOrUnknown(
              data['group_index_iri_id']!, _groupIndexIriIdMeta));
    }
    if (data.containsKey('group_index_template_iri_id')) {
      context.handle(
          _groupIndexTemplateIriIdMeta,
          groupIndexTemplateIriId.isAcceptableOrUnknown(
              data['group_index_template_iri_id']!,
              _groupIndexTemplateIriIdMeta));
    } else if (isInserting) {
      context.missing(_groupIndexTemplateIriIdMeta);
    }
    if (data.containsKey('indexed_type_iri_id')) {
      context.handle(
          _indexedTypeIriIdMeta,
          indexedTypeIriId.isAcceptableOrUnknown(
              data['indexed_type_iri_id']!, _indexedTypeIriIdMeta));
    } else if (isInserting) {
      context.missing(_indexedTypeIriIdMeta);
    }
    if (data.containsKey('item_fetch_policy')) {
      context.handle(
          _itemFetchPolicyMeta,
          itemFetchPolicy.isAcceptableOrUnknown(
              data['item_fetch_policy']!, _itemFetchPolicyMeta));
    } else if (isInserting) {
      context.missing(_itemFetchPolicyMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {groupIndexIriId};
  @override
  GroupIndexSubscription map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return GroupIndexSubscription(
      groupIndexIriId: attachedDatabase.typeMapping.read(
          DriftSqlType.int, data['${effectivePrefix}group_index_iri_id'])!,
      groupIndexTemplateIriId: attachedDatabase.typeMapping.read(
          DriftSqlType.int,
          data['${effectivePrefix}group_index_template_iri_id'])!,
      indexedTypeIriId: attachedDatabase.typeMapping.read(
          DriftSqlType.int, data['${effectivePrefix}indexed_type_iri_id'])!,
      itemFetchPolicy: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}item_fetch_policy'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}created_at'])!,
    );
  }

  @override
  $GroupIndexSubscriptionsTable createAlias(String alias) {
    return $GroupIndexSubscriptionsTable(attachedDatabase, alias);
  }
}

class GroupIndexSubscription extends DataClass
    implements Insertable<GroupIndexSubscription> {
  final int groupIndexIriId;
  final int groupIndexTemplateIriId;

  /// The type IRI that this group index is indexing
  final int indexedTypeIriId;

  /// Fetch policy: 'onRequest' or 'prefetch'
  final String itemFetchPolicy;

  /// Timestamp when this subscription was created (milliseconds since epoch)
  final int createdAt;
  const GroupIndexSubscription(
      {required this.groupIndexIriId,
      required this.groupIndexTemplateIriId,
      required this.indexedTypeIriId,
      required this.itemFetchPolicy,
      required this.createdAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['group_index_iri_id'] = Variable<int>(groupIndexIriId);
    map['group_index_template_iri_id'] = Variable<int>(groupIndexTemplateIriId);
    map['indexed_type_iri_id'] = Variable<int>(indexedTypeIriId);
    map['item_fetch_policy'] = Variable<String>(itemFetchPolicy);
    map['created_at'] = Variable<int>(createdAt);
    return map;
  }

  GroupIndexSubscriptionsCompanion toCompanion(bool nullToAbsent) {
    return GroupIndexSubscriptionsCompanion(
      groupIndexIriId: Value(groupIndexIriId),
      groupIndexTemplateIriId: Value(groupIndexTemplateIriId),
      indexedTypeIriId: Value(indexedTypeIriId),
      itemFetchPolicy: Value(itemFetchPolicy),
      createdAt: Value(createdAt),
    );
  }

  factory GroupIndexSubscription.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return GroupIndexSubscription(
      groupIndexIriId: serializer.fromJson<int>(json['groupIndexIriId']),
      groupIndexTemplateIriId:
          serializer.fromJson<int>(json['groupIndexTemplateIriId']),
      indexedTypeIriId: serializer.fromJson<int>(json['indexedTypeIriId']),
      itemFetchPolicy: serializer.fromJson<String>(json['itemFetchPolicy']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'groupIndexIriId': serializer.toJson<int>(groupIndexIriId),
      'groupIndexTemplateIriId':
          serializer.toJson<int>(groupIndexTemplateIriId),
      'indexedTypeIriId': serializer.toJson<int>(indexedTypeIriId),
      'itemFetchPolicy': serializer.toJson<String>(itemFetchPolicy),
      'createdAt': serializer.toJson<int>(createdAt),
    };
  }

  GroupIndexSubscription copyWith(
          {int? groupIndexIriId,
          int? groupIndexTemplateIriId,
          int? indexedTypeIriId,
          String? itemFetchPolicy,
          int? createdAt}) =>
      GroupIndexSubscription(
        groupIndexIriId: groupIndexIriId ?? this.groupIndexIriId,
        groupIndexTemplateIriId:
            groupIndexTemplateIriId ?? this.groupIndexTemplateIriId,
        indexedTypeIriId: indexedTypeIriId ?? this.indexedTypeIriId,
        itemFetchPolicy: itemFetchPolicy ?? this.itemFetchPolicy,
        createdAt: createdAt ?? this.createdAt,
      );
  GroupIndexSubscription copyWithCompanion(
      GroupIndexSubscriptionsCompanion data) {
    return GroupIndexSubscription(
      groupIndexIriId: data.groupIndexIriId.present
          ? data.groupIndexIriId.value
          : this.groupIndexIriId,
      groupIndexTemplateIriId: data.groupIndexTemplateIriId.present
          ? data.groupIndexTemplateIriId.value
          : this.groupIndexTemplateIriId,
      indexedTypeIriId: data.indexedTypeIriId.present
          ? data.indexedTypeIriId.value
          : this.indexedTypeIriId,
      itemFetchPolicy: data.itemFetchPolicy.present
          ? data.itemFetchPolicy.value
          : this.itemFetchPolicy,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('GroupIndexSubscription(')
          ..write('groupIndexIriId: $groupIndexIriId, ')
          ..write('groupIndexTemplateIriId: $groupIndexTemplateIriId, ')
          ..write('indexedTypeIriId: $indexedTypeIriId, ')
          ..write('itemFetchPolicy: $itemFetchPolicy, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(groupIndexIriId, groupIndexTemplateIriId,
      indexedTypeIriId, itemFetchPolicy, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is GroupIndexSubscription &&
          other.groupIndexIriId == this.groupIndexIriId &&
          other.groupIndexTemplateIriId == this.groupIndexTemplateIriId &&
          other.indexedTypeIriId == this.indexedTypeIriId &&
          other.itemFetchPolicy == this.itemFetchPolicy &&
          other.createdAt == this.createdAt);
}

class GroupIndexSubscriptionsCompanion
    extends UpdateCompanion<GroupIndexSubscription> {
  final Value<int> groupIndexIriId;
  final Value<int> groupIndexTemplateIriId;
  final Value<int> indexedTypeIriId;
  final Value<String> itemFetchPolicy;
  final Value<int> createdAt;
  const GroupIndexSubscriptionsCompanion({
    this.groupIndexIriId = const Value.absent(),
    this.groupIndexTemplateIriId = const Value.absent(),
    this.indexedTypeIriId = const Value.absent(),
    this.itemFetchPolicy = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  GroupIndexSubscriptionsCompanion.insert({
    this.groupIndexIriId = const Value.absent(),
    required int groupIndexTemplateIriId,
    required int indexedTypeIriId,
    required String itemFetchPolicy,
    required int createdAt,
  })  : groupIndexTemplateIriId = Value(groupIndexTemplateIriId),
        indexedTypeIriId = Value(indexedTypeIriId),
        itemFetchPolicy = Value(itemFetchPolicy),
        createdAt = Value(createdAt);
  static Insertable<GroupIndexSubscription> custom({
    Expression<int>? groupIndexIriId,
    Expression<int>? groupIndexTemplateIriId,
    Expression<int>? indexedTypeIriId,
    Expression<String>? itemFetchPolicy,
    Expression<int>? createdAt,
  }) {
    return RawValuesInsertable({
      if (groupIndexIriId != null) 'group_index_iri_id': groupIndexIriId,
      if (groupIndexTemplateIriId != null)
        'group_index_template_iri_id': groupIndexTemplateIriId,
      if (indexedTypeIriId != null) 'indexed_type_iri_id': indexedTypeIriId,
      if (itemFetchPolicy != null) 'item_fetch_policy': itemFetchPolicy,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  GroupIndexSubscriptionsCompanion copyWith(
      {Value<int>? groupIndexIriId,
      Value<int>? groupIndexTemplateIriId,
      Value<int>? indexedTypeIriId,
      Value<String>? itemFetchPolicy,
      Value<int>? createdAt}) {
    return GroupIndexSubscriptionsCompanion(
      groupIndexIriId: groupIndexIriId ?? this.groupIndexIriId,
      groupIndexTemplateIriId:
          groupIndexTemplateIriId ?? this.groupIndexTemplateIriId,
      indexedTypeIriId: indexedTypeIriId ?? this.indexedTypeIriId,
      itemFetchPolicy: itemFetchPolicy ?? this.itemFetchPolicy,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (groupIndexIriId.present) {
      map['group_index_iri_id'] = Variable<int>(groupIndexIriId.value);
    }
    if (groupIndexTemplateIriId.present) {
      map['group_index_template_iri_id'] =
          Variable<int>(groupIndexTemplateIriId.value);
    }
    if (indexedTypeIriId.present) {
      map['indexed_type_iri_id'] = Variable<int>(indexedTypeIriId.value);
    }
    if (itemFetchPolicy.present) {
      map['item_fetch_policy'] = Variable<String>(itemFetchPolicy.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('GroupIndexSubscriptionsCompanion(')
          ..write('groupIndexIriId: $groupIndexIriId, ')
          ..write('groupIndexTemplateIriId: $groupIndexTemplateIriId, ')
          ..write('indexedTypeIriId: $indexedTypeIriId, ')
          ..write('itemFetchPolicy: $itemFetchPolicy, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

class $IndexIriIdSetVersionsTable extends IndexIriIdSetVersions
    with TableInfo<$IndexIriIdSetVersionsTable, IndexIriIdSetVersion> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $IndexIriIdSetVersionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _indexIriIdsMeta =
      const VerificationMeta('indexIriIds');
  @override
  late final GeneratedColumn<String> indexIriIds = GeneratedColumn<String>(
      'index_iri_ids', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
      'created_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [id, indexIriIds, createdAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'index_iri_id_set_versions';
  @override
  VerificationContext validateIntegrity(
      Insertable<IndexIriIdSetVersion> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('index_iri_ids')) {
      context.handle(
          _indexIriIdsMeta,
          indexIriIds.isAcceptableOrUnknown(
              data['index_iri_ids']!, _indexIriIdsMeta));
    } else if (isInserting) {
      context.missing(_indexIriIdsMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
        {indexIriIds},
      ];
  @override
  IndexIriIdSetVersion map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return IndexIriIdSetVersion(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      indexIriIds: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}index_iri_ids'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}created_at'])!,
    );
  }

  @override
  $IndexIriIdSetVersionsTable createAlias(String alias) {
    return $IndexIriIdSetVersionsTable(attachedDatabase, alias);
  }
}

class IndexIriIdSetVersion extends DataClass
    implements Insertable<IndexIriIdSetVersion> {
  final int id;

  /// Comma-separated, sorted list of index IRI IDs (e.g., "5,7,9")
  /// Always sorted ascending to ensure consistent hashing
  final String indexIriIds;

  /// When this version was created (milliseconds since epoch)
  final int createdAt;
  const IndexIriIdSetVersion(
      {required this.id, required this.indexIriIds, required this.createdAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['index_iri_ids'] = Variable<String>(indexIriIds);
    map['created_at'] = Variable<int>(createdAt);
    return map;
  }

  IndexIriIdSetVersionsCompanion toCompanion(bool nullToAbsent) {
    return IndexIriIdSetVersionsCompanion(
      id: Value(id),
      indexIriIds: Value(indexIriIds),
      createdAt: Value(createdAt),
    );
  }

  factory IndexIriIdSetVersion.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return IndexIriIdSetVersion(
      id: serializer.fromJson<int>(json['id']),
      indexIriIds: serializer.fromJson<String>(json['indexIriIds']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'indexIriIds': serializer.toJson<String>(indexIriIds),
      'createdAt': serializer.toJson<int>(createdAt),
    };
  }

  IndexIriIdSetVersion copyWith(
          {int? id, String? indexIriIds, int? createdAt}) =>
      IndexIriIdSetVersion(
        id: id ?? this.id,
        indexIriIds: indexIriIds ?? this.indexIriIds,
        createdAt: createdAt ?? this.createdAt,
      );
  IndexIriIdSetVersion copyWithCompanion(IndexIriIdSetVersionsCompanion data) {
    return IndexIriIdSetVersion(
      id: data.id.present ? data.id.value : this.id,
      indexIriIds:
          data.indexIriIds.present ? data.indexIriIds.value : this.indexIriIds,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('IndexIriIdSetVersion(')
          ..write('id: $id, ')
          ..write('indexIriIds: $indexIriIds, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, indexIriIds, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is IndexIriIdSetVersion &&
          other.id == this.id &&
          other.indexIriIds == this.indexIriIds &&
          other.createdAt == this.createdAt);
}

class IndexIriIdSetVersionsCompanion
    extends UpdateCompanion<IndexIriIdSetVersion> {
  final Value<int> id;
  final Value<String> indexIriIds;
  final Value<int> createdAt;
  const IndexIriIdSetVersionsCompanion({
    this.id = const Value.absent(),
    this.indexIriIds = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  IndexIriIdSetVersionsCompanion.insert({
    this.id = const Value.absent(),
    required String indexIriIds,
    required int createdAt,
  })  : indexIriIds = Value(indexIriIds),
        createdAt = Value(createdAt);
  static Insertable<IndexIriIdSetVersion> custom({
    Expression<int>? id,
    Expression<String>? indexIriIds,
    Expression<int>? createdAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (indexIriIds != null) 'index_iri_ids': indexIriIds,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  IndexIriIdSetVersionsCompanion copyWith(
      {Value<int>? id, Value<String>? indexIriIds, Value<int>? createdAt}) {
    return IndexIriIdSetVersionsCompanion(
      id: id ?? this.id,
      indexIriIds: indexIriIds ?? this.indexIriIds,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (indexIriIds.present) {
      map['index_iri_ids'] = Variable<String>(indexIriIds.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('IndexIriIdSetVersionsCompanion(')
          ..write('id: $id, ')
          ..write('indexIriIds: $indexIriIds, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

class $RemoteSettingsTable extends RemoteSettings
    with TableInfo<$RemoteSettingsTable, RemoteSetting> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RemoteSettingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _remoteIdMeta =
      const VerificationMeta('remoteId');
  @override
  late final GeneratedColumn<String> remoteId = GeneratedColumn<String>(
      'remote_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _remoteTypeMeta =
      const VerificationMeta('remoteType');
  @override
  late final GeneratedColumn<String> remoteType = GeneratedColumn<String>(
      'remote_type', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _lastSyncTimestampMeta =
      const VerificationMeta('lastSyncTimestamp');
  @override
  late final GeneratedColumn<int> lastSyncTimestamp = GeneratedColumn<int>(
      'last_sync_timestamp', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
      'created_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [id, remoteId, remoteType, lastSyncTimestamp, createdAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'remote_settings';
  @override
  VerificationContext validateIntegrity(Insertable<RemoteSetting> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('remote_id')) {
      context.handle(_remoteIdMeta,
          remoteId.isAcceptableOrUnknown(data['remote_id']!, _remoteIdMeta));
    } else if (isInserting) {
      context.missing(_remoteIdMeta);
    }
    if (data.containsKey('remote_type')) {
      context.handle(
          _remoteTypeMeta,
          remoteType.isAcceptableOrUnknown(
              data['remote_type']!, _remoteTypeMeta));
    } else if (isInserting) {
      context.missing(_remoteTypeMeta);
    }
    if (data.containsKey('last_sync_timestamp')) {
      context.handle(
          _lastSyncTimestampMeta,
          lastSyncTimestamp.isAcceptableOrUnknown(
              data['last_sync_timestamp']!, _lastSyncTimestampMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
        {remoteType, remoteId},
      ];
  @override
  RemoteSetting map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RemoteSetting(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      remoteId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}remote_id'])!,
      remoteType: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}remote_type'])!,
      lastSyncTimestamp: attachedDatabase.typeMapping.read(
          DriftSqlType.int, data['${effectivePrefix}last_sync_timestamp'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}created_at'])!,
    );
  }

  @override
  $RemoteSettingsTable createAlias(String alias) {
    return $RemoteSettingsTable(attachedDatabase, alias);
  }
}

class RemoteSetting extends DataClass implements Insertable<RemoteSetting> {
  /// Auto-incrementing primary key
  final int id;

  /// Remote ID (e.g., 'https://alice.pod.example/')
  /// Combined with remoteType must be unique per backend.
  final String remoteId;

  /// Type of remote (e.g., 'solid-pod', 'generic-http')
  /// Allows future extensibility for different remote types
  final String remoteType;

  /// Timestamp of last successful sync with this remote (milliseconds since epoch)
  /// Used for tracking overall remote sync progress
  final int lastSyncTimestamp;

  /// When this remote was first configured (milliseconds since epoch)
  final int createdAt;
  const RemoteSetting(
      {required this.id,
      required this.remoteId,
      required this.remoteType,
      required this.lastSyncTimestamp,
      required this.createdAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['remote_id'] = Variable<String>(remoteId);
    map['remote_type'] = Variable<String>(remoteType);
    map['last_sync_timestamp'] = Variable<int>(lastSyncTimestamp);
    map['created_at'] = Variable<int>(createdAt);
    return map;
  }

  RemoteSettingsCompanion toCompanion(bool nullToAbsent) {
    return RemoteSettingsCompanion(
      id: Value(id),
      remoteId: Value(remoteId),
      remoteType: Value(remoteType),
      lastSyncTimestamp: Value(lastSyncTimestamp),
      createdAt: Value(createdAt),
    );
  }

  factory RemoteSetting.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RemoteSetting(
      id: serializer.fromJson<int>(json['id']),
      remoteId: serializer.fromJson<String>(json['remoteId']),
      remoteType: serializer.fromJson<String>(json['remoteType']),
      lastSyncTimestamp: serializer.fromJson<int>(json['lastSyncTimestamp']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'remoteId': serializer.toJson<String>(remoteId),
      'remoteType': serializer.toJson<String>(remoteType),
      'lastSyncTimestamp': serializer.toJson<int>(lastSyncTimestamp),
      'createdAt': serializer.toJson<int>(createdAt),
    };
  }

  RemoteSetting copyWith(
          {int? id,
          String? remoteId,
          String? remoteType,
          int? lastSyncTimestamp,
          int? createdAt}) =>
      RemoteSetting(
        id: id ?? this.id,
        remoteId: remoteId ?? this.remoteId,
        remoteType: remoteType ?? this.remoteType,
        lastSyncTimestamp: lastSyncTimestamp ?? this.lastSyncTimestamp,
        createdAt: createdAt ?? this.createdAt,
      );
  RemoteSetting copyWithCompanion(RemoteSettingsCompanion data) {
    return RemoteSetting(
      id: data.id.present ? data.id.value : this.id,
      remoteId: data.remoteId.present ? data.remoteId.value : this.remoteId,
      remoteType:
          data.remoteType.present ? data.remoteType.value : this.remoteType,
      lastSyncTimestamp: data.lastSyncTimestamp.present
          ? data.lastSyncTimestamp.value
          : this.lastSyncTimestamp,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RemoteSetting(')
          ..write('id: $id, ')
          ..write('remoteId: $remoteId, ')
          ..write('remoteType: $remoteType, ')
          ..write('lastSyncTimestamp: $lastSyncTimestamp, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, remoteId, remoteType, lastSyncTimestamp, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RemoteSetting &&
          other.id == this.id &&
          other.remoteId == this.remoteId &&
          other.remoteType == this.remoteType &&
          other.lastSyncTimestamp == this.lastSyncTimestamp &&
          other.createdAt == this.createdAt);
}

class RemoteSettingsCompanion extends UpdateCompanion<RemoteSetting> {
  final Value<int> id;
  final Value<String> remoteId;
  final Value<String> remoteType;
  final Value<int> lastSyncTimestamp;
  final Value<int> createdAt;
  const RemoteSettingsCompanion({
    this.id = const Value.absent(),
    this.remoteId = const Value.absent(),
    this.remoteType = const Value.absent(),
    this.lastSyncTimestamp = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  RemoteSettingsCompanion.insert({
    this.id = const Value.absent(),
    required String remoteId,
    required String remoteType,
    this.lastSyncTimestamp = const Value.absent(),
    required int createdAt,
  })  : remoteId = Value(remoteId),
        remoteType = Value(remoteType),
        createdAt = Value(createdAt);
  static Insertable<RemoteSetting> custom({
    Expression<int>? id,
    Expression<String>? remoteId,
    Expression<String>? remoteType,
    Expression<int>? lastSyncTimestamp,
    Expression<int>? createdAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (remoteId != null) 'remote_id': remoteId,
      if (remoteType != null) 'remote_type': remoteType,
      if (lastSyncTimestamp != null) 'last_sync_timestamp': lastSyncTimestamp,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  RemoteSettingsCompanion copyWith(
      {Value<int>? id,
      Value<String>? remoteId,
      Value<String>? remoteType,
      Value<int>? lastSyncTimestamp,
      Value<int>? createdAt}) {
    return RemoteSettingsCompanion(
      id: id ?? this.id,
      remoteId: remoteId ?? this.remoteId,
      remoteType: remoteType ?? this.remoteType,
      lastSyncTimestamp: lastSyncTimestamp ?? this.lastSyncTimestamp,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (remoteId.present) {
      map['remote_id'] = Variable<String>(remoteId.value);
    }
    if (remoteType.present) {
      map['remote_type'] = Variable<String>(remoteType.value);
    }
    if (lastSyncTimestamp.present) {
      map['last_sync_timestamp'] = Variable<int>(lastSyncTimestamp.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RemoteSettingsCompanion(')
          ..write('id: $id, ')
          ..write('remoteId: $remoteId, ')
          ..write('remoteType: $remoteType, ')
          ..write('lastSyncTimestamp: $lastSyncTimestamp, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

class $RemoteSyncStateTable extends RemoteSyncState
    with TableInfo<$RemoteSyncStateTable, RemoteSyncStateData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RemoteSyncStateTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _documentIriIdMeta =
      const VerificationMeta('documentIriId');
  @override
  late final GeneratedColumn<int> documentIriId = GeneratedColumn<int>(
      'document_iri_id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('REFERENCES sync_iris (id)'));
  static const VerificationMeta _remoteIdMeta =
      const VerificationMeta('remoteId');
  @override
  late final GeneratedColumn<int> remoteId = GeneratedColumn<int>(
      'remote_id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'REFERENCES remote_settings (id)'));
  static const VerificationMeta _etagMeta = const VerificationMeta('etag');
  @override
  late final GeneratedColumn<String> etag = GeneratedColumn<String>(
      'etag', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _lastSyncedAtMeta =
      const VerificationMeta('lastSyncedAt');
  @override
  late final GeneratedColumn<int> lastSyncedAt = GeneratedColumn<int>(
      'last_synced_at', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  @override
  List<GeneratedColumn> get $columns =>
      [documentIriId, remoteId, etag, lastSyncedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'remote_sync_state';
  @override
  VerificationContext validateIntegrity(
      Insertable<RemoteSyncStateData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('document_iri_id')) {
      context.handle(
          _documentIriIdMeta,
          documentIriId.isAcceptableOrUnknown(
              data['document_iri_id']!, _documentIriIdMeta));
    } else if (isInserting) {
      context.missing(_documentIriIdMeta);
    }
    if (data.containsKey('remote_id')) {
      context.handle(_remoteIdMeta,
          remoteId.isAcceptableOrUnknown(data['remote_id']!, _remoteIdMeta));
    } else if (isInserting) {
      context.missing(_remoteIdMeta);
    }
    if (data.containsKey('etag')) {
      context.handle(
          _etagMeta, etag.isAcceptableOrUnknown(data['etag']!, _etagMeta));
    }
    if (data.containsKey('last_synced_at')) {
      context.handle(
          _lastSyncedAtMeta,
          lastSyncedAt.isAcceptableOrUnknown(
              data['last_synced_at']!, _lastSyncedAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {documentIriId, remoteId};
  @override
  RemoteSyncStateData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RemoteSyncStateData(
      documentIriId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}document_iri_id'])!,
      remoteId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}remote_id'])!,
      etag: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}etag']),
      lastSyncedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}last_synced_at'])!,
    );
  }

  @override
  $RemoteSyncStateTable createAlias(String alias) {
    return $RemoteSyncStateTable(attachedDatabase, alias);
  }
}

class RemoteSyncStateData extends DataClass
    implements Insertable<RemoteSyncStateData> {
  /// Foreign key to SyncIris table for the document IRI
  final int documentIriId;

  /// Foreign key to RemoteSettings for efficient storage
  /// Normalized reference instead of repeating URLs
  final int remoteId;

  /// ETag from last GET/PUT for conditional requests
  /// NULL if never synced or ETag not supported by remote
  final String? etag;

  /// Timestamp of last successful sync (milliseconds since epoch)
  /// Used for tracking when document was last synced with this remote
  final int lastSyncedAt;
  const RemoteSyncStateData(
      {required this.documentIriId,
      required this.remoteId,
      this.etag,
      required this.lastSyncedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['document_iri_id'] = Variable<int>(documentIriId);
    map['remote_id'] = Variable<int>(remoteId);
    if (!nullToAbsent || etag != null) {
      map['etag'] = Variable<String>(etag);
    }
    map['last_synced_at'] = Variable<int>(lastSyncedAt);
    return map;
  }

  RemoteSyncStateCompanion toCompanion(bool nullToAbsent) {
    return RemoteSyncStateCompanion(
      documentIriId: Value(documentIriId),
      remoteId: Value(remoteId),
      etag: etag == null && nullToAbsent ? const Value.absent() : Value(etag),
      lastSyncedAt: Value(lastSyncedAt),
    );
  }

  factory RemoteSyncStateData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RemoteSyncStateData(
      documentIriId: serializer.fromJson<int>(json['documentIriId']),
      remoteId: serializer.fromJson<int>(json['remoteId']),
      etag: serializer.fromJson<String?>(json['etag']),
      lastSyncedAt: serializer.fromJson<int>(json['lastSyncedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'documentIriId': serializer.toJson<int>(documentIriId),
      'remoteId': serializer.toJson<int>(remoteId),
      'etag': serializer.toJson<String?>(etag),
      'lastSyncedAt': serializer.toJson<int>(lastSyncedAt),
    };
  }

  RemoteSyncStateData copyWith(
          {int? documentIriId,
          int? remoteId,
          Value<String?> etag = const Value.absent(),
          int? lastSyncedAt}) =>
      RemoteSyncStateData(
        documentIriId: documentIriId ?? this.documentIriId,
        remoteId: remoteId ?? this.remoteId,
        etag: etag.present ? etag.value : this.etag,
        lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      );
  RemoteSyncStateData copyWithCompanion(RemoteSyncStateCompanion data) {
    return RemoteSyncStateData(
      documentIriId: data.documentIriId.present
          ? data.documentIriId.value
          : this.documentIriId,
      remoteId: data.remoteId.present ? data.remoteId.value : this.remoteId,
      etag: data.etag.present ? data.etag.value : this.etag,
      lastSyncedAt: data.lastSyncedAt.present
          ? data.lastSyncedAt.value
          : this.lastSyncedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RemoteSyncStateData(')
          ..write('documentIriId: $documentIriId, ')
          ..write('remoteId: $remoteId, ')
          ..write('etag: $etag, ')
          ..write('lastSyncedAt: $lastSyncedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(documentIriId, remoteId, etag, lastSyncedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RemoteSyncStateData &&
          other.documentIriId == this.documentIriId &&
          other.remoteId == this.remoteId &&
          other.etag == this.etag &&
          other.lastSyncedAt == this.lastSyncedAt);
}

class RemoteSyncStateCompanion extends UpdateCompanion<RemoteSyncStateData> {
  final Value<int> documentIriId;
  final Value<int> remoteId;
  final Value<String?> etag;
  final Value<int> lastSyncedAt;
  final Value<int> rowid;
  const RemoteSyncStateCompanion({
    this.documentIriId = const Value.absent(),
    this.remoteId = const Value.absent(),
    this.etag = const Value.absent(),
    this.lastSyncedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  RemoteSyncStateCompanion.insert({
    required int documentIriId,
    required int remoteId,
    this.etag = const Value.absent(),
    this.lastSyncedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : documentIriId = Value(documentIriId),
        remoteId = Value(remoteId);
  static Insertable<RemoteSyncStateData> custom({
    Expression<int>? documentIriId,
    Expression<int>? remoteId,
    Expression<String>? etag,
    Expression<int>? lastSyncedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (documentIriId != null) 'document_iri_id': documentIriId,
      if (remoteId != null) 'remote_id': remoteId,
      if (etag != null) 'etag': etag,
      if (lastSyncedAt != null) 'last_synced_at': lastSyncedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  RemoteSyncStateCompanion copyWith(
      {Value<int>? documentIriId,
      Value<int>? remoteId,
      Value<String?>? etag,
      Value<int>? lastSyncedAt,
      Value<int>? rowid}) {
    return RemoteSyncStateCompanion(
      documentIriId: documentIriId ?? this.documentIriId,
      remoteId: remoteId ?? this.remoteId,
      etag: etag ?? this.etag,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (documentIriId.present) {
      map['document_iri_id'] = Variable<int>(documentIriId.value);
    }
    if (remoteId.present) {
      map['remote_id'] = Variable<int>(remoteId.value);
    }
    if (etag.present) {
      map['etag'] = Variable<String>(etag.value);
    }
    if (lastSyncedAt.present) {
      map['last_synced_at'] = Variable<int>(lastSyncedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RemoteSyncStateCompanion(')
          ..write('documentIriId: $documentIriId, ')
          ..write('remoteId: $remoteId, ')
          ..write('etag: $etag, ')
          ..write('lastSyncedAt: $lastSyncedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$SyncDatabase extends GeneratedDatabase {
  _$SyncDatabase(QueryExecutor e) : super(e);
  $SyncDatabaseManager get managers => $SyncDatabaseManager(this);
  late final $SyncIrisTable syncIris = $SyncIrisTable(this);
  late final $SyncDocumentsTable syncDocuments = $SyncDocumentsTable(this);
  late final $SyncPropertyChangesTable syncPropertyChanges =
      $SyncPropertyChangesTable(this);
  late final $SyncSettingsTable syncSettings = $SyncSettingsTable(this);
  late final $IndexEntriesTable indexEntries = $IndexEntriesTable(this);
  late final $GroupIndexSubscriptionsTable groupIndexSubscriptions =
      $GroupIndexSubscriptionsTable(this);
  late final $IndexIriIdSetVersionsTable indexIriIdSetVersions =
      $IndexIriIdSetVersionsTable(this);
  late final $RemoteSettingsTable remoteSettings = $RemoteSettingsTable(this);
  late final $RemoteSyncStateTable remoteSyncState =
      $RemoteSyncStateTable(this);
  late final SyncDocumentDao syncDocumentDao =
      SyncDocumentDao(this as SyncDatabase);
  late final SyncPropertyChangeDao syncPropertyChangeDao =
      SyncPropertyChangeDao(this as SyncDatabase);
  late final IndexDao indexDao = IndexDao(this as SyncDatabase);
  late final RemoteSyncStateDao remoteSyncStateDao =
      RemoteSyncStateDao(this as SyncDatabase);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
        syncIris,
        syncDocuments,
        syncPropertyChanges,
        syncSettings,
        indexEntries,
        groupIndexSubscriptions,
        indexIriIdSetVersions,
        remoteSettings,
        remoteSyncState
      ];
}

typedef $$SyncIrisTableCreateCompanionBuilder = SyncIrisCompanion Function({
  Value<int> id,
  required String iri,
});
typedef $$SyncIrisTableUpdateCompanionBuilder = SyncIrisCompanion Function({
  Value<int> id,
  Value<String> iri,
});

final class $$SyncIrisTableReferences
    extends BaseReferences<_$SyncDatabase, $SyncIrisTable, SyncIri> {
  $$SyncIrisTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$SyncDocumentsTable, List<SyncDocument>>
      _syncDocumentsRefsTable(_$SyncDatabase db) =>
          MultiTypedResultKey.fromTable(db.syncDocuments,
              aliasName: $_aliasNameGenerator(
                  db.syncIris.id, db.syncDocuments.documentIriId));

  $$SyncDocumentsTableProcessedTableManager get syncDocumentsRefs {
    final manager = $$SyncDocumentsTableTableManager($_db, $_db.syncDocuments)
        .filter((f) => f.documentIriId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_syncDocumentsRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }

  static MultiTypedResultKey<$SyncDocumentsTable, List<SyncDocument>>
      _typeIriTable(_$SyncDatabase db) => MultiTypedResultKey.fromTable(
          db.syncDocuments,
          aliasName:
              $_aliasNameGenerator(db.syncIris.id, db.syncDocuments.typeIriId));

  $$SyncDocumentsTableProcessedTableManager get typeIri {
    final manager = $$SyncDocumentsTableTableManager($_db, $_db.syncDocuments)
        .filter((f) => f.typeIriId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_typeIriTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }

  static MultiTypedResultKey<$SyncPropertyChangesTable,
      List<SyncPropertyChange>> _resourceIriTable(
          _$SyncDatabase db) =>
      MultiTypedResultKey.fromTable(db.syncPropertyChanges,
          aliasName: $_aliasNameGenerator(
              db.syncIris.id, db.syncPropertyChanges.resourceIriId));

  $$SyncPropertyChangesTableProcessedTableManager get resourceIri {
    final manager = $$SyncPropertyChangesTableTableManager(
            $_db, $_db.syncPropertyChanges)
        .filter((f) => f.resourceIriId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_resourceIriTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }

  static MultiTypedResultKey<$SyncPropertyChangesTable,
      List<SyncPropertyChange>> _propertyIriTable(
          _$SyncDatabase db) =>
      MultiTypedResultKey.fromTable(db.syncPropertyChanges,
          aliasName: $_aliasNameGenerator(
              db.syncIris.id, db.syncPropertyChanges.propertyIriId));

  $$SyncPropertyChangesTableProcessedTableManager get propertyIri {
    final manager = $$SyncPropertyChangesTableTableManager(
            $_db, $_db.syncPropertyChanges)
        .filter((f) => f.propertyIriId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_propertyIriTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }

  static MultiTypedResultKey<$IndexEntriesTable, List<IndexEntry>>
      _shardIriTable(_$SyncDatabase db) => MultiTypedResultKey.fromTable(
          db.indexEntries,
          aliasName:
              $_aliasNameGenerator(db.syncIris.id, db.indexEntries.shardIri));

  $$IndexEntriesTableProcessedTableManager get shardIri {
    final manager = $$IndexEntriesTableTableManager($_db, $_db.indexEntries)
        .filter((f) => f.shardIri.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_shardIriTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }

  static MultiTypedResultKey<$IndexEntriesTable, List<IndexEntry>>
      _indexIriTable(_$SyncDatabase db) => MultiTypedResultKey.fromTable(
          db.indexEntries,
          aliasName:
              $_aliasNameGenerator(db.syncIris.id, db.indexEntries.indexIriId));

  $$IndexEntriesTableProcessedTableManager get indexIri {
    final manager = $$IndexEntriesTableTableManager($_db, $_db.indexEntries)
        .filter((f) => f.indexIriId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_indexIriTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }

  static MultiTypedResultKey<$IndexEntriesTable, List<IndexEntry>>
      _indexResourceIriTable(_$SyncDatabase db) =>
          MultiTypedResultKey.fromTable(db.indexEntries,
              aliasName: $_aliasNameGenerator(
                  db.syncIris.id, db.indexEntries.resourceIriId));

  $$IndexEntriesTableProcessedTableManager get indexResourceIri {
    final manager = $$IndexEntriesTableTableManager($_db, $_db.indexEntries)
        .filter((f) => f.resourceIriId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_indexResourceIriTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }

  static MultiTypedResultKey<$IndexEntriesTable, List<IndexEntry>>
      _resourceTypeIriTable(_$SyncDatabase db) =>
          MultiTypedResultKey.fromTable(db.indexEntries,
              aliasName: $_aliasNameGenerator(
                  db.syncIris.id, db.indexEntries.resourceTypeIriId));

  $$IndexEntriesTableProcessedTableManager get resourceTypeIri {
    final manager = $$IndexEntriesTableTableManager($_db, $_db.indexEntries)
        .filter(
            (f) => f.resourceTypeIriId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_resourceTypeIriTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }

  static MultiTypedResultKey<$GroupIndexSubscriptionsTable,
      List<GroupIndexSubscription>> _groupIndexSubscriptionsRefsTable(
          _$SyncDatabase db) =>
      MultiTypedResultKey.fromTable(db.groupIndexSubscriptions,
          aliasName: $_aliasNameGenerator(
              db.syncIris.id, db.groupIndexSubscriptions.groupIndexIriId));

  $$GroupIndexSubscriptionsTableProcessedTableManager
      get groupIndexSubscriptionsRefs {
    final manager = $$GroupIndexSubscriptionsTableTableManager(
            $_db, $_db.groupIndexSubscriptions)
        .filter(
            (f) => f.groupIndexIriId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache =
        $_typedResult.readTableOrNull(_groupIndexSubscriptionsRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }

  static MultiTypedResultKey<$GroupIndexSubscriptionsTable,
      List<GroupIndexSubscription>> _groupIndexTemplateIriIdTable(
          _$SyncDatabase db) =>
      MultiTypedResultKey.fromTable(db.groupIndexSubscriptions,
          aliasName: $_aliasNameGenerator(db.syncIris.id,
              db.groupIndexSubscriptions.groupIndexTemplateIriId));

  $$GroupIndexSubscriptionsTableProcessedTableManager
      get groupIndexTemplateIriId {
    final manager = $$GroupIndexSubscriptionsTableTableManager(
            $_db, $_db.groupIndexSubscriptions)
        .filter((f) =>
            f.groupIndexTemplateIriId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache =
        $_typedResult.readTableOrNull(_groupIndexTemplateIriIdTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }

  static MultiTypedResultKey<$GroupIndexSubscriptionsTable,
      List<GroupIndexSubscription>> _indexedTypeIriIdTable(
          _$SyncDatabase db) =>
      MultiTypedResultKey.fromTable(db.groupIndexSubscriptions,
          aliasName: $_aliasNameGenerator(
              db.syncIris.id, db.groupIndexSubscriptions.indexedTypeIriId));

  $$GroupIndexSubscriptionsTableProcessedTableManager get indexedTypeIriId {
    final manager = $$GroupIndexSubscriptionsTableTableManager(
            $_db, $_db.groupIndexSubscriptions)
        .filter(
            (f) => f.indexedTypeIriId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_indexedTypeIriIdTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }

  static MultiTypedResultKey<$RemoteSyncStateTable, List<RemoteSyncStateData>>
      _remoteSyncStateRefsTable(_$SyncDatabase db) =>
          MultiTypedResultKey.fromTable(db.remoteSyncState,
              aliasName: $_aliasNameGenerator(
                  db.syncIris.id, db.remoteSyncState.documentIriId));

  $$RemoteSyncStateTableProcessedTableManager get remoteSyncStateRefs {
    final manager = $$RemoteSyncStateTableTableManager(
            $_db, $_db.remoteSyncState)
        .filter((f) => f.documentIriId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache =
        $_typedResult.readTableOrNull(_remoteSyncStateRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }
}

class $$SyncIrisTableFilterComposer
    extends Composer<_$SyncDatabase, $SyncIrisTable> {
  $$SyncIrisTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get iri => $composableBuilder(
      column: $table.iri, builder: (column) => ColumnFilters(column));

  Expression<bool> syncDocumentsRefs(
      Expression<bool> Function($$SyncDocumentsTableFilterComposer f) f) {
    final $$SyncDocumentsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.syncDocuments,
        getReferencedColumn: (t) => t.documentIriId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncDocumentsTableFilterComposer(
              $db: $db,
              $table: $db.syncDocuments,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<bool> typeIri(
      Expression<bool> Function($$SyncDocumentsTableFilterComposer f) f) {
    final $$SyncDocumentsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.syncDocuments,
        getReferencedColumn: (t) => t.typeIriId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncDocumentsTableFilterComposer(
              $db: $db,
              $table: $db.syncDocuments,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<bool> resourceIri(
      Expression<bool> Function($$SyncPropertyChangesTableFilterComposer f) f) {
    final $$SyncPropertyChangesTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.syncPropertyChanges,
        getReferencedColumn: (t) => t.resourceIriId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncPropertyChangesTableFilterComposer(
              $db: $db,
              $table: $db.syncPropertyChanges,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<bool> propertyIri(
      Expression<bool> Function($$SyncPropertyChangesTableFilterComposer f) f) {
    final $$SyncPropertyChangesTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.syncPropertyChanges,
        getReferencedColumn: (t) => t.propertyIriId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncPropertyChangesTableFilterComposer(
              $db: $db,
              $table: $db.syncPropertyChanges,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<bool> shardIri(
      Expression<bool> Function($$IndexEntriesTableFilterComposer f) f) {
    final $$IndexEntriesTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.indexEntries,
        getReferencedColumn: (t) => t.shardIri,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$IndexEntriesTableFilterComposer(
              $db: $db,
              $table: $db.indexEntries,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<bool> indexIri(
      Expression<bool> Function($$IndexEntriesTableFilterComposer f) f) {
    final $$IndexEntriesTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.indexEntries,
        getReferencedColumn: (t) => t.indexIriId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$IndexEntriesTableFilterComposer(
              $db: $db,
              $table: $db.indexEntries,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<bool> indexResourceIri(
      Expression<bool> Function($$IndexEntriesTableFilterComposer f) f) {
    final $$IndexEntriesTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.indexEntries,
        getReferencedColumn: (t) => t.resourceIriId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$IndexEntriesTableFilterComposer(
              $db: $db,
              $table: $db.indexEntries,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<bool> resourceTypeIri(
      Expression<bool> Function($$IndexEntriesTableFilterComposer f) f) {
    final $$IndexEntriesTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.indexEntries,
        getReferencedColumn: (t) => t.resourceTypeIriId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$IndexEntriesTableFilterComposer(
              $db: $db,
              $table: $db.indexEntries,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<bool> groupIndexSubscriptionsRefs(
      Expression<bool> Function($$GroupIndexSubscriptionsTableFilterComposer f)
          f) {
    final $$GroupIndexSubscriptionsTableFilterComposer composer =
        $composerBuilder(
            composer: this,
            getCurrentColumn: (t) => t.id,
            referencedTable: $db.groupIndexSubscriptions,
            getReferencedColumn: (t) => t.groupIndexIriId,
            builder: (joinBuilder,
                    {$addJoinBuilderToRootComposer,
                    $removeJoinBuilderFromRootComposer}) =>
                $$GroupIndexSubscriptionsTableFilterComposer(
                  $db: $db,
                  $table: $db.groupIndexSubscriptions,
                  $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                  joinBuilder: joinBuilder,
                  $removeJoinBuilderFromRootComposer:
                      $removeJoinBuilderFromRootComposer,
                ));
    return f(composer);
  }

  Expression<bool> groupIndexTemplateIriId(
      Expression<bool> Function($$GroupIndexSubscriptionsTableFilterComposer f)
          f) {
    final $$GroupIndexSubscriptionsTableFilterComposer composer =
        $composerBuilder(
            composer: this,
            getCurrentColumn: (t) => t.id,
            referencedTable: $db.groupIndexSubscriptions,
            getReferencedColumn: (t) => t.groupIndexTemplateIriId,
            builder: (joinBuilder,
                    {$addJoinBuilderToRootComposer,
                    $removeJoinBuilderFromRootComposer}) =>
                $$GroupIndexSubscriptionsTableFilterComposer(
                  $db: $db,
                  $table: $db.groupIndexSubscriptions,
                  $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                  joinBuilder: joinBuilder,
                  $removeJoinBuilderFromRootComposer:
                      $removeJoinBuilderFromRootComposer,
                ));
    return f(composer);
  }

  Expression<bool> indexedTypeIriId(
      Expression<bool> Function($$GroupIndexSubscriptionsTableFilterComposer f)
          f) {
    final $$GroupIndexSubscriptionsTableFilterComposer composer =
        $composerBuilder(
            composer: this,
            getCurrentColumn: (t) => t.id,
            referencedTable: $db.groupIndexSubscriptions,
            getReferencedColumn: (t) => t.indexedTypeIriId,
            builder: (joinBuilder,
                    {$addJoinBuilderToRootComposer,
                    $removeJoinBuilderFromRootComposer}) =>
                $$GroupIndexSubscriptionsTableFilterComposer(
                  $db: $db,
                  $table: $db.groupIndexSubscriptions,
                  $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                  joinBuilder: joinBuilder,
                  $removeJoinBuilderFromRootComposer:
                      $removeJoinBuilderFromRootComposer,
                ));
    return f(composer);
  }

  Expression<bool> remoteSyncStateRefs(
      Expression<bool> Function($$RemoteSyncStateTableFilterComposer f) f) {
    final $$RemoteSyncStateTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.remoteSyncState,
        getReferencedColumn: (t) => t.documentIriId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$RemoteSyncStateTableFilterComposer(
              $db: $db,
              $table: $db.remoteSyncState,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$SyncIrisTableOrderingComposer
    extends Composer<_$SyncDatabase, $SyncIrisTable> {
  $$SyncIrisTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get iri => $composableBuilder(
      column: $table.iri, builder: (column) => ColumnOrderings(column));
}

class $$SyncIrisTableAnnotationComposer
    extends Composer<_$SyncDatabase, $SyncIrisTable> {
  $$SyncIrisTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get iri =>
      $composableBuilder(column: $table.iri, builder: (column) => column);

  Expression<T> syncDocumentsRefs<T extends Object>(
      Expression<T> Function($$SyncDocumentsTableAnnotationComposer a) f) {
    final $$SyncDocumentsTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.syncDocuments,
        getReferencedColumn: (t) => t.documentIriId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncDocumentsTableAnnotationComposer(
              $db: $db,
              $table: $db.syncDocuments,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<T> typeIri<T extends Object>(
      Expression<T> Function($$SyncDocumentsTableAnnotationComposer a) f) {
    final $$SyncDocumentsTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.syncDocuments,
        getReferencedColumn: (t) => t.typeIriId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncDocumentsTableAnnotationComposer(
              $db: $db,
              $table: $db.syncDocuments,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<T> resourceIri<T extends Object>(
      Expression<T> Function($$SyncPropertyChangesTableAnnotationComposer a)
          f) {
    final $$SyncPropertyChangesTableAnnotationComposer composer =
        $composerBuilder(
            composer: this,
            getCurrentColumn: (t) => t.id,
            referencedTable: $db.syncPropertyChanges,
            getReferencedColumn: (t) => t.resourceIriId,
            builder: (joinBuilder,
                    {$addJoinBuilderToRootComposer,
                    $removeJoinBuilderFromRootComposer}) =>
                $$SyncPropertyChangesTableAnnotationComposer(
                  $db: $db,
                  $table: $db.syncPropertyChanges,
                  $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                  joinBuilder: joinBuilder,
                  $removeJoinBuilderFromRootComposer:
                      $removeJoinBuilderFromRootComposer,
                ));
    return f(composer);
  }

  Expression<T> propertyIri<T extends Object>(
      Expression<T> Function($$SyncPropertyChangesTableAnnotationComposer a)
          f) {
    final $$SyncPropertyChangesTableAnnotationComposer composer =
        $composerBuilder(
            composer: this,
            getCurrentColumn: (t) => t.id,
            referencedTable: $db.syncPropertyChanges,
            getReferencedColumn: (t) => t.propertyIriId,
            builder: (joinBuilder,
                    {$addJoinBuilderToRootComposer,
                    $removeJoinBuilderFromRootComposer}) =>
                $$SyncPropertyChangesTableAnnotationComposer(
                  $db: $db,
                  $table: $db.syncPropertyChanges,
                  $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                  joinBuilder: joinBuilder,
                  $removeJoinBuilderFromRootComposer:
                      $removeJoinBuilderFromRootComposer,
                ));
    return f(composer);
  }

  Expression<T> shardIri<T extends Object>(
      Expression<T> Function($$IndexEntriesTableAnnotationComposer a) f) {
    final $$IndexEntriesTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.indexEntries,
        getReferencedColumn: (t) => t.shardIri,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$IndexEntriesTableAnnotationComposer(
              $db: $db,
              $table: $db.indexEntries,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<T> indexIri<T extends Object>(
      Expression<T> Function($$IndexEntriesTableAnnotationComposer a) f) {
    final $$IndexEntriesTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.indexEntries,
        getReferencedColumn: (t) => t.indexIriId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$IndexEntriesTableAnnotationComposer(
              $db: $db,
              $table: $db.indexEntries,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<T> indexResourceIri<T extends Object>(
      Expression<T> Function($$IndexEntriesTableAnnotationComposer a) f) {
    final $$IndexEntriesTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.indexEntries,
        getReferencedColumn: (t) => t.resourceIriId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$IndexEntriesTableAnnotationComposer(
              $db: $db,
              $table: $db.indexEntries,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<T> resourceTypeIri<T extends Object>(
      Expression<T> Function($$IndexEntriesTableAnnotationComposer a) f) {
    final $$IndexEntriesTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.indexEntries,
        getReferencedColumn: (t) => t.resourceTypeIriId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$IndexEntriesTableAnnotationComposer(
              $db: $db,
              $table: $db.indexEntries,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<T> groupIndexSubscriptionsRefs<T extends Object>(
      Expression<T> Function($$GroupIndexSubscriptionsTableAnnotationComposer a)
          f) {
    final $$GroupIndexSubscriptionsTableAnnotationComposer composer =
        $composerBuilder(
            composer: this,
            getCurrentColumn: (t) => t.id,
            referencedTable: $db.groupIndexSubscriptions,
            getReferencedColumn: (t) => t.groupIndexIriId,
            builder: (joinBuilder,
                    {$addJoinBuilderToRootComposer,
                    $removeJoinBuilderFromRootComposer}) =>
                $$GroupIndexSubscriptionsTableAnnotationComposer(
                  $db: $db,
                  $table: $db.groupIndexSubscriptions,
                  $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                  joinBuilder: joinBuilder,
                  $removeJoinBuilderFromRootComposer:
                      $removeJoinBuilderFromRootComposer,
                ));
    return f(composer);
  }

  Expression<T> groupIndexTemplateIriId<T extends Object>(
      Expression<T> Function($$GroupIndexSubscriptionsTableAnnotationComposer a)
          f) {
    final $$GroupIndexSubscriptionsTableAnnotationComposer composer =
        $composerBuilder(
            composer: this,
            getCurrentColumn: (t) => t.id,
            referencedTable: $db.groupIndexSubscriptions,
            getReferencedColumn: (t) => t.groupIndexTemplateIriId,
            builder: (joinBuilder,
                    {$addJoinBuilderToRootComposer,
                    $removeJoinBuilderFromRootComposer}) =>
                $$GroupIndexSubscriptionsTableAnnotationComposer(
                  $db: $db,
                  $table: $db.groupIndexSubscriptions,
                  $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                  joinBuilder: joinBuilder,
                  $removeJoinBuilderFromRootComposer:
                      $removeJoinBuilderFromRootComposer,
                ));
    return f(composer);
  }

  Expression<T> indexedTypeIriId<T extends Object>(
      Expression<T> Function($$GroupIndexSubscriptionsTableAnnotationComposer a)
          f) {
    final $$GroupIndexSubscriptionsTableAnnotationComposer composer =
        $composerBuilder(
            composer: this,
            getCurrentColumn: (t) => t.id,
            referencedTable: $db.groupIndexSubscriptions,
            getReferencedColumn: (t) => t.indexedTypeIriId,
            builder: (joinBuilder,
                    {$addJoinBuilderToRootComposer,
                    $removeJoinBuilderFromRootComposer}) =>
                $$GroupIndexSubscriptionsTableAnnotationComposer(
                  $db: $db,
                  $table: $db.groupIndexSubscriptions,
                  $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                  joinBuilder: joinBuilder,
                  $removeJoinBuilderFromRootComposer:
                      $removeJoinBuilderFromRootComposer,
                ));
    return f(composer);
  }

  Expression<T> remoteSyncStateRefs<T extends Object>(
      Expression<T> Function($$RemoteSyncStateTableAnnotationComposer a) f) {
    final $$RemoteSyncStateTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.remoteSyncState,
        getReferencedColumn: (t) => t.documentIriId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$RemoteSyncStateTableAnnotationComposer(
              $db: $db,
              $table: $db.remoteSyncState,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$SyncIrisTableTableManager extends RootTableManager<
    _$SyncDatabase,
    $SyncIrisTable,
    SyncIri,
    $$SyncIrisTableFilterComposer,
    $$SyncIrisTableOrderingComposer,
    $$SyncIrisTableAnnotationComposer,
    $$SyncIrisTableCreateCompanionBuilder,
    $$SyncIrisTableUpdateCompanionBuilder,
    (SyncIri, $$SyncIrisTableReferences),
    SyncIri,
    PrefetchHooks Function(
        {bool syncDocumentsRefs,
        bool typeIri,
        bool resourceIri,
        bool propertyIri,
        bool shardIri,
        bool indexIri,
        bool indexResourceIri,
        bool resourceTypeIri,
        bool groupIndexSubscriptionsRefs,
        bool groupIndexTemplateIriId,
        bool indexedTypeIriId,
        bool remoteSyncStateRefs})> {
  $$SyncIrisTableTableManager(_$SyncDatabase db, $SyncIrisTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncIrisTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncIrisTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncIrisTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> iri = const Value.absent(),
          }) =>
              SyncIrisCompanion(
            id: id,
            iri: iri,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String iri,
          }) =>
              SyncIrisCompanion.insert(
            id: id,
            iri: iri,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) =>
                  (e.readTable(table), $$SyncIrisTableReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: (
              {syncDocumentsRefs = false,
              typeIri = false,
              resourceIri = false,
              propertyIri = false,
              shardIri = false,
              indexIri = false,
              indexResourceIri = false,
              resourceTypeIri = false,
              groupIndexSubscriptionsRefs = false,
              groupIndexTemplateIriId = false,
              indexedTypeIriId = false,
              remoteSyncStateRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (syncDocumentsRefs) db.syncDocuments,
                if (typeIri) db.syncDocuments,
                if (resourceIri) db.syncPropertyChanges,
                if (propertyIri) db.syncPropertyChanges,
                if (shardIri) db.indexEntries,
                if (indexIri) db.indexEntries,
                if (indexResourceIri) db.indexEntries,
                if (resourceTypeIri) db.indexEntries,
                if (groupIndexSubscriptionsRefs) db.groupIndexSubscriptions,
                if (groupIndexTemplateIriId) db.groupIndexSubscriptions,
                if (indexedTypeIriId) db.groupIndexSubscriptions,
                if (remoteSyncStateRefs) db.remoteSyncState
              ],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (syncDocumentsRefs)
                    await $_getPrefetchedData<SyncIri, $SyncIrisTable,
                            SyncDocument>(
                        currentTable: table,
                        referencedTable: $$SyncIrisTableReferences
                            ._syncDocumentsRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$SyncIrisTableReferences(db, table, p0)
                                .syncDocumentsRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.documentIriId == item.id),
                        typedResults: items),
                  if (typeIri)
                    await $_getPrefetchedData<SyncIri, $SyncIrisTable,
                            SyncDocument>(
                        currentTable: table,
                        referencedTable:
                            $$SyncIrisTableReferences._typeIriTable(db),
                        managerFromTypedResult: (p0) =>
                            $$SyncIrisTableReferences(db, table, p0).typeIri,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.typeIriId == item.id),
                        typedResults: items),
                  if (resourceIri)
                    await $_getPrefetchedData<SyncIri, $SyncIrisTable,
                            SyncPropertyChange>(
                        currentTable: table,
                        referencedTable:
                            $$SyncIrisTableReferences._resourceIriTable(db),
                        managerFromTypedResult: (p0) =>
                            $$SyncIrisTableReferences(db, table, p0)
                                .resourceIri,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.resourceIriId == item.id),
                        typedResults: items),
                  if (propertyIri)
                    await $_getPrefetchedData<SyncIri, $SyncIrisTable,
                            SyncPropertyChange>(
                        currentTable: table,
                        referencedTable:
                            $$SyncIrisTableReferences._propertyIriTable(db),
                        managerFromTypedResult: (p0) =>
                            $$SyncIrisTableReferences(db, table, p0)
                                .propertyIri,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.propertyIriId == item.id),
                        typedResults: items),
                  if (shardIri)
                    await $_getPrefetchedData<SyncIri, $SyncIrisTable,
                            IndexEntry>(
                        currentTable: table,
                        referencedTable:
                            $$SyncIrisTableReferences._shardIriTable(db),
                        managerFromTypedResult: (p0) =>
                            $$SyncIrisTableReferences(db, table, p0).shardIri,
                        referencedItemsForCurrentItem: (item,
                                referencedItems) =>
                            referencedItems.where((e) => e.shardIri == item.id),
                        typedResults: items),
                  if (indexIri)
                    await $_getPrefetchedData<SyncIri, $SyncIrisTable,
                            IndexEntry>(
                        currentTable: table,
                        referencedTable:
                            $$SyncIrisTableReferences._indexIriTable(db),
                        managerFromTypedResult: (p0) =>
                            $$SyncIrisTableReferences(db, table, p0).indexIri,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.indexIriId == item.id),
                        typedResults: items),
                  if (indexResourceIri)
                    await $_getPrefetchedData<SyncIri, $SyncIrisTable,
                            IndexEntry>(
                        currentTable: table,
                        referencedTable: $$SyncIrisTableReferences
                            ._indexResourceIriTable(db),
                        managerFromTypedResult: (p0) =>
                            $$SyncIrisTableReferences(db, table, p0)
                                .indexResourceIri,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.resourceIriId == item.id),
                        typedResults: items),
                  if (resourceTypeIri)
                    await $_getPrefetchedData<SyncIri, $SyncIrisTable,
                            IndexEntry>(
                        currentTable: table,
                        referencedTable:
                            $$SyncIrisTableReferences._resourceTypeIriTable(db),
                        managerFromTypedResult: (p0) =>
                            $$SyncIrisTableReferences(db, table, p0)
                                .resourceTypeIri,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.resourceTypeIriId == item.id),
                        typedResults: items),
                  if (groupIndexSubscriptionsRefs)
                    await $_getPrefetchedData<SyncIri, $SyncIrisTable,
                            GroupIndexSubscription>(
                        currentTable: table,
                        referencedTable: $$SyncIrisTableReferences
                            ._groupIndexSubscriptionsRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$SyncIrisTableReferences(db, table, p0)
                                .groupIndexSubscriptionsRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.groupIndexIriId == item.id),
                        typedResults: items),
                  if (groupIndexTemplateIriId)
                    await $_getPrefetchedData<SyncIri, $SyncIrisTable,
                            GroupIndexSubscription>(
                        currentTable: table,
                        referencedTable: $$SyncIrisTableReferences
                            ._groupIndexTemplateIriIdTable(db),
                        managerFromTypedResult: (p0) =>
                            $$SyncIrisTableReferences(db, table, p0)
                                .groupIndexTemplateIriId,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems.where(
                                (e) => e.groupIndexTemplateIriId == item.id),
                        typedResults: items),
                  if (indexedTypeIriId)
                    await $_getPrefetchedData<SyncIri, $SyncIrisTable,
                            GroupIndexSubscription>(
                        currentTable: table,
                        referencedTable: $$SyncIrisTableReferences
                            ._indexedTypeIriIdTable(db),
                        managerFromTypedResult: (p0) =>
                            $$SyncIrisTableReferences(db, table, p0)
                                .indexedTypeIriId,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.indexedTypeIriId == item.id),
                        typedResults: items),
                  if (remoteSyncStateRefs)
                    await $_getPrefetchedData<SyncIri, $SyncIrisTable,
                            RemoteSyncStateData>(
                        currentTable: table,
                        referencedTable: $$SyncIrisTableReferences
                            ._remoteSyncStateRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$SyncIrisTableReferences(db, table, p0)
                                .remoteSyncStateRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.documentIriId == item.id),
                        typedResults: items)
                ];
              },
            );
          },
        ));
}

typedef $$SyncIrisTableProcessedTableManager = ProcessedTableManager<
    _$SyncDatabase,
    $SyncIrisTable,
    SyncIri,
    $$SyncIrisTableFilterComposer,
    $$SyncIrisTableOrderingComposer,
    $$SyncIrisTableAnnotationComposer,
    $$SyncIrisTableCreateCompanionBuilder,
    $$SyncIrisTableUpdateCompanionBuilder,
    (SyncIri, $$SyncIrisTableReferences),
    SyncIri,
    PrefetchHooks Function(
        {bool syncDocumentsRefs,
        bool typeIri,
        bool resourceIri,
        bool propertyIri,
        bool shardIri,
        bool indexIri,
        bool indexResourceIri,
        bool resourceTypeIri,
        bool groupIndexSubscriptionsRefs,
        bool groupIndexTemplateIriId,
        bool indexedTypeIriId,
        bool remoteSyncStateRefs})>;
typedef $$SyncDocumentsTableCreateCompanionBuilder = SyncDocumentsCompanion
    Function({
  Value<int> id,
  required int documentIriId,
  required int typeIriId,
  required String documentContent,
  required int ourPhysicalClock,
  required int updatedAt,
});
typedef $$SyncDocumentsTableUpdateCompanionBuilder = SyncDocumentsCompanion
    Function({
  Value<int> id,
  Value<int> documentIriId,
  Value<int> typeIriId,
  Value<String> documentContent,
  Value<int> ourPhysicalClock,
  Value<int> updatedAt,
});

final class $$SyncDocumentsTableReferences
    extends BaseReferences<_$SyncDatabase, $SyncDocumentsTable, SyncDocument> {
  $$SyncDocumentsTableReferences(
      super.$_db, super.$_table, super.$_typedResult);

  static $SyncIrisTable _documentIriIdTable(_$SyncDatabase db) =>
      db.syncIris.createAlias(
          $_aliasNameGenerator(db.syncDocuments.documentIriId, db.syncIris.id));

  $$SyncIrisTableProcessedTableManager get documentIriId {
    final $_column = $_itemColumn<int>('document_iri_id')!;

    final manager = $$SyncIrisTableTableManager($_db, $_db.syncIris)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_documentIriIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }

  static $SyncIrisTable _typeIriIdTable(_$SyncDatabase db) =>
      db.syncIris.createAlias(
          $_aliasNameGenerator(db.syncDocuments.typeIriId, db.syncIris.id));

  $$SyncIrisTableProcessedTableManager get typeIriId {
    final $_column = $_itemColumn<int>('type_iri_id')!;

    final manager = $$SyncIrisTableTableManager($_db, $_db.syncIris)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_typeIriIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }

  static MultiTypedResultKey<$SyncPropertyChangesTable,
      List<SyncPropertyChange>> _syncPropertyChangesRefsTable(
          _$SyncDatabase db) =>
      MultiTypedResultKey.fromTable(db.syncPropertyChanges,
          aliasName: $_aliasNameGenerator(
              db.syncDocuments.id, db.syncPropertyChanges.documentId));

  $$SyncPropertyChangesTableProcessedTableManager get syncPropertyChangesRefs {
    final manager =
        $$SyncPropertyChangesTableTableManager($_db, $_db.syncPropertyChanges)
            .filter((f) => f.documentId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache =
        $_typedResult.readTableOrNull(_syncPropertyChangesRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }
}

class $$SyncDocumentsTableFilterComposer
    extends Composer<_$SyncDatabase, $SyncDocumentsTable> {
  $$SyncDocumentsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get documentContent => $composableBuilder(
      column: $table.documentContent,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get ourPhysicalClock => $composableBuilder(
      column: $table.ourPhysicalClock,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));

  $$SyncIrisTableFilterComposer get documentIriId {
    final $$SyncIrisTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.documentIriId,
        referencedTable: $db.syncIris,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncIrisTableFilterComposer(
              $db: $db,
              $table: $db.syncIris,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$SyncIrisTableFilterComposer get typeIriId {
    final $$SyncIrisTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.typeIriId,
        referencedTable: $db.syncIris,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncIrisTableFilterComposer(
              $db: $db,
              $table: $db.syncIris,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  Expression<bool> syncPropertyChangesRefs(
      Expression<bool> Function($$SyncPropertyChangesTableFilterComposer f) f) {
    final $$SyncPropertyChangesTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.syncPropertyChanges,
        getReferencedColumn: (t) => t.documentId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncPropertyChangesTableFilterComposer(
              $db: $db,
              $table: $db.syncPropertyChanges,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$SyncDocumentsTableOrderingComposer
    extends Composer<_$SyncDatabase, $SyncDocumentsTable> {
  $$SyncDocumentsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get documentContent => $composableBuilder(
      column: $table.documentContent,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get ourPhysicalClock => $composableBuilder(
      column: $table.ourPhysicalClock,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));

  $$SyncIrisTableOrderingComposer get documentIriId {
    final $$SyncIrisTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.documentIriId,
        referencedTable: $db.syncIris,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncIrisTableOrderingComposer(
              $db: $db,
              $table: $db.syncIris,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$SyncIrisTableOrderingComposer get typeIriId {
    final $$SyncIrisTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.typeIriId,
        referencedTable: $db.syncIris,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncIrisTableOrderingComposer(
              $db: $db,
              $table: $db.syncIris,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$SyncDocumentsTableAnnotationComposer
    extends Composer<_$SyncDatabase, $SyncDocumentsTable> {
  $$SyncDocumentsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get documentContent => $composableBuilder(
      column: $table.documentContent, builder: (column) => column);

  GeneratedColumn<int> get ourPhysicalClock => $composableBuilder(
      column: $table.ourPhysicalClock, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  $$SyncIrisTableAnnotationComposer get documentIriId {
    final $$SyncIrisTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.documentIriId,
        referencedTable: $db.syncIris,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncIrisTableAnnotationComposer(
              $db: $db,
              $table: $db.syncIris,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$SyncIrisTableAnnotationComposer get typeIriId {
    final $$SyncIrisTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.typeIriId,
        referencedTable: $db.syncIris,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncIrisTableAnnotationComposer(
              $db: $db,
              $table: $db.syncIris,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  Expression<T> syncPropertyChangesRefs<T extends Object>(
      Expression<T> Function($$SyncPropertyChangesTableAnnotationComposer a)
          f) {
    final $$SyncPropertyChangesTableAnnotationComposer composer =
        $composerBuilder(
            composer: this,
            getCurrentColumn: (t) => t.id,
            referencedTable: $db.syncPropertyChanges,
            getReferencedColumn: (t) => t.documentId,
            builder: (joinBuilder,
                    {$addJoinBuilderToRootComposer,
                    $removeJoinBuilderFromRootComposer}) =>
                $$SyncPropertyChangesTableAnnotationComposer(
                  $db: $db,
                  $table: $db.syncPropertyChanges,
                  $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                  joinBuilder: joinBuilder,
                  $removeJoinBuilderFromRootComposer:
                      $removeJoinBuilderFromRootComposer,
                ));
    return f(composer);
  }
}

class $$SyncDocumentsTableTableManager extends RootTableManager<
    _$SyncDatabase,
    $SyncDocumentsTable,
    SyncDocument,
    $$SyncDocumentsTableFilterComposer,
    $$SyncDocumentsTableOrderingComposer,
    $$SyncDocumentsTableAnnotationComposer,
    $$SyncDocumentsTableCreateCompanionBuilder,
    $$SyncDocumentsTableUpdateCompanionBuilder,
    (SyncDocument, $$SyncDocumentsTableReferences),
    SyncDocument,
    PrefetchHooks Function(
        {bool documentIriId, bool typeIriId, bool syncPropertyChangesRefs})> {
  $$SyncDocumentsTableTableManager(_$SyncDatabase db, $SyncDocumentsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncDocumentsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncDocumentsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncDocumentsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int> documentIriId = const Value.absent(),
            Value<int> typeIriId = const Value.absent(),
            Value<String> documentContent = const Value.absent(),
            Value<int> ourPhysicalClock = const Value.absent(),
            Value<int> updatedAt = const Value.absent(),
          }) =>
              SyncDocumentsCompanion(
            id: id,
            documentIriId: documentIriId,
            typeIriId: typeIriId,
            documentContent: documentContent,
            ourPhysicalClock: ourPhysicalClock,
            updatedAt: updatedAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required int documentIriId,
            required int typeIriId,
            required String documentContent,
            required int ourPhysicalClock,
            required int updatedAt,
          }) =>
              SyncDocumentsCompanion.insert(
            id: id,
            documentIriId: documentIriId,
            typeIriId: typeIriId,
            documentContent: documentContent,
            ourPhysicalClock: ourPhysicalClock,
            updatedAt: updatedAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$SyncDocumentsTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: (
              {documentIriId = false,
              typeIriId = false,
              syncPropertyChangesRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (syncPropertyChangesRefs) db.syncPropertyChanges
              ],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (documentIriId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.documentIriId,
                    referencedTable:
                        $$SyncDocumentsTableReferences._documentIriIdTable(db),
                    referencedColumn: $$SyncDocumentsTableReferences
                        ._documentIriIdTable(db)
                        .id,
                  ) as T;
                }
                if (typeIriId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.typeIriId,
                    referencedTable:
                        $$SyncDocumentsTableReferences._typeIriIdTable(db),
                    referencedColumn:
                        $$SyncDocumentsTableReferences._typeIriIdTable(db).id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [
                  if (syncPropertyChangesRefs)
                    await $_getPrefetchedData<SyncDocument, $SyncDocumentsTable,
                            SyncPropertyChange>(
                        currentTable: table,
                        referencedTable: $$SyncDocumentsTableReferences
                            ._syncPropertyChangesRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$SyncDocumentsTableReferences(db, table, p0)
                                .syncPropertyChangesRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.documentId == item.id),
                        typedResults: items)
                ];
              },
            );
          },
        ));
}

typedef $$SyncDocumentsTableProcessedTableManager = ProcessedTableManager<
    _$SyncDatabase,
    $SyncDocumentsTable,
    SyncDocument,
    $$SyncDocumentsTableFilterComposer,
    $$SyncDocumentsTableOrderingComposer,
    $$SyncDocumentsTableAnnotationComposer,
    $$SyncDocumentsTableCreateCompanionBuilder,
    $$SyncDocumentsTableUpdateCompanionBuilder,
    (SyncDocument, $$SyncDocumentsTableReferences),
    SyncDocument,
    PrefetchHooks Function(
        {bool documentIriId, bool typeIriId, bool syncPropertyChangesRefs})>;
typedef $$SyncPropertyChangesTableCreateCompanionBuilder
    = SyncPropertyChangesCompanion Function({
  required int documentId,
  required int resourceIriId,
  required int propertyIriId,
  required int changedAtMs,
  required int changeLogicalClock,
  Value<bool> isFrameworkProperty,
  Value<int> rowid,
});
typedef $$SyncPropertyChangesTableUpdateCompanionBuilder
    = SyncPropertyChangesCompanion Function({
  Value<int> documentId,
  Value<int> resourceIriId,
  Value<int> propertyIriId,
  Value<int> changedAtMs,
  Value<int> changeLogicalClock,
  Value<bool> isFrameworkProperty,
  Value<int> rowid,
});

final class $$SyncPropertyChangesTableReferences extends BaseReferences<
    _$SyncDatabase, $SyncPropertyChangesTable, SyncPropertyChange> {
  $$SyncPropertyChangesTableReferences(
      super.$_db, super.$_table, super.$_typedResult);

  static $SyncDocumentsTable _documentIdTable(_$SyncDatabase db) =>
      db.syncDocuments.createAlias($_aliasNameGenerator(
          db.syncPropertyChanges.documentId, db.syncDocuments.id));

  $$SyncDocumentsTableProcessedTableManager get documentId {
    final $_column = $_itemColumn<int>('document_id')!;

    final manager = $$SyncDocumentsTableTableManager($_db, $_db.syncDocuments)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_documentIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }

  static $SyncIrisTable _resourceIriIdTable(_$SyncDatabase db) =>
      db.syncIris.createAlias($_aliasNameGenerator(
          db.syncPropertyChanges.resourceIriId, db.syncIris.id));

  $$SyncIrisTableProcessedTableManager get resourceIriId {
    final $_column = $_itemColumn<int>('resource_iri_id')!;

    final manager = $$SyncIrisTableTableManager($_db, $_db.syncIris)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_resourceIriIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }

  static $SyncIrisTable _propertyIriIdTable(_$SyncDatabase db) =>
      db.syncIris.createAlias($_aliasNameGenerator(
          db.syncPropertyChanges.propertyIriId, db.syncIris.id));

  $$SyncIrisTableProcessedTableManager get propertyIriId {
    final $_column = $_itemColumn<int>('property_iri_id')!;

    final manager = $$SyncIrisTableTableManager($_db, $_db.syncIris)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_propertyIriIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$SyncPropertyChangesTableFilterComposer
    extends Composer<_$SyncDatabase, $SyncPropertyChangesTable> {
  $$SyncPropertyChangesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get changedAtMs => $composableBuilder(
      column: $table.changedAtMs, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get changeLogicalClock => $composableBuilder(
      column: $table.changeLogicalClock,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get isFrameworkProperty => $composableBuilder(
      column: $table.isFrameworkProperty,
      builder: (column) => ColumnFilters(column));

  $$SyncDocumentsTableFilterComposer get documentId {
    final $$SyncDocumentsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.documentId,
        referencedTable: $db.syncDocuments,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncDocumentsTableFilterComposer(
              $db: $db,
              $table: $db.syncDocuments,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$SyncIrisTableFilterComposer get resourceIriId {
    final $$SyncIrisTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.resourceIriId,
        referencedTable: $db.syncIris,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncIrisTableFilterComposer(
              $db: $db,
              $table: $db.syncIris,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$SyncIrisTableFilterComposer get propertyIriId {
    final $$SyncIrisTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.propertyIriId,
        referencedTable: $db.syncIris,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncIrisTableFilterComposer(
              $db: $db,
              $table: $db.syncIris,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$SyncPropertyChangesTableOrderingComposer
    extends Composer<_$SyncDatabase, $SyncPropertyChangesTable> {
  $$SyncPropertyChangesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get changedAtMs => $composableBuilder(
      column: $table.changedAtMs, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get changeLogicalClock => $composableBuilder(
      column: $table.changeLogicalClock,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get isFrameworkProperty => $composableBuilder(
      column: $table.isFrameworkProperty,
      builder: (column) => ColumnOrderings(column));

  $$SyncDocumentsTableOrderingComposer get documentId {
    final $$SyncDocumentsTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.documentId,
        referencedTable: $db.syncDocuments,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncDocumentsTableOrderingComposer(
              $db: $db,
              $table: $db.syncDocuments,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$SyncIrisTableOrderingComposer get resourceIriId {
    final $$SyncIrisTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.resourceIriId,
        referencedTable: $db.syncIris,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncIrisTableOrderingComposer(
              $db: $db,
              $table: $db.syncIris,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$SyncIrisTableOrderingComposer get propertyIriId {
    final $$SyncIrisTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.propertyIriId,
        referencedTable: $db.syncIris,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncIrisTableOrderingComposer(
              $db: $db,
              $table: $db.syncIris,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$SyncPropertyChangesTableAnnotationComposer
    extends Composer<_$SyncDatabase, $SyncPropertyChangesTable> {
  $$SyncPropertyChangesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get changedAtMs => $composableBuilder(
      column: $table.changedAtMs, builder: (column) => column);

  GeneratedColumn<int> get changeLogicalClock => $composableBuilder(
      column: $table.changeLogicalClock, builder: (column) => column);

  GeneratedColumn<bool> get isFrameworkProperty => $composableBuilder(
      column: $table.isFrameworkProperty, builder: (column) => column);

  $$SyncDocumentsTableAnnotationComposer get documentId {
    final $$SyncDocumentsTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.documentId,
        referencedTable: $db.syncDocuments,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncDocumentsTableAnnotationComposer(
              $db: $db,
              $table: $db.syncDocuments,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$SyncIrisTableAnnotationComposer get resourceIriId {
    final $$SyncIrisTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.resourceIriId,
        referencedTable: $db.syncIris,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncIrisTableAnnotationComposer(
              $db: $db,
              $table: $db.syncIris,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$SyncIrisTableAnnotationComposer get propertyIriId {
    final $$SyncIrisTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.propertyIriId,
        referencedTable: $db.syncIris,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncIrisTableAnnotationComposer(
              $db: $db,
              $table: $db.syncIris,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$SyncPropertyChangesTableTableManager extends RootTableManager<
    _$SyncDatabase,
    $SyncPropertyChangesTable,
    SyncPropertyChange,
    $$SyncPropertyChangesTableFilterComposer,
    $$SyncPropertyChangesTableOrderingComposer,
    $$SyncPropertyChangesTableAnnotationComposer,
    $$SyncPropertyChangesTableCreateCompanionBuilder,
    $$SyncPropertyChangesTableUpdateCompanionBuilder,
    (SyncPropertyChange, $$SyncPropertyChangesTableReferences),
    SyncPropertyChange,
    PrefetchHooks Function(
        {bool documentId, bool resourceIriId, bool propertyIriId})> {
  $$SyncPropertyChangesTableTableManager(
      _$SyncDatabase db, $SyncPropertyChangesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncPropertyChangesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncPropertyChangesTableOrderingComposer(
                  $db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncPropertyChangesTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> documentId = const Value.absent(),
            Value<int> resourceIriId = const Value.absent(),
            Value<int> propertyIriId = const Value.absent(),
            Value<int> changedAtMs = const Value.absent(),
            Value<int> changeLogicalClock = const Value.absent(),
            Value<bool> isFrameworkProperty = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              SyncPropertyChangesCompanion(
            documentId: documentId,
            resourceIriId: resourceIriId,
            propertyIriId: propertyIriId,
            changedAtMs: changedAtMs,
            changeLogicalClock: changeLogicalClock,
            isFrameworkProperty: isFrameworkProperty,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required int documentId,
            required int resourceIriId,
            required int propertyIriId,
            required int changedAtMs,
            required int changeLogicalClock,
            Value<bool> isFrameworkProperty = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              SyncPropertyChangesCompanion.insert(
            documentId: documentId,
            resourceIriId: resourceIriId,
            propertyIriId: propertyIriId,
            changedAtMs: changedAtMs,
            changeLogicalClock: changeLogicalClock,
            isFrameworkProperty: isFrameworkProperty,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$SyncPropertyChangesTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: (
              {documentId = false,
              resourceIriId = false,
              propertyIriId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (documentId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.documentId,
                    referencedTable: $$SyncPropertyChangesTableReferences
                        ._documentIdTable(db),
                    referencedColumn: $$SyncPropertyChangesTableReferences
                        ._documentIdTable(db)
                        .id,
                  ) as T;
                }
                if (resourceIriId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.resourceIriId,
                    referencedTable: $$SyncPropertyChangesTableReferences
                        ._resourceIriIdTable(db),
                    referencedColumn: $$SyncPropertyChangesTableReferences
                        ._resourceIriIdTable(db)
                        .id,
                  ) as T;
                }
                if (propertyIriId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.propertyIriId,
                    referencedTable: $$SyncPropertyChangesTableReferences
                        ._propertyIriIdTable(db),
                    referencedColumn: $$SyncPropertyChangesTableReferences
                        ._propertyIriIdTable(db)
                        .id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ));
}

typedef $$SyncPropertyChangesTableProcessedTableManager = ProcessedTableManager<
    _$SyncDatabase,
    $SyncPropertyChangesTable,
    SyncPropertyChange,
    $$SyncPropertyChangesTableFilterComposer,
    $$SyncPropertyChangesTableOrderingComposer,
    $$SyncPropertyChangesTableAnnotationComposer,
    $$SyncPropertyChangesTableCreateCompanionBuilder,
    $$SyncPropertyChangesTableUpdateCompanionBuilder,
    (SyncPropertyChange, $$SyncPropertyChangesTableReferences),
    SyncPropertyChange,
    PrefetchHooks Function(
        {bool documentId, bool resourceIriId, bool propertyIriId})>;
typedef $$SyncSettingsTableCreateCompanionBuilder = SyncSettingsCompanion
    Function({
  required String key,
  required String value,
  Value<int> rowid,
});
typedef $$SyncSettingsTableUpdateCompanionBuilder = SyncSettingsCompanion
    Function({
  Value<String> key,
  Value<String> value,
  Value<int> rowid,
});

class $$SyncSettingsTableFilterComposer
    extends Composer<_$SyncDatabase, $SyncSettingsTable> {
  $$SyncSettingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get value => $composableBuilder(
      column: $table.value, builder: (column) => ColumnFilters(column));
}

class $$SyncSettingsTableOrderingComposer
    extends Composer<_$SyncDatabase, $SyncSettingsTable> {
  $$SyncSettingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get value => $composableBuilder(
      column: $table.value, builder: (column) => ColumnOrderings(column));
}

class $$SyncSettingsTableAnnotationComposer
    extends Composer<_$SyncDatabase, $SyncSettingsTable> {
  $$SyncSettingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$SyncSettingsTableTableManager extends RootTableManager<
    _$SyncDatabase,
    $SyncSettingsTable,
    SyncSetting,
    $$SyncSettingsTableFilterComposer,
    $$SyncSettingsTableOrderingComposer,
    $$SyncSettingsTableAnnotationComposer,
    $$SyncSettingsTableCreateCompanionBuilder,
    $$SyncSettingsTableUpdateCompanionBuilder,
    (
      SyncSetting,
      BaseReferences<_$SyncDatabase, $SyncSettingsTable, SyncSetting>
    ),
    SyncSetting,
    PrefetchHooks Function()> {
  $$SyncSettingsTableTableManager(_$SyncDatabase db, $SyncSettingsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncSettingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncSettingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncSettingsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> key = const Value.absent(),
            Value<String> value = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              SyncSettingsCompanion(
            key: key,
            value: value,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String key,
            required String value,
            Value<int> rowid = const Value.absent(),
          }) =>
              SyncSettingsCompanion.insert(
            key: key,
            value: value,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$SyncSettingsTableProcessedTableManager = ProcessedTableManager<
    _$SyncDatabase,
    $SyncSettingsTable,
    SyncSetting,
    $$SyncSettingsTableFilterComposer,
    $$SyncSettingsTableOrderingComposer,
    $$SyncSettingsTableAnnotationComposer,
    $$SyncSettingsTableCreateCompanionBuilder,
    $$SyncSettingsTableUpdateCompanionBuilder,
    (
      SyncSetting,
      BaseReferences<_$SyncDatabase, $SyncSettingsTable, SyncSetting>
    ),
    SyncSetting,
    PrefetchHooks Function()>;
typedef $$IndexEntriesTableCreateCompanionBuilder = IndexEntriesCompanion
    Function({
  required int shardIri,
  required int indexIriId,
  required int resourceIriId,
  required int resourceTypeIriId,
  required String clockHash,
  Value<String?> headerProperties,
  required int updatedAt,
  required int ourPhysicalClock,
  Value<bool> isDeleted,
  Value<int> rowid,
});
typedef $$IndexEntriesTableUpdateCompanionBuilder = IndexEntriesCompanion
    Function({
  Value<int> shardIri,
  Value<int> indexIriId,
  Value<int> resourceIriId,
  Value<int> resourceTypeIriId,
  Value<String> clockHash,
  Value<String?> headerProperties,
  Value<int> updatedAt,
  Value<int> ourPhysicalClock,
  Value<bool> isDeleted,
  Value<int> rowid,
});

final class $$IndexEntriesTableReferences
    extends BaseReferences<_$SyncDatabase, $IndexEntriesTable, IndexEntry> {
  $$IndexEntriesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $SyncIrisTable _shardIriTable(_$SyncDatabase db) =>
      db.syncIris.createAlias(
          $_aliasNameGenerator(db.indexEntries.shardIri, db.syncIris.id));

  $$SyncIrisTableProcessedTableManager get shardIri {
    final $_column = $_itemColumn<int>('shard_iri')!;

    final manager = $$SyncIrisTableTableManager($_db, $_db.syncIris)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_shardIriTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }

  static $SyncIrisTable _indexIriIdTable(_$SyncDatabase db) =>
      db.syncIris.createAlias(
          $_aliasNameGenerator(db.indexEntries.indexIriId, db.syncIris.id));

  $$SyncIrisTableProcessedTableManager get indexIriId {
    final $_column = $_itemColumn<int>('index_iri_id')!;

    final manager = $$SyncIrisTableTableManager($_db, $_db.syncIris)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_indexIriIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }

  static $SyncIrisTable _resourceIriIdTable(_$SyncDatabase db) =>
      db.syncIris.createAlias(
          $_aliasNameGenerator(db.indexEntries.resourceIriId, db.syncIris.id));

  $$SyncIrisTableProcessedTableManager get resourceIriId {
    final $_column = $_itemColumn<int>('resource_iri_id')!;

    final manager = $$SyncIrisTableTableManager($_db, $_db.syncIris)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_resourceIriIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }

  static $SyncIrisTable _resourceTypeIriIdTable(_$SyncDatabase db) =>
      db.syncIris.createAlias($_aliasNameGenerator(
          db.indexEntries.resourceTypeIriId, db.syncIris.id));

  $$SyncIrisTableProcessedTableManager get resourceTypeIriId {
    final $_column = $_itemColumn<int>('resource_type_iri_id')!;

    final manager = $$SyncIrisTableTableManager($_db, $_db.syncIris)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_resourceTypeIriIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$IndexEntriesTableFilterComposer
    extends Composer<_$SyncDatabase, $IndexEntriesTable> {
  $$IndexEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get clockHash => $composableBuilder(
      column: $table.clockHash, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get headerProperties => $composableBuilder(
      column: $table.headerProperties,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get ourPhysicalClock => $composableBuilder(
      column: $table.ourPhysicalClock,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get isDeleted => $composableBuilder(
      column: $table.isDeleted, builder: (column) => ColumnFilters(column));

  $$SyncIrisTableFilterComposer get shardIri {
    final $$SyncIrisTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.shardIri,
        referencedTable: $db.syncIris,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncIrisTableFilterComposer(
              $db: $db,
              $table: $db.syncIris,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$SyncIrisTableFilterComposer get indexIriId {
    final $$SyncIrisTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.indexIriId,
        referencedTable: $db.syncIris,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncIrisTableFilterComposer(
              $db: $db,
              $table: $db.syncIris,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$SyncIrisTableFilterComposer get resourceIriId {
    final $$SyncIrisTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.resourceIriId,
        referencedTable: $db.syncIris,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncIrisTableFilterComposer(
              $db: $db,
              $table: $db.syncIris,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$SyncIrisTableFilterComposer get resourceTypeIriId {
    final $$SyncIrisTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.resourceTypeIriId,
        referencedTable: $db.syncIris,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncIrisTableFilterComposer(
              $db: $db,
              $table: $db.syncIris,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$IndexEntriesTableOrderingComposer
    extends Composer<_$SyncDatabase, $IndexEntriesTable> {
  $$IndexEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get clockHash => $composableBuilder(
      column: $table.clockHash, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get headerProperties => $composableBuilder(
      column: $table.headerProperties,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get ourPhysicalClock => $composableBuilder(
      column: $table.ourPhysicalClock,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get isDeleted => $composableBuilder(
      column: $table.isDeleted, builder: (column) => ColumnOrderings(column));

  $$SyncIrisTableOrderingComposer get shardIri {
    final $$SyncIrisTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.shardIri,
        referencedTable: $db.syncIris,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncIrisTableOrderingComposer(
              $db: $db,
              $table: $db.syncIris,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$SyncIrisTableOrderingComposer get indexIriId {
    final $$SyncIrisTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.indexIriId,
        referencedTable: $db.syncIris,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncIrisTableOrderingComposer(
              $db: $db,
              $table: $db.syncIris,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$SyncIrisTableOrderingComposer get resourceIriId {
    final $$SyncIrisTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.resourceIriId,
        referencedTable: $db.syncIris,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncIrisTableOrderingComposer(
              $db: $db,
              $table: $db.syncIris,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$SyncIrisTableOrderingComposer get resourceTypeIriId {
    final $$SyncIrisTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.resourceTypeIriId,
        referencedTable: $db.syncIris,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncIrisTableOrderingComposer(
              $db: $db,
              $table: $db.syncIris,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$IndexEntriesTableAnnotationComposer
    extends Composer<_$SyncDatabase, $IndexEntriesTable> {
  $$IndexEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get clockHash =>
      $composableBuilder(column: $table.clockHash, builder: (column) => column);

  GeneratedColumn<String> get headerProperties => $composableBuilder(
      column: $table.headerProperties, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<int> get ourPhysicalClock => $composableBuilder(
      column: $table.ourPhysicalClock, builder: (column) => column);

  GeneratedColumn<bool> get isDeleted =>
      $composableBuilder(column: $table.isDeleted, builder: (column) => column);

  $$SyncIrisTableAnnotationComposer get shardIri {
    final $$SyncIrisTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.shardIri,
        referencedTable: $db.syncIris,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncIrisTableAnnotationComposer(
              $db: $db,
              $table: $db.syncIris,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$SyncIrisTableAnnotationComposer get indexIriId {
    final $$SyncIrisTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.indexIriId,
        referencedTable: $db.syncIris,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncIrisTableAnnotationComposer(
              $db: $db,
              $table: $db.syncIris,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$SyncIrisTableAnnotationComposer get resourceIriId {
    final $$SyncIrisTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.resourceIriId,
        referencedTable: $db.syncIris,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncIrisTableAnnotationComposer(
              $db: $db,
              $table: $db.syncIris,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$SyncIrisTableAnnotationComposer get resourceTypeIriId {
    final $$SyncIrisTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.resourceTypeIriId,
        referencedTable: $db.syncIris,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncIrisTableAnnotationComposer(
              $db: $db,
              $table: $db.syncIris,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$IndexEntriesTableTableManager extends RootTableManager<
    _$SyncDatabase,
    $IndexEntriesTable,
    IndexEntry,
    $$IndexEntriesTableFilterComposer,
    $$IndexEntriesTableOrderingComposer,
    $$IndexEntriesTableAnnotationComposer,
    $$IndexEntriesTableCreateCompanionBuilder,
    $$IndexEntriesTableUpdateCompanionBuilder,
    (IndexEntry, $$IndexEntriesTableReferences),
    IndexEntry,
    PrefetchHooks Function(
        {bool shardIri,
        bool indexIriId,
        bool resourceIriId,
        bool resourceTypeIriId})> {
  $$IndexEntriesTableTableManager(_$SyncDatabase db, $IndexEntriesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$IndexEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$IndexEntriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$IndexEntriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> shardIri = const Value.absent(),
            Value<int> indexIriId = const Value.absent(),
            Value<int> resourceIriId = const Value.absent(),
            Value<int> resourceTypeIriId = const Value.absent(),
            Value<String> clockHash = const Value.absent(),
            Value<String?> headerProperties = const Value.absent(),
            Value<int> updatedAt = const Value.absent(),
            Value<int> ourPhysicalClock = const Value.absent(),
            Value<bool> isDeleted = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              IndexEntriesCompanion(
            shardIri: shardIri,
            indexIriId: indexIriId,
            resourceIriId: resourceIriId,
            resourceTypeIriId: resourceTypeIriId,
            clockHash: clockHash,
            headerProperties: headerProperties,
            updatedAt: updatedAt,
            ourPhysicalClock: ourPhysicalClock,
            isDeleted: isDeleted,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required int shardIri,
            required int indexIriId,
            required int resourceIriId,
            required int resourceTypeIriId,
            required String clockHash,
            Value<String?> headerProperties = const Value.absent(),
            required int updatedAt,
            required int ourPhysicalClock,
            Value<bool> isDeleted = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              IndexEntriesCompanion.insert(
            shardIri: shardIri,
            indexIriId: indexIriId,
            resourceIriId: resourceIriId,
            resourceTypeIriId: resourceTypeIriId,
            clockHash: clockHash,
            headerProperties: headerProperties,
            updatedAt: updatedAt,
            ourPhysicalClock: ourPhysicalClock,
            isDeleted: isDeleted,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$IndexEntriesTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: (
              {shardIri = false,
              indexIriId = false,
              resourceIriId = false,
              resourceTypeIriId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (shardIri) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.shardIri,
                    referencedTable:
                        $$IndexEntriesTableReferences._shardIriTable(db),
                    referencedColumn:
                        $$IndexEntriesTableReferences._shardIriTable(db).id,
                  ) as T;
                }
                if (indexIriId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.indexIriId,
                    referencedTable:
                        $$IndexEntriesTableReferences._indexIriIdTable(db),
                    referencedColumn:
                        $$IndexEntriesTableReferences._indexIriIdTable(db).id,
                  ) as T;
                }
                if (resourceIriId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.resourceIriId,
                    referencedTable:
                        $$IndexEntriesTableReferences._resourceIriIdTable(db),
                    referencedColumn: $$IndexEntriesTableReferences
                        ._resourceIriIdTable(db)
                        .id,
                  ) as T;
                }
                if (resourceTypeIriId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.resourceTypeIriId,
                    referencedTable: $$IndexEntriesTableReferences
                        ._resourceTypeIriIdTable(db),
                    referencedColumn: $$IndexEntriesTableReferences
                        ._resourceTypeIriIdTable(db)
                        .id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ));
}

typedef $$IndexEntriesTableProcessedTableManager = ProcessedTableManager<
    _$SyncDatabase,
    $IndexEntriesTable,
    IndexEntry,
    $$IndexEntriesTableFilterComposer,
    $$IndexEntriesTableOrderingComposer,
    $$IndexEntriesTableAnnotationComposer,
    $$IndexEntriesTableCreateCompanionBuilder,
    $$IndexEntriesTableUpdateCompanionBuilder,
    (IndexEntry, $$IndexEntriesTableReferences),
    IndexEntry,
    PrefetchHooks Function(
        {bool shardIri,
        bool indexIriId,
        bool resourceIriId,
        bool resourceTypeIriId})>;
typedef $$GroupIndexSubscriptionsTableCreateCompanionBuilder
    = GroupIndexSubscriptionsCompanion Function({
  Value<int> groupIndexIriId,
  required int groupIndexTemplateIriId,
  required int indexedTypeIriId,
  required String itemFetchPolicy,
  required int createdAt,
});
typedef $$GroupIndexSubscriptionsTableUpdateCompanionBuilder
    = GroupIndexSubscriptionsCompanion Function({
  Value<int> groupIndexIriId,
  Value<int> groupIndexTemplateIriId,
  Value<int> indexedTypeIriId,
  Value<String> itemFetchPolicy,
  Value<int> createdAt,
});

final class $$GroupIndexSubscriptionsTableReferences extends BaseReferences<
    _$SyncDatabase, $GroupIndexSubscriptionsTable, GroupIndexSubscription> {
  $$GroupIndexSubscriptionsTableReferences(
      super.$_db, super.$_table, super.$_typedResult);

  static $SyncIrisTable _groupIndexIriIdTable(_$SyncDatabase db) =>
      db.syncIris.createAlias($_aliasNameGenerator(
          db.groupIndexSubscriptions.groupIndexIriId, db.syncIris.id));

  $$SyncIrisTableProcessedTableManager get groupIndexIriId {
    final $_column = $_itemColumn<int>('group_index_iri_id')!;

    final manager = $$SyncIrisTableTableManager($_db, $_db.syncIris)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_groupIndexIriIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }

  static $SyncIrisTable _groupIndexTemplateIriIdTable(_$SyncDatabase db) =>
      db.syncIris.createAlias($_aliasNameGenerator(
          db.groupIndexSubscriptions.groupIndexTemplateIriId, db.syncIris.id));

  $$SyncIrisTableProcessedTableManager get groupIndexTemplateIriId {
    final $_column = $_itemColumn<int>('group_index_template_iri_id')!;

    final manager = $$SyncIrisTableTableManager($_db, $_db.syncIris)
        .filter((f) => f.id.sqlEquals($_column));
    final item =
        $_typedResult.readTableOrNull(_groupIndexTemplateIriIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }

  static $SyncIrisTable _indexedTypeIriIdTable(_$SyncDatabase db) =>
      db.syncIris.createAlias($_aliasNameGenerator(
          db.groupIndexSubscriptions.indexedTypeIriId, db.syncIris.id));

  $$SyncIrisTableProcessedTableManager get indexedTypeIriId {
    final $_column = $_itemColumn<int>('indexed_type_iri_id')!;

    final manager = $$SyncIrisTableTableManager($_db, $_db.syncIris)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_indexedTypeIriIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$GroupIndexSubscriptionsTableFilterComposer
    extends Composer<_$SyncDatabase, $GroupIndexSubscriptionsTable> {
  $$GroupIndexSubscriptionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get itemFetchPolicy => $composableBuilder(
      column: $table.itemFetchPolicy,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  $$SyncIrisTableFilterComposer get groupIndexIriId {
    final $$SyncIrisTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.groupIndexIriId,
        referencedTable: $db.syncIris,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncIrisTableFilterComposer(
              $db: $db,
              $table: $db.syncIris,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$SyncIrisTableFilterComposer get groupIndexTemplateIriId {
    final $$SyncIrisTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.groupIndexTemplateIriId,
        referencedTable: $db.syncIris,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncIrisTableFilterComposer(
              $db: $db,
              $table: $db.syncIris,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$SyncIrisTableFilterComposer get indexedTypeIriId {
    final $$SyncIrisTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.indexedTypeIriId,
        referencedTable: $db.syncIris,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncIrisTableFilterComposer(
              $db: $db,
              $table: $db.syncIris,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$GroupIndexSubscriptionsTableOrderingComposer
    extends Composer<_$SyncDatabase, $GroupIndexSubscriptionsTable> {
  $$GroupIndexSubscriptionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get itemFetchPolicy => $composableBuilder(
      column: $table.itemFetchPolicy,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  $$SyncIrisTableOrderingComposer get groupIndexIriId {
    final $$SyncIrisTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.groupIndexIriId,
        referencedTable: $db.syncIris,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncIrisTableOrderingComposer(
              $db: $db,
              $table: $db.syncIris,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$SyncIrisTableOrderingComposer get groupIndexTemplateIriId {
    final $$SyncIrisTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.groupIndexTemplateIriId,
        referencedTable: $db.syncIris,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncIrisTableOrderingComposer(
              $db: $db,
              $table: $db.syncIris,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$SyncIrisTableOrderingComposer get indexedTypeIriId {
    final $$SyncIrisTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.indexedTypeIriId,
        referencedTable: $db.syncIris,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncIrisTableOrderingComposer(
              $db: $db,
              $table: $db.syncIris,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$GroupIndexSubscriptionsTableAnnotationComposer
    extends Composer<_$SyncDatabase, $GroupIndexSubscriptionsTable> {
  $$GroupIndexSubscriptionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get itemFetchPolicy => $composableBuilder(
      column: $table.itemFetchPolicy, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  $$SyncIrisTableAnnotationComposer get groupIndexIriId {
    final $$SyncIrisTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.groupIndexIriId,
        referencedTable: $db.syncIris,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncIrisTableAnnotationComposer(
              $db: $db,
              $table: $db.syncIris,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$SyncIrisTableAnnotationComposer get groupIndexTemplateIriId {
    final $$SyncIrisTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.groupIndexTemplateIriId,
        referencedTable: $db.syncIris,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncIrisTableAnnotationComposer(
              $db: $db,
              $table: $db.syncIris,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$SyncIrisTableAnnotationComposer get indexedTypeIriId {
    final $$SyncIrisTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.indexedTypeIriId,
        referencedTable: $db.syncIris,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncIrisTableAnnotationComposer(
              $db: $db,
              $table: $db.syncIris,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$GroupIndexSubscriptionsTableTableManager extends RootTableManager<
    _$SyncDatabase,
    $GroupIndexSubscriptionsTable,
    GroupIndexSubscription,
    $$GroupIndexSubscriptionsTableFilterComposer,
    $$GroupIndexSubscriptionsTableOrderingComposer,
    $$GroupIndexSubscriptionsTableAnnotationComposer,
    $$GroupIndexSubscriptionsTableCreateCompanionBuilder,
    $$GroupIndexSubscriptionsTableUpdateCompanionBuilder,
    (GroupIndexSubscription, $$GroupIndexSubscriptionsTableReferences),
    GroupIndexSubscription,
    PrefetchHooks Function(
        {bool groupIndexIriId,
        bool groupIndexTemplateIriId,
        bool indexedTypeIriId})> {
  $$GroupIndexSubscriptionsTableTableManager(
      _$SyncDatabase db, $GroupIndexSubscriptionsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$GroupIndexSubscriptionsTableFilterComposer(
                  $db: db, $table: table),
          createOrderingComposer: () =>
              $$GroupIndexSubscriptionsTableOrderingComposer(
                  $db: db, $table: table),
          createComputedFieldComposer: () =>
              $$GroupIndexSubscriptionsTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> groupIndexIriId = const Value.absent(),
            Value<int> groupIndexTemplateIriId = const Value.absent(),
            Value<int> indexedTypeIriId = const Value.absent(),
            Value<String> itemFetchPolicy = const Value.absent(),
            Value<int> createdAt = const Value.absent(),
          }) =>
              GroupIndexSubscriptionsCompanion(
            groupIndexIriId: groupIndexIriId,
            groupIndexTemplateIriId: groupIndexTemplateIriId,
            indexedTypeIriId: indexedTypeIriId,
            itemFetchPolicy: itemFetchPolicy,
            createdAt: createdAt,
          ),
          createCompanionCallback: ({
            Value<int> groupIndexIriId = const Value.absent(),
            required int groupIndexTemplateIriId,
            required int indexedTypeIriId,
            required String itemFetchPolicy,
            required int createdAt,
          }) =>
              GroupIndexSubscriptionsCompanion.insert(
            groupIndexIriId: groupIndexIriId,
            groupIndexTemplateIriId: groupIndexTemplateIriId,
            indexedTypeIriId: indexedTypeIriId,
            itemFetchPolicy: itemFetchPolicy,
            createdAt: createdAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$GroupIndexSubscriptionsTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: (
              {groupIndexIriId = false,
              groupIndexTemplateIriId = false,
              indexedTypeIriId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (groupIndexIriId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.groupIndexIriId,
                    referencedTable: $$GroupIndexSubscriptionsTableReferences
                        ._groupIndexIriIdTable(db),
                    referencedColumn: $$GroupIndexSubscriptionsTableReferences
                        ._groupIndexIriIdTable(db)
                        .id,
                  ) as T;
                }
                if (groupIndexTemplateIriId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.groupIndexTemplateIriId,
                    referencedTable: $$GroupIndexSubscriptionsTableReferences
                        ._groupIndexTemplateIriIdTable(db),
                    referencedColumn: $$GroupIndexSubscriptionsTableReferences
                        ._groupIndexTemplateIriIdTable(db)
                        .id,
                  ) as T;
                }
                if (indexedTypeIriId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.indexedTypeIriId,
                    referencedTable: $$GroupIndexSubscriptionsTableReferences
                        ._indexedTypeIriIdTable(db),
                    referencedColumn: $$GroupIndexSubscriptionsTableReferences
                        ._indexedTypeIriIdTable(db)
                        .id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ));
}

typedef $$GroupIndexSubscriptionsTableProcessedTableManager
    = ProcessedTableManager<
        _$SyncDatabase,
        $GroupIndexSubscriptionsTable,
        GroupIndexSubscription,
        $$GroupIndexSubscriptionsTableFilterComposer,
        $$GroupIndexSubscriptionsTableOrderingComposer,
        $$GroupIndexSubscriptionsTableAnnotationComposer,
        $$GroupIndexSubscriptionsTableCreateCompanionBuilder,
        $$GroupIndexSubscriptionsTableUpdateCompanionBuilder,
        (GroupIndexSubscription, $$GroupIndexSubscriptionsTableReferences),
        GroupIndexSubscription,
        PrefetchHooks Function(
            {bool groupIndexIriId,
            bool groupIndexTemplateIriId,
            bool indexedTypeIriId})>;
typedef $$IndexIriIdSetVersionsTableCreateCompanionBuilder
    = IndexIriIdSetVersionsCompanion Function({
  Value<int> id,
  required String indexIriIds,
  required int createdAt,
});
typedef $$IndexIriIdSetVersionsTableUpdateCompanionBuilder
    = IndexIriIdSetVersionsCompanion Function({
  Value<int> id,
  Value<String> indexIriIds,
  Value<int> createdAt,
});

class $$IndexIriIdSetVersionsTableFilterComposer
    extends Composer<_$SyncDatabase, $IndexIriIdSetVersionsTable> {
  $$IndexIriIdSetVersionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get indexIriIds => $composableBuilder(
      column: $table.indexIriIds, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));
}

class $$IndexIriIdSetVersionsTableOrderingComposer
    extends Composer<_$SyncDatabase, $IndexIriIdSetVersionsTable> {
  $$IndexIriIdSetVersionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get indexIriIds => $composableBuilder(
      column: $table.indexIriIds, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));
}

class $$IndexIriIdSetVersionsTableAnnotationComposer
    extends Composer<_$SyncDatabase, $IndexIriIdSetVersionsTable> {
  $$IndexIriIdSetVersionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get indexIriIds => $composableBuilder(
      column: $table.indexIriIds, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$IndexIriIdSetVersionsTableTableManager extends RootTableManager<
    _$SyncDatabase,
    $IndexIriIdSetVersionsTable,
    IndexIriIdSetVersion,
    $$IndexIriIdSetVersionsTableFilterComposer,
    $$IndexIriIdSetVersionsTableOrderingComposer,
    $$IndexIriIdSetVersionsTableAnnotationComposer,
    $$IndexIriIdSetVersionsTableCreateCompanionBuilder,
    $$IndexIriIdSetVersionsTableUpdateCompanionBuilder,
    (
      IndexIriIdSetVersion,
      BaseReferences<_$SyncDatabase, $IndexIriIdSetVersionsTable,
          IndexIriIdSetVersion>
    ),
    IndexIriIdSetVersion,
    PrefetchHooks Function()> {
  $$IndexIriIdSetVersionsTableTableManager(
      _$SyncDatabase db, $IndexIriIdSetVersionsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$IndexIriIdSetVersionsTableFilterComposer(
                  $db: db, $table: table),
          createOrderingComposer: () =>
              $$IndexIriIdSetVersionsTableOrderingComposer(
                  $db: db, $table: table),
          createComputedFieldComposer: () =>
              $$IndexIriIdSetVersionsTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> indexIriIds = const Value.absent(),
            Value<int> createdAt = const Value.absent(),
          }) =>
              IndexIriIdSetVersionsCompanion(
            id: id,
            indexIriIds: indexIriIds,
            createdAt: createdAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String indexIriIds,
            required int createdAt,
          }) =>
              IndexIriIdSetVersionsCompanion.insert(
            id: id,
            indexIriIds: indexIriIds,
            createdAt: createdAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$IndexIriIdSetVersionsTableProcessedTableManager
    = ProcessedTableManager<
        _$SyncDatabase,
        $IndexIriIdSetVersionsTable,
        IndexIriIdSetVersion,
        $$IndexIriIdSetVersionsTableFilterComposer,
        $$IndexIriIdSetVersionsTableOrderingComposer,
        $$IndexIriIdSetVersionsTableAnnotationComposer,
        $$IndexIriIdSetVersionsTableCreateCompanionBuilder,
        $$IndexIriIdSetVersionsTableUpdateCompanionBuilder,
        (
          IndexIriIdSetVersion,
          BaseReferences<_$SyncDatabase, $IndexIriIdSetVersionsTable,
              IndexIriIdSetVersion>
        ),
        IndexIriIdSetVersion,
        PrefetchHooks Function()>;
typedef $$RemoteSettingsTableCreateCompanionBuilder = RemoteSettingsCompanion
    Function({
  Value<int> id,
  required String remoteId,
  required String remoteType,
  Value<int> lastSyncTimestamp,
  required int createdAt,
});
typedef $$RemoteSettingsTableUpdateCompanionBuilder = RemoteSettingsCompanion
    Function({
  Value<int> id,
  Value<String> remoteId,
  Value<String> remoteType,
  Value<int> lastSyncTimestamp,
  Value<int> createdAt,
});

final class $$RemoteSettingsTableReferences extends BaseReferences<
    _$SyncDatabase, $RemoteSettingsTable, RemoteSetting> {
  $$RemoteSettingsTableReferences(
      super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$RemoteSyncStateTable, List<RemoteSyncStateData>>
      _remoteSyncStateRefsTable(_$SyncDatabase db) =>
          MultiTypedResultKey.fromTable(db.remoteSyncState,
              aliasName: $_aliasNameGenerator(
                  db.remoteSettings.id, db.remoteSyncState.remoteId));

  $$RemoteSyncStateTableProcessedTableManager get remoteSyncStateRefs {
    final manager =
        $$RemoteSyncStateTableTableManager($_db, $_db.remoteSyncState)
            .filter((f) => f.remoteId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache =
        $_typedResult.readTableOrNull(_remoteSyncStateRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }
}

class $$RemoteSettingsTableFilterComposer
    extends Composer<_$SyncDatabase, $RemoteSettingsTable> {
  $$RemoteSettingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get remoteId => $composableBuilder(
      column: $table.remoteId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get remoteType => $composableBuilder(
      column: $table.remoteType, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get lastSyncTimestamp => $composableBuilder(
      column: $table.lastSyncTimestamp,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  Expression<bool> remoteSyncStateRefs(
      Expression<bool> Function($$RemoteSyncStateTableFilterComposer f) f) {
    final $$RemoteSyncStateTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.remoteSyncState,
        getReferencedColumn: (t) => t.remoteId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$RemoteSyncStateTableFilterComposer(
              $db: $db,
              $table: $db.remoteSyncState,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$RemoteSettingsTableOrderingComposer
    extends Composer<_$SyncDatabase, $RemoteSettingsTable> {
  $$RemoteSettingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get remoteId => $composableBuilder(
      column: $table.remoteId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get remoteType => $composableBuilder(
      column: $table.remoteType, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get lastSyncTimestamp => $composableBuilder(
      column: $table.lastSyncTimestamp,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));
}

class $$RemoteSettingsTableAnnotationComposer
    extends Composer<_$SyncDatabase, $RemoteSettingsTable> {
  $$RemoteSettingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get remoteId =>
      $composableBuilder(column: $table.remoteId, builder: (column) => column);

  GeneratedColumn<String> get remoteType => $composableBuilder(
      column: $table.remoteType, builder: (column) => column);

  GeneratedColumn<int> get lastSyncTimestamp => $composableBuilder(
      column: $table.lastSyncTimestamp, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  Expression<T> remoteSyncStateRefs<T extends Object>(
      Expression<T> Function($$RemoteSyncStateTableAnnotationComposer a) f) {
    final $$RemoteSyncStateTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.remoteSyncState,
        getReferencedColumn: (t) => t.remoteId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$RemoteSyncStateTableAnnotationComposer(
              $db: $db,
              $table: $db.remoteSyncState,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$RemoteSettingsTableTableManager extends RootTableManager<
    _$SyncDatabase,
    $RemoteSettingsTable,
    RemoteSetting,
    $$RemoteSettingsTableFilterComposer,
    $$RemoteSettingsTableOrderingComposer,
    $$RemoteSettingsTableAnnotationComposer,
    $$RemoteSettingsTableCreateCompanionBuilder,
    $$RemoteSettingsTableUpdateCompanionBuilder,
    (RemoteSetting, $$RemoteSettingsTableReferences),
    RemoteSetting,
    PrefetchHooks Function({bool remoteSyncStateRefs})> {
  $$RemoteSettingsTableTableManager(
      _$SyncDatabase db, $RemoteSettingsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RemoteSettingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$RemoteSettingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$RemoteSettingsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> remoteId = const Value.absent(),
            Value<String> remoteType = const Value.absent(),
            Value<int> lastSyncTimestamp = const Value.absent(),
            Value<int> createdAt = const Value.absent(),
          }) =>
              RemoteSettingsCompanion(
            id: id,
            remoteId: remoteId,
            remoteType: remoteType,
            lastSyncTimestamp: lastSyncTimestamp,
            createdAt: createdAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String remoteId,
            required String remoteType,
            Value<int> lastSyncTimestamp = const Value.absent(),
            required int createdAt,
          }) =>
              RemoteSettingsCompanion.insert(
            id: id,
            remoteId: remoteId,
            remoteType: remoteType,
            lastSyncTimestamp: lastSyncTimestamp,
            createdAt: createdAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$RemoteSettingsTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({remoteSyncStateRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (remoteSyncStateRefs) db.remoteSyncState
              ],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (remoteSyncStateRefs)
                    await $_getPrefetchedData<RemoteSetting,
                            $RemoteSettingsTable, RemoteSyncStateData>(
                        currentTable: table,
                        referencedTable: $$RemoteSettingsTableReferences
                            ._remoteSyncStateRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$RemoteSettingsTableReferences(db, table, p0)
                                .remoteSyncStateRefs,
                        referencedItemsForCurrentItem: (item,
                                referencedItems) =>
                            referencedItems.where((e) => e.remoteId == item.id),
                        typedResults: items)
                ];
              },
            );
          },
        ));
}

typedef $$RemoteSettingsTableProcessedTableManager = ProcessedTableManager<
    _$SyncDatabase,
    $RemoteSettingsTable,
    RemoteSetting,
    $$RemoteSettingsTableFilterComposer,
    $$RemoteSettingsTableOrderingComposer,
    $$RemoteSettingsTableAnnotationComposer,
    $$RemoteSettingsTableCreateCompanionBuilder,
    $$RemoteSettingsTableUpdateCompanionBuilder,
    (RemoteSetting, $$RemoteSettingsTableReferences),
    RemoteSetting,
    PrefetchHooks Function({bool remoteSyncStateRefs})>;
typedef $$RemoteSyncStateTableCreateCompanionBuilder = RemoteSyncStateCompanion
    Function({
  required int documentIriId,
  required int remoteId,
  Value<String?> etag,
  Value<int> lastSyncedAt,
  Value<int> rowid,
});
typedef $$RemoteSyncStateTableUpdateCompanionBuilder = RemoteSyncStateCompanion
    Function({
  Value<int> documentIriId,
  Value<int> remoteId,
  Value<String?> etag,
  Value<int> lastSyncedAt,
  Value<int> rowid,
});

final class $$RemoteSyncStateTableReferences extends BaseReferences<
    _$SyncDatabase, $RemoteSyncStateTable, RemoteSyncStateData> {
  $$RemoteSyncStateTableReferences(
      super.$_db, super.$_table, super.$_typedResult);

  static $SyncIrisTable _documentIriIdTable(_$SyncDatabase db) =>
      db.syncIris.createAlias($_aliasNameGenerator(
          db.remoteSyncState.documentIriId, db.syncIris.id));

  $$SyncIrisTableProcessedTableManager get documentIriId {
    final $_column = $_itemColumn<int>('document_iri_id')!;

    final manager = $$SyncIrisTableTableManager($_db, $_db.syncIris)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_documentIriIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }

  static $RemoteSettingsTable _remoteIdTable(_$SyncDatabase db) =>
      db.remoteSettings.createAlias($_aliasNameGenerator(
          db.remoteSyncState.remoteId, db.remoteSettings.id));

  $$RemoteSettingsTableProcessedTableManager get remoteId {
    final $_column = $_itemColumn<int>('remote_id')!;

    final manager = $$RemoteSettingsTableTableManager($_db, $_db.remoteSettings)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_remoteIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$RemoteSyncStateTableFilterComposer
    extends Composer<_$SyncDatabase, $RemoteSyncStateTable> {
  $$RemoteSyncStateTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get etag => $composableBuilder(
      column: $table.etag, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get lastSyncedAt => $composableBuilder(
      column: $table.lastSyncedAt, builder: (column) => ColumnFilters(column));

  $$SyncIrisTableFilterComposer get documentIriId {
    final $$SyncIrisTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.documentIriId,
        referencedTable: $db.syncIris,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncIrisTableFilterComposer(
              $db: $db,
              $table: $db.syncIris,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$RemoteSettingsTableFilterComposer get remoteId {
    final $$RemoteSettingsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.remoteId,
        referencedTable: $db.remoteSettings,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$RemoteSettingsTableFilterComposer(
              $db: $db,
              $table: $db.remoteSettings,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$RemoteSyncStateTableOrderingComposer
    extends Composer<_$SyncDatabase, $RemoteSyncStateTable> {
  $$RemoteSyncStateTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get etag => $composableBuilder(
      column: $table.etag, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get lastSyncedAt => $composableBuilder(
      column: $table.lastSyncedAt,
      builder: (column) => ColumnOrderings(column));

  $$SyncIrisTableOrderingComposer get documentIriId {
    final $$SyncIrisTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.documentIriId,
        referencedTable: $db.syncIris,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncIrisTableOrderingComposer(
              $db: $db,
              $table: $db.syncIris,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$RemoteSettingsTableOrderingComposer get remoteId {
    final $$RemoteSettingsTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.remoteId,
        referencedTable: $db.remoteSettings,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$RemoteSettingsTableOrderingComposer(
              $db: $db,
              $table: $db.remoteSettings,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$RemoteSyncStateTableAnnotationComposer
    extends Composer<_$SyncDatabase, $RemoteSyncStateTable> {
  $$RemoteSyncStateTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get etag =>
      $composableBuilder(column: $table.etag, builder: (column) => column);

  GeneratedColumn<int> get lastSyncedAt => $composableBuilder(
      column: $table.lastSyncedAt, builder: (column) => column);

  $$SyncIrisTableAnnotationComposer get documentIriId {
    final $$SyncIrisTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.documentIriId,
        referencedTable: $db.syncIris,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncIrisTableAnnotationComposer(
              $db: $db,
              $table: $db.syncIris,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$RemoteSettingsTableAnnotationComposer get remoteId {
    final $$RemoteSettingsTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.remoteId,
        referencedTable: $db.remoteSettings,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$RemoteSettingsTableAnnotationComposer(
              $db: $db,
              $table: $db.remoteSettings,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$RemoteSyncStateTableTableManager extends RootTableManager<
    _$SyncDatabase,
    $RemoteSyncStateTable,
    RemoteSyncStateData,
    $$RemoteSyncStateTableFilterComposer,
    $$RemoteSyncStateTableOrderingComposer,
    $$RemoteSyncStateTableAnnotationComposer,
    $$RemoteSyncStateTableCreateCompanionBuilder,
    $$RemoteSyncStateTableUpdateCompanionBuilder,
    (RemoteSyncStateData, $$RemoteSyncStateTableReferences),
    RemoteSyncStateData,
    PrefetchHooks Function({bool documentIriId, bool remoteId})> {
  $$RemoteSyncStateTableTableManager(
      _$SyncDatabase db, $RemoteSyncStateTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RemoteSyncStateTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$RemoteSyncStateTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$RemoteSyncStateTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> documentIriId = const Value.absent(),
            Value<int> remoteId = const Value.absent(),
            Value<String?> etag = const Value.absent(),
            Value<int> lastSyncedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              RemoteSyncStateCompanion(
            documentIriId: documentIriId,
            remoteId: remoteId,
            etag: etag,
            lastSyncedAt: lastSyncedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required int documentIriId,
            required int remoteId,
            Value<String?> etag = const Value.absent(),
            Value<int> lastSyncedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              RemoteSyncStateCompanion.insert(
            documentIriId: documentIriId,
            remoteId: remoteId,
            etag: etag,
            lastSyncedAt: lastSyncedAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$RemoteSyncStateTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({documentIriId = false, remoteId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (documentIriId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.documentIriId,
                    referencedTable: $$RemoteSyncStateTableReferences
                        ._documentIriIdTable(db),
                    referencedColumn: $$RemoteSyncStateTableReferences
                        ._documentIriIdTable(db)
                        .id,
                  ) as T;
                }
                if (remoteId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.remoteId,
                    referencedTable:
                        $$RemoteSyncStateTableReferences._remoteIdTable(db),
                    referencedColumn:
                        $$RemoteSyncStateTableReferences._remoteIdTable(db).id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ));
}

typedef $$RemoteSyncStateTableProcessedTableManager = ProcessedTableManager<
    _$SyncDatabase,
    $RemoteSyncStateTable,
    RemoteSyncStateData,
    $$RemoteSyncStateTableFilterComposer,
    $$RemoteSyncStateTableOrderingComposer,
    $$RemoteSyncStateTableAnnotationComposer,
    $$RemoteSyncStateTableCreateCompanionBuilder,
    $$RemoteSyncStateTableUpdateCompanionBuilder,
    (RemoteSyncStateData, $$RemoteSyncStateTableReferences),
    RemoteSyncStateData,
    PrefetchHooks Function({bool documentIriId, bool remoteId})>;

class $SyncDatabaseManager {
  final _$SyncDatabase _db;
  $SyncDatabaseManager(this._db);
  $$SyncIrisTableTableManager get syncIris =>
      $$SyncIrisTableTableManager(_db, _db.syncIris);
  $$SyncDocumentsTableTableManager get syncDocuments =>
      $$SyncDocumentsTableTableManager(_db, _db.syncDocuments);
  $$SyncPropertyChangesTableTableManager get syncPropertyChanges =>
      $$SyncPropertyChangesTableTableManager(_db, _db.syncPropertyChanges);
  $$SyncSettingsTableTableManager get syncSettings =>
      $$SyncSettingsTableTableManager(_db, _db.syncSettings);
  $$IndexEntriesTableTableManager get indexEntries =>
      $$IndexEntriesTableTableManager(_db, _db.indexEntries);
  $$GroupIndexSubscriptionsTableTableManager get groupIndexSubscriptions =>
      $$GroupIndexSubscriptionsTableTableManager(
          _db, _db.groupIndexSubscriptions);
  $$IndexIriIdSetVersionsTableTableManager get indexIriIdSetVersions =>
      $$IndexIriIdSetVersionsTableTableManager(_db, _db.indexIriIdSetVersions);
  $$RemoteSettingsTableTableManager get remoteSettings =>
      $$RemoteSettingsTableTableManager(_db, _db.remoteSettings);
  $$RemoteSyncStateTableTableManager get remoteSyncState =>
      $$RemoteSyncStateTableTableManager(_db, _db.remoteSyncState);
}
