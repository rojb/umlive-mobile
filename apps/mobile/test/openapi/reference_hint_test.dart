// Unit test for the one pure function `reference_hint.dart` introduces
// (`odd/tasks/reference-expansion-on-reads.md`, T2). `inferReferences` is
// synchronous and has no Flutter dependency, so this is a plain Dart test
// running under `flutter_test` for consistency with the rest of the app.

import 'package:flutter_test/flutter_test.dart';
import 'package:umlive_voice/openapi/reference_hint.dart';
import 'package:umlive_voice/openapi/registry.dart';

void main() {
  group('inferReferences', () {
    test('matches when the folded base equals a get-capable entity name', () {
      final registry = _registry([_entity('Cliente', withGet: true)]);
      const fields = [
        FieldDescriptor(name: 'clienteId', type: 'integer', format: 'int64'),
      ];

      final hints = inferReferences(fields: fields, registry: registry);

      expect(hints, hasLength(1));
      expect(hints.single.fieldName, 'clienteId');
      expect(hints.single.entity.name, 'Cliente');
    });

    test(
      'does not match a role name the target entity does not share '
      '(Venta - Cliente role "comprador" yields compradorId, which names no '
      'registry entity)',
      () {
        final registry = _registry([_entity('Cliente', withGet: true)]);
        const fields = [
          FieldDescriptor(
            name: 'compradorId',
            type: 'integer',
            format: 'int64',
          ),
        ];

        final hints = inferReferences(fields: fields, registry: registry);

        expect(hints, isEmpty);
      },
    );

    test('never treats the record\'s own id as a reference', () {
      final registry = _registry([_entity('Cliente', withGet: true)]);
      const fields = [
        FieldDescriptor(name: 'id', type: 'integer', format: 'int64'),
      ];

      final hints = inferReferences(fields: fields, registry: registry);

      expect(hints, isEmpty);
    });

    test('rejects a field of a type a foreign key is never declared as', () {
      final registry = _registry([_entity('Cliente', withGet: true)]);
      const fields = [
        FieldDescriptor(
          name: 'clienteId',
          type: 'array',
          itemsType: 'integer',
        ),
      ];

      final hints = inferReferences(fields: fields, registry: registry);

      expect(hints, isEmpty);
    });

    test('does not fetch through an entity with no get role', () {
      final registry = _registry([_entity('Cliente', withGet: false)]);
      const fields = [
        FieldDescriptor(name: 'clienteId', type: 'integer', format: 'int64'),
      ];

      final hints = inferReferences(fields: fields, registry: registry);

      expect(hints, isEmpty);
    });

    test('folds accents and case the same way the OpenAPI parser does', () {
      final registry = _registry([_entity('Dirección', withGet: true)]);
      const fields = [FieldDescriptor(name: 'direccionId', type: 'string')];

      final hints = inferReferences(fields: fields, registry: registry);

      expect(hints, hasLength(1));
      expect(hints.single.entity.name, 'Dirección');
    });

    test('a near miss renders the raw id rather than guessing', () {
      final registry = _registry([_entity('Cliente', withGet: true)]);
      const fields = [
        FieldDescriptor(name: 'clientId', type: 'integer', format: 'int64'),
      ];

      final hints = inferReferences(fields: fields, registry: registry);

      expect(hints, isEmpty);
    });
  });
}

EntityModel _entity(String name, {required bool withGet}) => EntityModel(
  name: name,
  collectionRoute: '/api/${name.toLowerCase()}',
  operationKeys: const <String>[],
  roleKeys: withGet
      ? <EntityRole, String>{EntityRole.get: 'GET /api/${name.toLowerCase()}/{id}'}
      : const <EntityRole, String>{},
  readableFields: const <FieldDescriptor>[],
  requiredWritableFields: const <FieldDescriptor>[],
);

ApiRegistry _registry(List<EntityModel> entities) => ApiRegistry(
  openapiVersion: '3.1.0',
  documentHash: 'test-hash',
  pathCount: entities.length,
  operations: const <ApiOperation>[],
  entities: entities,
  diagnostics: const <RegistryDiagnostic>[],
);
