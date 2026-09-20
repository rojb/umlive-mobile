import 'dart:convert';

import '../core/sha256.dart';
import 'registry.dart';

/// The result of turning a document into a registry.
class RegistryParseResult {
  const RegistryParseResult({
    required this.registry,
    required this.documentJson,
    required this.elapsedMs,
  });

  final ApiRegistry registry;

  /// The document as text, for `registry.document_json` (T4). Empty when the
  /// bytes were not valid UTF-8.
  final String documentJson;

  /// Wall time of the parse, for the `[umlive][registry]` summary line.
  final int elapsedMs;
}

/// Stable diagnostic codes. They are persisted by T4, so they are names, not
/// sentences, and they do not change when the wording does.
abstract final class DiagnosticCode {
  static const String documentUnreadable = 'documentUnreadable';
  static const String documentRootNotObject = 'documentRootNotObject';
  static const String missingOpenapiVersion = 'missingOpenapiVersion';
  static const String unsupportedOpenapiVersion = 'unsupportedOpenapiVersion';
  static const String pathsNotObject = 'pathsNotObject';
  static const String pathKeyNotTemplate = 'pathKeyNotTemplate';
  static const String pathItemNotObject = 'pathItemNotObject';
  static const String unknownPathItemKey = 'unknownPathItemKey';
  static const String pathWithoutOperations = 'pathWithoutOperations';
  static const String operationNotObject = 'operationNotObject';
  static const String malformedParameter = 'malformedParameter';
  static const String unresolvedRef = 'unresolvedRef';
  static const String malformedRequired = 'malformedRequired';
  static const String requiredFieldMissing = 'requiredFieldMissing';
  static const String malformedProperty = 'malformedProperty';
  static const String arrayWithoutItems = 'arrayWithoutItems';
  static const String unsupportedSchemaConstruct = 'unsupportedSchemaConstruct';
  static const String entityNameUnresolved = 'entityNameUnresolved';
}

/// Turns a raw OpenAPI document into the derived registry (`FR-MA03`).
///
/// Pure: no I/O, no copy, no logging. It is deliberately tolerant — an unknown
/// verb, an unsupported construct, a `$ref` that does not resolve and a path
/// with no operations each become a [RegistryDiagnostic] rather than an
/// exception or a silence. The one crash it cannot avoid is a bug, so the
/// document is read through total helpers instead of casts.
abstract final class RegistryParser {
  /// Reference marker inside a document, e.g. `#/components/schemas/Cliente`.
  static const String _refKey = r'$ref';

  /// The path-item keys that are structure, not operations. Anything else that
  /// is not a known verb is reported as an unknown verb.
  static const Set<String> _nonOperationKeys = <String>{
    'summary',
    'description',
    'servers',
    'parameters',
    _refKey,
  };

  /// Every HTTP verb OpenAPI 3.1 defines. They all become operations; only the
  /// five CRUD roles are classified into entities.
  static const Set<String> _verbs = <String>{
    'get',
    'put',
    'post',
    'delete',
    'options',
    'head',
    'patch',
    'trace',
  };

  /// Upper bound on the document the parser will look at, so a misbehaving
  /// backend cannot make the analysis unbounded.
  static const int maxDocumentBytes = 8 * 1024 * 1024;

