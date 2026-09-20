/// The derived registry: the spine every later stage reads.
///
/// `docs/architecture.md` §2 and §11: discovery turns the backend's OpenAPI
/// document into this model, the online resolver projects it into tool schemas
/// and the offline resolver matches against it. Nothing downstream may invent a
/// path, verb or field name this model does not carry (`FR-MA03`).
///
/// The model is immutable and round-trips through JSON, because T4 persists
/// [ApiRegistry.toJson] as `registry.derived_json` and must load it back into
/// the identical structure.
library;

/// One callable operation: `path` × `method`.
class ApiOperation {
  const ApiOperation({
    required this.key,
    required this.operationId,
    required this.method,
    required this.path,
    required this.pathParameters,
    required this.requestBody,
    required this.requestBodyRequired,
    required this.responseSchema,
  });

  /// Identity of the operation, and never the generator's `operationId`.
  ///
  /// `"<METHOD> <path template>"`, e.g. `GET /api/cliente/{id}`. springdoc
  /// deduplicates `operationId` with an unstable numeric suffix (`create_6`),
  /// so it changes whenever the diagram changes; the path and verb do not.
  final String key;

  /// The generator's own identifier, carried because `FR-MA03` asks for it and
  /// the online resolver's tool schemas may surface it. It is evidence, not
  /// identity.
  final String? operationId;

  /// Upper-case HTTP verb as declared by the document.
  final String method;

  /// The path template, exactly as the document spells it, parameters included.
  final String path;

  /// Declared path parameters only, in document order.
  final List<ParameterDescriptor> pathParameters;

  /// The request body schema, or null when the operation takes no body.
  final SchemaDescriptor? requestBody;

  /// Whether the document marks the body itself as required.
  final bool requestBodyRequired;

  /// The schema of the first successful response content type, or null when
  /// the operation declares no response schema (e.g. `204 No Content`).
  final SchemaDescriptor? responseSchema;

  /// The path parameters as `{name: value}` names, in document order.
  List<String> get pathParameterNames =>
      pathParameters.map((parameter) => parameter.name).toList();

  Map<String, Object?> toJson() => <String, Object?>{
    'key': key,
    'operationId': operationId,
    'method': method,
    'path': path,
    'pathParameters': pathParameters
        .map((parameter) => parameter.toJson())
        .toList(),
    'requestBody': requestBody?.toJson(),
    'requestBodyRequired': requestBodyRequired,
    'responseSchema': responseSchema?.toJson(),
  };

  factory ApiOperation.fromJson(Map<String, Object?> json) => ApiOperation(
    key: _string(json['key']) ?? '',
    operationId: _string(json['operationId']),
    method: _string(json['method']) ?? '',
    path: _string(json['path']) ?? '',
    pathParameters: _objects(
      json['pathParameters'],
    ).map(ParameterDescriptor.fromJson).toList(),
    requestBody: _map(json['requestBody']) == null
        ? null
        : SchemaDescriptor.fromJson(_map(json['requestBody'])!),
    requestBodyRequired: _bool(json['requestBodyRequired']) ?? false,
    responseSchema: _map(json['responseSchema']) == null
        ? null
        : SchemaDescriptor.fromJson(_map(json['responseSchema'])!),
  );
}

/// One declared operation parameter that lives in the path template.
class ParameterDescriptor {
  const ParameterDescriptor({
    required this.name,
    required this.type,
    required this.format,
    required this.required,
  });

  final String name;

  /// The declared JSON type, e.g. `integer`, or `unknown` when the document
  /// declares none.
  final String type;

  /// The declared `format`, e.g. `int64`, or null.
  final String? format;

  final bool required;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'type': type,
    'format': format,
    'required': required,
  };

  factory ParameterDescriptor.fromJson(Map<String, Object?> json) =>
      ParameterDescriptor(
        name: _string(json['name']) ?? '',
        type: _string(json['type']) ?? 'unknown',
        format: _string(json['format']),
        required: _bool(json['required']) ?? false,
      );
}

/// A field of a schema, in the order the document declares it.
class FieldDescriptor {
  const FieldDescriptor({
    required this.name,
    required this.type,
    this.format,
    this.itemsType,
    this.itemsFormat,
  });

  final String name;

  /// The declared JSON type, the referenced schema name for a `$ref` field, or
  /// `unknown` when the document declares neither.
  final String type;

  final String? format;

  /// Element type of an array field, or null when the field is not an array.
  final String? itemsType;

  /// Element format of an array field, or null.
  final String? itemsFormat;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'type': type,
    'format': format,
    'itemsType': itemsType,
    'itemsFormat': itemsFormat,
  };

  factory FieldDescriptor.fromJson(Map<String, Object?> json) =>
      FieldDescriptor(
        name: _string(json['name']) ?? '',
        type: _string(json['type']) ?? 'unknown',
        format: _string(json['format']),
        itemsType: _string(json['itemsType']),
        itemsFormat: _string(json['itemsFormat']),
      );
}

