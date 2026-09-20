/// Turns one spoken answer into the JSON value its field declares (`T13`).
///
/// Slot filling (`FR-MC02`) collects the operator's own words and stores them
/// unchanged; the conversion to a typed JSON value happens exactly once, when
/// the complete record is submitted. This file is that conversion, and it is
/// the only place a sentence like `42`, `3,5` or `sí` becomes an `int`, a
/// `double` or a `bool`.
///
/// **What it refuses is as important as what it converts.** A relation or a
/// list is not something this conversation can collect by voice, so a field of
/// any other declared type fails with `unsupported_type` rather than being
/// stored as nonsense. [isCollectibleByVoice] is the predicate behind that
/// refusal, so the resolver, the draft and this converter cannot disagree about
/// which fields are dictatable.
///
/// **A refusal never mutates the draft.** Conversion is pure: it takes the
/// field and the answer and returns a result. The caller keeps the draft
/// unchanged when the result is [FieldValueFailed], which is why a failed
/// answer is re-asked instead of half-applied.
library;

import '../openapi/registry.dart';
import 'spanish_language.dart';

/// The outcome of interpreting one answer for a field.
sealed class FieldValueResult {
  const FieldValueResult();
}

/// The answer was understood and converted.
final class FieldValueOk extends FieldValueResult {
  const FieldValueOk(this.value);

  /// The JSON value to send: a `String`, `int`, `double` or `bool` depending on
  /// the field's declared type.
  final Object? value;
}

/// The answer could not be interpreted.
final class FieldValueFailed extends FieldValueResult {
  const FieldValueFailed(this.reason);

  /// A stable code for the log, never user-facing copy.
  final String reason;
}

/// Whether [field] is a field this conversation can ask for and convert by
/// voice at all.
///
/// True for `string`, `unknown` (a property the document declared neither type
/// nor `$ref` for) and the three scalar types the operator can dictate: the
/// integer, the number and the boolean. False for an array and for anything
/// else, which is a relation or a list by definition here.
bool isCollectibleByVoice(FieldDescriptor field) {
  switch (field.type.toLowerCase()) {
    case 'string':
    case 'unknown':
    case 'integer':
    case 'number':
    case 'boolean':
      return true;
    default:
      return false;
  }
}

/// Interprets [answer] as a value for [field], by the field's declared type.
///
/// The type is compared lower-cased, and a property the document declared no
/// type for (`unknown`) is taken as text, which is what the resolver can
/// capture from speech in the first place.
FieldValueResult convertFieldValue(FieldDescriptor field, String answer) {
  final type = field.type.toLowerCase();
  final trimmed = answer.trim();

  switch (type) {
    case 'string':
    case 'unknown':
      // The operator's own words, accents and capitals included: nothing is
      // normalised here, because a name is data and not a search key.
      if (trimmed.isEmpty) return const FieldValueFailed('empty');
      return FieldValueOk(trimmed);

    case 'integer':
      if (!_integerPattern.hasMatch(trimmed)) {
        return const FieldValueFailed('not_an_integer');
      }
      return FieldValueOk(int.parse(trimmed));

    case 'number':
      // A comma is a decimal separator in Spanish, so it is normalised before
      // parsing; the accepted shape is digits with at most one separator.
      final normalised = trimmed.replaceAll(',', '.');
      if (!_numberPattern.hasMatch(normalised)) {
        return const FieldValueFailed('not_a_number');
      }
      return FieldValueOk(double.parse(normalised));

    case 'boolean':
      // Any affirmative token anywhere in the answer wins, then any negative
      // token; an answer with neither is not a boolean.
      final tokens = utteranceTokens(answer);
      if (tokens.any(affirmativeAnswers.contains)) {
        return const FieldValueOk(true);
      }
      if (tokens.any(negativeAnswers.contains)) {
        return const FieldValueOk(false);
      }
      return const FieldValueFailed('not_a_boolean');

    default:
      // An array or an object: a relation or a list. Never guess a JSON value
      // for it — the app says it cannot collect it instead (`FR-MC04`).
      return const FieldValueFailed('unsupported_type');
  }
}

/// Digits only: the spec's `^[0-9]+$`, with no sign and no separator.
final RegExp _integerPattern = RegExp(r'^[0-9]+$');

/// Digits, an optional single `.` decimal separator, and an optional leading
/// sign. The separator is normalised from `,` to `.` before this is applied.
final RegExp _numberPattern = RegExp(r'^-?[0-9]+([.][0-9]+)?$');