  /// Parses [documentBytes] into a registry plus its SHA-256.
  static RegistryParseResult parse(List<int> documentBytes) {
    final stopwatch = Stopwatch()..start();
    final diagnostics = <RegistryDiagnostic>[];
    final hash = Sha256.hex(documentBytes);

    var documentJson = '';
    Map<String, Object?>? root;
    try {
      documentJson = utf8.decode(documentBytes);
      final decoded = jsonDecode(documentJson);
      if (decoded is Map<String, Object?>) {
        root = decoded;
      } else {
        diagnostics.add(
          const RegistryDiagnostic(
            code: DiagnosticCode.documentRootNotObject,
            message: 'The document does not decode to a JSON object.',
          ),
        );
      }
    } on Object catch (error) {
      diagnostics.add(
        RegistryDiagnostic(
          code: DiagnosticCode.documentUnreadable,
          message: 'The document is not readable UTF-8 JSON: $error',
        ),
      );
    }

    final operations = <ApiOperation>[];
    var pathCount = 0;
    String? version;

    if (root != null) {
      version = _asString(root['openapi']);
      if (version == null || version.isEmpty) {
        diagnostics.add(
          const RegistryDiagnostic(
            code: DiagnosticCode.missingOpenapiVersion,
            message: 'The document declares no openapi version.',
          ),
        );
      } else if (!version.startsWith('3.')) {
        diagnostics.add(
          RegistryDiagnostic(
            code: DiagnosticCode.unsupportedOpenapiVersion,
            message: 'The document declares openapi $version, not 3.1.',
          ),
        );
      }

      pathCount = _readPaths(root, operations, diagnostics);
    }

    final entities = _buildEntities(operations, diagnostics);
    stopwatch.stop();

    return RegistryParseResult(
      registry: ApiRegistry(
        openapiVersion: version,
        documentHash: hash,
        pathCount: pathCount,
        operations: operations,
        entities: entities,
        diagnostics: diagnostics,
      ),
      documentJson: documentJson,
      elapsedMs: stopwatch.elapsedMilliseconds,
    );
  }

  /// Walks `paths` and appends every operation it can derive. Returns how many
  /// path templates the document declares, operations or not.
  static int _readPaths(
    Map<String, Object?> root,
    List<ApiOperation> operations,
    List<RegistryDiagnostic> diagnostics,
  ) {
    final rawPathsValue = root['paths'];
    if (rawPathsValue == null) {
      // A document with no paths is not an error: the backend exposes no
      // operations, and Pass 6 gives that its own sentence.
      return 0;
    }
    final rawPaths = _asMap(rawPathsValue);
    if (rawPaths == null) {
      diagnostics.add(
        const RegistryDiagnostic(
          code: DiagnosticCode.pathsNotObject,
          message: 'The paths member is not an object.',
        ),
      );
      return 0;
    }

    var pathCount = 0;
    for (final entry in rawPaths.entries) {
      final path = entry.key;
      if (!path.startsWith('/')) {
        diagnostics.add(
          RegistryDiagnostic(
            code: DiagnosticCode.pathKeyNotTemplate,
            message: 'A paths key is not a path template.',
            path: path,
          ),
        );
        continue;
      }
      pathCount++;

      final pathItem = _asMap(entry.value);
      if (pathItem == null) {
        diagnostics.add(
          RegistryDiagnostic(
            code: DiagnosticCode.pathItemNotObject,
            message: 'This path declares no path item object.',
            path: path,
          ),
        );
        continue;
      }

      var operationsHere = 0;
      for (final operationEntry in pathItem.entries) {
        final verb = operationEntry.key.toLowerCase();
        if (_verbs.contains(verb)) {
          final operation = _readOperation(
            path: path,
            method: verb,
            raw: operationEntry.value,
            root: root,
            diagnostics: diagnostics,
          );
          if (operation != null) {
            operations.add(operation);
            operationsHere++;
          }
          continue;
        }
        if (_nonOperationKeys.contains(operationEntry.key) ||
            operationEntry.key.startsWith('x-')) {
          continue;
        }
        diagnostics.add(
          RegistryDiagnostic(
            code: DiagnosticCode.unknownPathItemKey,
            message: 'The path declares an unknown verb.',
            path: path,
            method: operationEntry.key,
          ),
        );
      }

      if (operationsHere == 0) {
        diagnostics.add(
          RegistryDiagnostic(
            code: DiagnosticCode.pathWithoutOperations,
            message: 'This path declares no operation.',
            path: path,
          ),
        );
      }
    }
    return pathCount;
  }