/// A resolved schema: what the document declares about a request body or a
/// response, after every local `$ref` has been followed.
class SchemaDescriptor {
  const SchemaDescriptor({
    required this.name,
    required this.type,
    required this.format,
    required this.fields,
    required this.required,
    this.items,
  });

  /// The component name the schema was reached through, e.g. `DirecciónRequest`
  /// — the un-folded original spelling survives here even when the route was
  /// folded to ASCII (`FR-MC07`). Null for an inline schema.
  final String? name;

  /// The declared JSON type, `object` when properties imply it, or null.
  final String? type;

  final String? format;

  /// Properties in schema declaration order. This order is the slot-filling
  /// order of `FR-MC02`.
  final List<FieldDescriptor> fields;

  /// The `required` array in the order the document declares it. Request
  /// schemas carry it; response schemas usually do not.
  final List<String> required;

  /// Element schema of an array schema, or null.
  final SchemaDescriptor? items;

  /// The required fields as descriptors, in property declaration order.
  ///
  /// A `required` name with no matching property is dropped here and recorded
  /// as a diagnostic by the parser, never invented as a field.
  List<FieldDescriptor> get requiredFields {
    final requiredNames = required.toSet();
    return fields
        .where((field) => requiredNames.contains(field.name))
        .toList();
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'type': type,
    'format': format,
    'fields': fields.map((field) => field.toJson()).toList(),
    'required': required,
    'items': items?.toJson(),
  };

  factory SchemaDescriptor.fromJson(Map<String, Object?> json) {
    final items = _map(json['items']);
    return SchemaDescriptor(
      name: _string(json['name']),
      type: _string(json['type']),
      format: _string(json['format']),
      fields: _objects(json['fields']).map(FieldDescriptor.fromJson).toList(),
      required: _strings(json['required']),
      items: items == null ? null : SchemaDescriptor.fromJson(items),
    );
  }
}

/// The five callable roles a collection route can carry.
///
/// Derived from the verb plus whether the path carries parameters — never from
/// a hard-coded route or entity name.
enum EntityRole {
  /// `GET` on the collection route.
  list,

  /// `GET` on an item route.
  get,

  /// `POST` on the collection route.
  create,

  /// `PUT` on an item route.
  update,

  /// `DELETE` on an item route.
  delete,
}

/// One entity the backend exposes: a collection route and what it can do.
class EntityModel {
  const EntityModel({
    required this.name,
    required this.collectionRoute,
    required this.operationKeys,
    required this.roleKeys,
    required this.readableFields,
    required this.requiredWritableFields,
  });

  /// The un-folded domain name recovered from the schema `$ref` the operations
  /// reference, e.g. `Dirección` for the route `/api/direccion` (`FR-MC07`).
  final String name;

  /// The route all of this entity's operations hang off, e.g. `/api/direccion`.
  final String collectionRoute;

  /// Every operation key of the entity, in document order.
  final List<String> operationKeys;

  /// The operation key per role, for the roles the backend actually publishes.
  final Map<EntityRole, String> roleKeys;

  /// The record's readable fields, in response schema order. Read-only
  /// projections — `id`, and inverse relations such as `citaIds` — live here
  /// and are never writable.
  final List<FieldDescriptor> readableFields;

  /// The request body's required fields, in schema order: the array that makes
  /// slot filling possible (`FR-MC02`).
  final List<FieldDescriptor> requiredWritableFields;

  /// The `GET`-collection operation key, or null when it is absent.
  String? get listOperationKey => roleKeys[EntityRole.list];

  /// The `GET`-item operation key, or null when it is absent.
  String? get getOperationKey => roleKeys[EntityRole.get];

  /// The `POST`-collection operation key, or null when it is absent.
  String? get createOperationKey => roleKeys[EntityRole.create];

  /// The `PUT`-item operation key, or null when it is absent.
  String? get updateOperationKey => roleKeys[EntityRole.update];

