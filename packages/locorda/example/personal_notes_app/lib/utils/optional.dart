/// Wrapper class to distinguish between "don't change" (null) and "set to null" (Optional(null))
///
/// This is used in copyWith methods where we need to differentiate between:
/// - null parameter: don't change the field
/// - Optional(null): set the field to null
/// - Optional(value): set the field to value
class Optional<T> {
  final T? value;
  const Optional(this.value);

  /// Create an Optional that represents setting the field to null
  const Optional.absent() : value = null;

  @override
  String toString() => 'Optional($value)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Optional<T> &&
          runtimeType == other.runtimeType &&
          value == other.value;

  @override
  int get hashCode => value.hashCode;
}