  static ApiOperation? _readOperation({
    required String path,
    required String method,
    required Object? raw,
    required Map<String, Object?> root,
    required List<RegistryDiagnostic> diagnostics,
  }) {
    final operation = _asMap(raw);
    if (operation == null) {
      diagnostics.add(
        RegistryDiagnostic(
          code: DiagnosticCode.operationNotObject,
          message: 'The operation is not an object.',
          path: path,
          method: method,
        ),
      );
      return null;
    }

    final pathParameters = _readPathParameters(
      operation['parameters'],
      root: root,
      path: path,
      method: method,
      diagnostics: diagnostics,
    );

    final rawBody = _asMap(operation['requestBody']);
    final requestBody = rawBody == null
        ? null
        : _firstSchemaOf(
            rawBody['content'],
            root: root,
            path: path,
            method: method,
            diagnostics: diagnostics,
          );

    return ApiOperation(
      key: '${method.toUpperCase()} $path',
      operationId: _asString(operation['operationId']),
      method: method.toUpperCase(),
      path: path,
      pathParameters: pathParameters,
      requestBody: requestBody,
      requestBodyRequired: _asBool(rawBody?['required']) ?? false,
      responseSchema: _readResponse(
        operation['responses'],
        root: root,
        path: path,
        method: method,
        diagnostics: diagnostics,
      ),
    );
  }

  static List<ParameterDescriptor> _readPathParameters(
    Object? raw, {
    required Map<String, Object?> root,
    required String path,
    required String method,
    required List<RegistryDiagnostic> diagnostics,
  }) {
    final parameters = <ParameterDescriptor>[];
    if (raw == null) return parameters;
    if (raw is! List) {
      diagnostics.add(
        RegistryDiagnostic(
          code: DiagnosticCode.malformedParameter,
          message: 'The parameters member is not an array.',
          path: path,
          method: method,
        ),
      );
      return parameters;
    }

    for (final item in raw) {
      final parameter = _asMap(item);
      if (parameter == null) {
        diagnostics.add(
          RegistryDiagnostic(
            code: DiagnosticCode.malformedParameter,
            message: 'A parameter is not an object.',
            path: path,
            method: method,
          ),
        );
        continue;
      }
      // Only path parameters are part of the registry: they are the ones the
      // executor has to substitute. Query and header parameters are a
      // supported construct this task does not model, not an error.
      if (_asString(parameter['in']) != 'path') continue;

      final name = _asString(parameter['name']);
      if (name == null || name.isEmpty) {
        diagnostics.add(
          RegistryDiagnostic(
            code: DiagnosticCode.malformedParameter,
            message: 'A path parameter declares no name.',
            path: path,
            method: method,
          ),
        );
        continue;
      }

      final schema = _asMap(parameter['schema']);
      final resolved = schema == null
          ? null
          : _resolveSchema(
              schema,
              root: root,
              path: path,
              method: method,
              diagnostics: diagnostics,
            );
      parameters.add(
        ParameterDescriptor(
          name: name,
          type: resolved?.type ?? 'unknown',
          format: resolved?.format,
          required: _asBool(parameter['required']) ?? false,
        ),
      );
    }
    return parameters;
  }

  static SchemaDescriptor? _readResponse(
    Object? raw, {
    required Map<String, Object?> root,
    required String path,
    required String method,
    required List<RegistryDiagnostic> diagnostics,
  }) {
    final responses = _asMap(raw);
    if (responses == null) return null;

    SchemaDescriptor? firstSchema(Iterable<MapEntry<String, Object?>> entries) {
      for (final entry in entries) {
        final response = _asMap(entry.value);
        if (response == null) continue;
        final schema = _firstSchemaOf(
          response['content'],
          root: root,
          path: path,
          method: method,
          diagnostics: diagnostics,
        );
        if (schema != null) return schema;
      }
      return null;
    }

    final success = responses.entries.where(
      (entry) => entry.key.startsWith('2'),
    );
    return firstSchema(success) ?? firstSchema(responses.entries);
  }

  /// Scans every declared content type, in document order, and resolves the
  /// first schema it finds.
  ///
  /// The generated backend declares response bodies under `*/*` and request
  /// bodies under `application/json`, so assuming one content type would lose
  /// every response schema.
  static SchemaDescriptor? _firstSchemaOf(
    Object? rawContent, {
    required Map<String, Object?> root,
    required String path,
    required String method,
    required List<RegistryDiagnostic> diagnostics,
  }) {
    final content = _asMap(rawContent);
    if (content == null) return null;
    for (final media in content.values) {
      final mediaType = _asMap(media);
      if (mediaType == null) continue;
      final schema = _asMap(mediaType['schema']);
      if (schema == null) continue;
      final resolved = _resolveSchema(
        schema,
        root: root,
        path: path,
        method: method,
        diagnostics: diagnostics,
      );
      if (resolved != null) return resolved;
    }
    return null;
  }