  /// The `DELETE`-item operation key, or null when it is absent.
  String? get deleteOperationKey => roleKeys[EntityRole.delete];

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'collectionRoute': collectionRoute,
    'operationKeys': operationKeys,
    'roleKeys': <String, Object?>{
      for (final role in EntityRole.values)
        if (roleKeys[role] != null) role.name: roleKeys[role],
    },
    'readableFields': readableFields
        .map((field) => field.toJson())
        .toList(),
    'requiredWritableFields': requiredWritableFields
        .map((field) => field.toJson())
        .toList(),
  };

  factory EntityModel.fromJson(Map<String, Object?> json) {
    final rawRoles = _map(json['roleKeys']) ?? const <String, Object?>{};
    final roleKeys = <EntityRole, String>{};
    for (final role in EntityRole.values) {
      final key = _string(rawRoles[role.name]);
      if (key != null) roleKeys[role] = key;
    }
    return EntityModel(
      name: _string(json['name']) ?? '',
      collectionRoute: _string(json['collectionRoute']) ?? '',
      operationKeys: _strings(json['operationKeys']),
      roleKeys: roleKeys,
      readableFields: _objects(
        json['readableFields'],
      ).map(FieldDescriptor.fromJson).toList(),
      requiredWritableFields: _objects(
        json['requiredWritableFields'],
      ).map(FieldDescriptor.fromJson).toList(),
    );
  }
}

/// A recorded parse problem: the parser never crashes and never stays silent.
///
/// `code` is stable and machine-readable; `message` is for logs and technical
/// mode, never for a default-visible surface.
class RegistryDiagnostic {
  const RegistryDiagnostic({
    required this.code,
    required this.message,
    this.path,
    this.method,
  });

  final String code;
  final String message;

  /// The path template the problem belongs to, when it belongs to one.
  final String? path;

  /// The verb the problem belongs to, when it belongs to one.
  final String? method;

  Map<String, Object?> toJson() => <String, Object?>{
    'code': code,
    'message': message,
    'path': path,
    'method': method,
  };

  factory RegistryDiagnostic.fromJson(Map<String, Object?> json) =>
      RegistryDiagnostic(
        code: _string(json['code']) ?? '',
        message: _string(json['message']) ?? '',
        path: _string(json['path']),
        method: _string(json['method']),
      );
}

/// The whole derived registry for one backend description.
class ApiRegistry {
  const ApiRegistry({
    required this.openapiVersion,
    required this.documentHash,
    required this.pathCount,
    required this.operations,
    required this.entities,
    required this.diagnostics,
  });

  /// The `openapi` field of the document, e.g. `3.1.0`.
  final String? openapiVersion;

  /// SHA-256 of the raw document bytes, lowercase hex. T4 compares it to detect
  /// change (`FR-MA07`).
  final String documentHash;

  /// How many path templates the document declares, including one with no
  /// operations.
  final int pathCount;

  /// Every derived operation, in document order.
  final List<ApiOperation> operations;

  /// Every derived entity, in first-seen document order.
  final List<EntityModel> entities;

  /// Everything the parser could not understand or resolve.
  final List<RegistryDiagnostic> diagnostics;

  /// True when the backend publishes no operation at all.
  ///
  /// Not an error: a diagram with no classes describes no endpoints, and the
  /// UX has its own sentence for it (Pass 6).
  bool get isEmpty => operations.isEmpty;

  /// Looks an operation up by its key.
  ApiOperation? operation(String key) {
    for (final operation in operations) {
      if (operation.key == key) return operation;
    }
    return null;
  }

  /// Looks an entity up by its recovered domain name.
  EntityModel? entity(String name) {
    for (final entity in entities) {
      if (entity.name == name) return entity;
    }
    return null;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'openapiVersion': openapiVersion,
    'documentHash': documentHash,
    'pathCount': pathCount,
    'operations': operations.map((operation) => operation.toJson()).toList(),
    'entities': entities.map((entity) => entity.toJson()).toList(),
    'diagnostics': diagnostics
        .map((diagnostic) => diagnostic.toJson())
        .toList(),
  };

  factory ApiRegistry.fromJson(Map<String, Object?> json) => ApiRegistry(
    openapiVersion: _string(json['openapiVersion']),
    documentHash: _string(json['documentHash']) ?? '',
    pathCount: _int(json['pathCount']) ?? 0,
    operations: _objects(
      json['operations'],
    ).map(ApiOperation.fromJson).toList(),
    entities: _objects(json['entities']).map(EntityModel.fromJson).toList(),
    diagnostics: _objects(
      json['diagnostics'],
    ).map(RegistryDiagnostic.fromJson).toList(),
  );
}

// Decoding helpers. Persisted JSON comes back as `Map<String, dynamic>`; these
// keep [fromJson] total instead of throwing on an unexpected shape, because a
// corrupt row is diagnosed by its empty result and not by a crash.
Map<String, Object?>? _map(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
  return null;
}

List<Map<String, Object?>> _objects(Object? value) {
  if (value is! List) return const <Map<String, Object?>>[];
  final result = <Map<String, Object?>>[];
  for (final item in value) {
    final map = _map(item);
    if (map != null) result.add(map);
  }
  return result;
}

String? _string(Object? value) => value is String ? value : null;

int? _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}

bool? _bool(Object? value) => value is bool ? value : null;

List<String> _strings(Object? value) {
  if (value is! List) return <String>[];
  return value.whereType<String>().toList();
}