  /// Resolves a schema, following one local `$ref` at its head.
  static SchemaDescriptor? _resolveSchema(
    Map<String, Object?> schema, {
    required Map<String, Object?> root,
    required String path,
    required String method,
    required List<RegistryDiagnostic> diagnostics,
  }) {
    final ref = _asString(schema[_refKey]);
    if (ref == null) {
      return _describeSchema(
        schema,
        name: null,
        root: root,
        path: path,
        method: method,
        diagnostics: diagnostics,
      );
    }

    final target = _resolveRef(ref, root);
    if (target == null) {
      diagnostics.add(
        RegistryDiagnostic(
          code: DiagnosticCode.unresolvedRef,
          message: 'The reference $ref does not resolve in this document.',
          path: path,
          method: method,
        ),
      );
      return null;
    }
    return _describeSchema(
      target,
      name: _refName(ref),
      root: root,
      path: path,
      method: method,
      diagnostics: diagnostics,
    );
  }

  static SchemaDescriptor _describeSchema(
    Map<String, Object?> schema, {
    required String? name,
    required Map<String, Object?> root,
    required String path,
    required String method,
    required List<RegistryDiagnostic> diagnostics,
  }) {
    final fields = <FieldDescriptor>[];
    final rawPropertiesValue = schema['properties'];
    final rawProperties = _asMap(rawPropertiesValue);
    if (rawPropertiesValue != null && rawProperties == null) {
      diagnostics.add(
        RegistryDiagnostic(
          code: DiagnosticCode.malformedProperty,
          message: 'The properties member is not an object.',
          path: path,
          method: method,
        ),
      );
    } else if (rawProperties != null) {
      for (final property in rawProperties.entries) {
        fields.add(
          _describeField(
            property.key,
            property.value,
            root: root,
            path: path,
            method: method,
            diagnostics: diagnostics,
          ),
        );
      }
    }

    final required = <String>[];
    final rawRequired = schema['required'];
    if (rawRequired is List) {
      for (final item in rawRequired) {
        if (item is String && item.isNotEmpty) {
          required.add(item);
        } else {
          diagnostics.add(
            RegistryDiagnostic(
              code: DiagnosticCode.malformedRequired,
              message: 'A required entry is not a field name.',
              path: path,
              method: method,
            ),
          );
        }
      }
    } else if (rawRequired != null) {
      diagnostics.add(
        RegistryDiagnostic(
          code: DiagnosticCode.malformedRequired,
          message: 'The required member is not an array.',
          path: path,
          method: method,
        ),
      );
    }
    for (final requiredName in required) {
      if (!fields.any((field) => field.name == requiredName)) {
        diagnostics.add(
          RegistryDiagnostic(
            code: DiagnosticCode.requiredFieldMissing,
            message:
                'The required field $requiredName has no declared property.',
            path: path,
            method: method,
          ),
        );
      }
    }

    final declaredType = _asString(schema['type']);
    final type = declaredType ?? (fields.isEmpty ? null : 'object');
    SchemaDescriptor? items;
    if (type == 'array') {
      items = _arrayItems(
        schema['items'],
        root: root,
        path: path,
        method: method,
        diagnostics: diagnostics,
      );
    } else {
      _reportUnsupportedConstruct(
        schema,
        path: path,
        method: method,
        diagnostics: diagnostics,
      );
    }

    return SchemaDescriptor(
      name: name,
      type: type,
      format: _asString(schema['format']),
      fields: fields,
      required: required,
      items: items,
    );
  }

  static FieldDescriptor _describeField(
    String name,
    Object? raw, {
    required Map<String, Object?> root,
    required String path,
    required String method,
    required List<RegistryDiagnostic> diagnostics,
  }) {
    final property = _asMap(raw);
    if (property == null) {
      diagnostics.add(
        RegistryDiagnostic(
          code: DiagnosticCode.malformedProperty,
          message: 'The property $name is not an object.',
          path: path,
          method: method,
        ),
      );
      return FieldDescriptor(name: name, type: 'unknown');
    }

    final ref = _asString(property[_refKey]);
    var schema = property;
    if (ref != null) {
      final target = _resolveRef(ref, root);
      if (target == null) {
        diagnostics.add(
          RegistryDiagnostic(
            code: DiagnosticCode.unresolvedRef,
            message: 'The reference $ref of $name does not resolve.',
            path: path,
            method: method,
          ),
        );
      } else {
        schema = target;
      }
    }

    final declaredType = _asString(schema['type']);
    final resolvedType =
        declaredType ?? (ref != null ? _refName(ref) : 'unknown');

    String? itemsType;
    String? itemsFormat;
    if (resolvedType == 'array') {
      final items = _arrayItems(
        schema['items'],
        root: root,
        path: path,
        method: method,
        diagnostics: diagnostics,
      );
      itemsType = items?.name ?? items?.type ?? 'unknown';
      itemsFormat = items?.format;
    }

    return FieldDescriptor(
      name: name,
      type: resolvedType,
      format: _asString(schema['format']),
      itemsType: itemsType,
      itemsFormat: itemsFormat,
    );
  }

  static SchemaDescriptor? _arrayItems(
    Object? raw, {
    required Map<String, Object?> root,
    required String path,
    required String method,
    required List<RegistryDiagnostic> diagnostics,
  }) {
    final items = _asMap(raw);
    if (items == null) {
      diagnostics.add(
        RegistryDiagnostic(
          code: DiagnosticCode.arrayWithoutItems,
          message: 'An array schema declares no items.',
          path: path,
          method: method,
        ),
      );
      return null;
    }
    return _resolveSchema(
      items,
      root: root,
      path: path,
      method: method,
      diagnostics: diagnostics,
    );
  }

  /// Composition keywords this task does not flatten. They are reported once
  /// per schema so the registry is honest about what it did not read.
  static const Set<String> _unsupportedComposition = <String>{
    'allOf',
    'oneOf',
    'anyOf',
    'not',
    'if',
    'then',
    'else',
  };

  static void _reportUnsupportedConstruct(
    Map<String, Object?> schema, {
    required String path,
    required String method,
    required List<RegistryDiagnostic> diagnostics,
  }) {
    for (final keyword in _unsupportedComposition) {
      if (schema.containsKey(keyword)) {
        diagnostics.add(
          RegistryDiagnostic(
            code: DiagnosticCode.unsupportedSchemaConstruct,
            message: 'The schema composes with $keyword, which is not read.',
            path: path,
            method: method,
          ),
        );
        return;
      }
    }
  }

  /// Follows a local reference such as `#/components/schemas/ClienteRequest`.
  /// External references are not fetched, so they do not resolve.
  static Map<String, Object?>? _resolveRef(
    String ref,
    Map<String, Object?> root,
  ) {
    if (!ref.startsWith('#')) return null;
    Object? current = root;
    for (final rawSegment in ref.substring(1).split('/')) {
      if (rawSegment.isEmpty) continue;
      final segment = rawSegment.replaceAll('~1', '/').replaceAll('~0', '~');
      if (current is Map<String, Object?>) {
        current = current[segment];
      } else if (current is List) {
        final index = int.tryParse(segment);
        if (index == null || index < 0 || index >= current.length) return null;
        current = current[index];
      } else {
        return null;
      }
    }
    return current is Map<String, Object?> ? current : null;
  }

  /// The last segment of a reference, unescaped: the component name.
  static String _refName(String ref) {
    final segments = ref.split('/');
    return segments.last.replaceAll('~1', '/').replaceAll('~0', '~');
  }

  /// Groups operations into entities by collection route.
  ///
  /// Nothing here knows the word `cliente`: the collection route is whatever
  /// remains after stripping trailing path-parameter segments, and the role is
  /// the verb plus whether the path carries parameters.
  static List<EntityModel> _buildEntities(
    List<ApiOperation> operations,
    List<RegistryDiagnostic> diagnostics,
  ) {
    final groups = <String, List<ApiOperation>>{};
    for (final operation in operations) {
      groups
          .putIfAbsent(collectionRouteOf(operation.path), () => <ApiOperation>[])
          .add(operation);
    }

    final entities = <EntityModel>[];
    for (final group in groups.entries) {
      entities.add(_buildEntity(group.key, group.value, diagnostics));
    }
    return entities;
  }

  static EntityModel _buildEntity(
    String collectionRoute,
    List<ApiOperation> operations,
    List<RegistryDiagnostic> diagnostics,
  ) {
    final roleKeys = <EntityRole, String>{};
    for (final operation in operations) {
      final role = roleOf(
        operation.method,
        isItem: operation.path != collectionRoute,
      );
      if (role != null) roleKeys.putIfAbsent(role, () => operation.key);
    }

    // The record schema is the item read when it exists, otherwise the element
    // of the collection read. It is the readable projection: `id` and inverse
    // relations are only ever here.
    final record = _readSchemaFor(roleKeys, operations, EntityRole.get) ??
        _listElementSchema(roleKeys, operations);
    final writable = _requestSchemaFor(roleKeys, operations, EntityRole.create) ??
        _requestSchemaFor(roleKeys, operations, EntityRole.update);

    final schemaNames = <String>[];
    for (final operation in operations) {
      final body = operation.requestBody?.name;
      if (body != null && !schemaNames.contains(body)) schemaNames.add(body);
      final response = operation.responseSchema?.name;
      if (response != null && !schemaNames.contains(response)) {
        schemaNames.add(response);
      }
      final element = operation.responseSchema?.items?.name;
      if (element != null && !schemaNames.contains(element)) {
        schemaNames.add(element);
      }
    }

    final name = _entityName(schemaNames, collectionRoute);
    if (schemaNames.isEmpty) {
      diagnostics.add(
        RegistryDiagnostic(
          code: DiagnosticCode.entityNameUnresolved,
          message:
              'The entity name was taken from the route: no schema reference '
              'carries it.',
          path: collectionRoute,
        ),
      );
    }

    return EntityModel(
      name: name,
      collectionRoute: collectionRoute,
      operationKeys: operations.map((operation) => operation.key).toList(),
      roleKeys: roleKeys,
      readableFields: record?.fields ?? const <FieldDescriptor>[],
      requiredWritableFields:
          writable?.requiredFields ?? const <FieldDescriptor>[],
    );
  }

  static SchemaDescriptor? _readSchemaFor(
    Map<EntityRole, String> roleKeys,
    List<ApiOperation> operations,
    EntityRole role,
  ) {
    final key = roleKeys[role];
    if (key == null) return null;
    for (final operation in operations) {
      if (operation.key == key) return operation.responseSchema;
    }
    return null;
  }

  static SchemaDescriptor? _listElementSchema(
    Map<EntityRole, String> roleKeys,
    List<ApiOperation> operations,
  ) {
    final schema = _readSchemaFor(roleKeys, operations, EntityRole.list);
    if (schema == null) return null;
    // A collection read answers with an array; the entity's fields are the
    // element's fields, not the array's.
    return schema.type == 'array' ? schema.items : schema;
  }

  static SchemaDescriptor? _requestSchemaFor(
    Map<EntityRole, String> roleKeys,
    List<ApiOperation> operations,
    EntityRole role,
  ) {
    final key = roleKeys[role];
    if (key == null) return null;
    for (final operation in operations) {
      if (operation.key == key) return operation.requestBody;
    }
    return null;
  }

  /// The collection route of [path]: the path with its trailing parameter
  /// segments removed.
  static String collectionRouteOf(String path) {
    final segments = path.split('/');
    var end = segments.length;
    while (end > 0 && _isParameterSegment(segments[end - 1])) {
      end--;
    }
    final trimmed = segments.sublist(0, end).join('/');
    return trimmed.isEmpty ? '/' : trimmed;
  }

  /// The role a verb plays on a route, or null when it plays none of the five.
  static EntityRole? roleOf(String method, {required bool isItem}) {
    switch (method.toUpperCase()) {
      case 'GET':
        return isItem ? EntityRole.get : EntityRole.list;
      case 'POST':
        return isItem ? null : EntityRole.create;
      case 'PUT':
        return isItem ? EntityRole.update : null;
      case 'DELETE':
        return isItem ? EntityRole.delete : null;
      default:
        return null;
    }
  }

  static bool _isParameterSegment(String segment) =>
      segment.length >= 2 && segment.startsWith('{') && segment.endsWith('}');

  /// Recovers the un-folded domain name from the schema references.
  ///
  /// `DirecciónRequest` and `DirecciónResponse` both fold to the ASCII route
  /// word `direccion`, and that agreement is what confirms the name `Dirección`
  /// — the generator emits no extension that would carry it (`FR-MC07`). The
  /// comparison is generic: it folds the candidate and the route word, and
  /// drops trailing camel-case tokens until they agree, so no domain word and
  /// no generator suffix is ever hard-coded here.
  static String _entityName(List<String> schemaNames, String collectionRoute) {
    final tokenLists = <List<String>>[];
    for (final schemaName in schemaNames) {
      final tokens = _camelTokens(schemaName);
      if (tokens.isNotEmpty) tokenLists.add(tokens);
    }
    if (tokenLists.isEmpty) return _routeWord(collectionRoute);

    var common = tokenLists.first;
    for (final tokens in tokenLists.skip(1)) {
      var length = 0;
      while (length < common.length &&
          length < tokens.length &&
          common[length] == tokens[length]) {
        length++;
      }
      common = common.sublist(0, length);
      if (common.isEmpty) break;
    }

    final routeWord = _fold(_routeWord(collectionRoute));
    if (routeWord.isNotEmpty) {
      for (var length = common.length; length >= 1; length--) {
        final candidate = common.sublist(0, length).join();
        if (_fold(candidate) == routeWord) return candidate;
      }
    }
    return common.isEmpty ? _routeWord(collectionRoute) : common.join();
  }

  /// The last non-empty segment of a collection route, e.g. `direccion`.
  static String _routeWord(String collectionRoute) {
    final segments = collectionRoute
        .split('/')
        .where((segment) => segment.isNotEmpty);
    return segments.isEmpty ? collectionRoute : segments.last;
  }

  /// Splits a name at camel-case boundaries: `DirecciónRequest` becomes
  /// `[Dirección, Request]`, `ItemPedidoResponse` becomes
  /// `[Item, Pedido, Response]`.
  static List<String> _camelTokens(String name) {
    final tokens = <String>[];
    final buffer = StringBuffer();
    for (var i = 0; i < name.length; i++) {
      final character = name[i];
      if (i > 0 && _isUpper(character) && !_isUpper(name[i - 1])) {
        tokens.add(buffer.toString());
        buffer.clear();
      }
      buffer.write(character);
    }
    if (buffer.isNotEmpty) tokens.add(buffer.toString());
    return tokens;
  }

  static bool _isUpper(String character) =>
      character.toUpperCase() == character &&
      character.toLowerCase() != character;

  /// Folds a word to ASCII, lower-case, alphanumerics only: `Dirección` and
  /// `direccion` both become `direccion`, `ItemPedido` and `item-pedido` both
  /// become `itempedido`.
  static String _fold(String value) {
    final buffer = StringBuffer();
    for (final rune in value.toLowerCase().runes) {
      final character = String.fromCharCode(rune);
      final folded = _accents[character];
      if (folded != null) {
        buffer.write(folded);
      } else if (_alphanumeric.hasMatch(character)) {
        buffer.write(character);
      }
    }
    return buffer.toString();
  }

  static final RegExp _alphanumeric = RegExp(r'[a-z0-9]');

  static const Map<String, String> _accents = <String, String>{
    'á': 'a', 'à': 'a', 'ä': 'a', 'â': 'a', 'ã': 'a',
    'é': 'e', 'è': 'e', 'ë': 'e', 'ê': 'e',
    'í': 'i', 'ì': 'i', 'ï': 'i', 'î': 'i',
    'ó': 'o', 'ò': 'o', 'ö': 'o', 'ô': 'o', 'õ': 'o',
    'ú': 'u', 'ù': 'u', 'ü': 'u', 'û': 'u',
    'ñ': 'n', 'ç': 'c',
  };

  static Map<String, Object?>? _asMap(Object? value) {
    if (value is Map<String, Object?>) return value;
    if (value is Map) {
      return value.map((key, item) => MapEntry(key.toString(), item));
    }
    return null;
  }

  static String? _asString(Object? value) => value is String ? value : null;

  static bool? _asBool(Object? value) => value is bool ? value : null;
}
