/// Utilities for working with dart:js_interop conversions.
///
/// Handles the conversion of JS objects into proper Dart types,
/// including recursive conversion of nested structures.
library;

import 'dart:js_interop';

/// Converts a JS value to a fully Dart-typed object.
///
/// This function combines `dartify()` and deep conversion into a single operation:
/// 1. Calls `dartify()` to convert JS types to Dart types
/// 2. Recursively converts nested structures (JsLinkedHashMap → Map, etc.)
///
/// The dart:js_interop `dartify()` alone is insufficient because:
/// - It returns `JsLinkedHashMap<Object?, Object?>` not `Map<String, dynamic>`
/// - Type checks like `is Map<String, dynamic>` fail on JS types
/// - Nested structures also need conversion
///
/// Example:
/// ```dart
/// // Instead of:
/// final jsData = messageEvent.data.dartify();
/// final dartData = deepConvertJsObject(jsData);
///
/// // Use:
/// final dartData = dartifyAndConvert(messageEvent.data);
/// // Now dartData is properly typed Map<String, dynamic>
/// ```
dynamic dartifyAndConvert(JSAny? jsValue) {
  final dartified = jsValue.dartify();
  return _deepConvertJsObject(dartified);
}

/// Recursively converts dartified objects to proper Dart types.
///
/// Use this when you already have a dartified object (e.g., nested within
/// a larger structure). For JS values, prefer [dartifyAndConvert].
///
/// Handles nested Maps and Lists that come from dartify() as JsLinkedHashMap.
dynamic _deepConvertJsObject(dynamic value) {
  if (value is Map) {
    return value
        .map((key, val) => MapEntry(key.toString(), _deepConvertJsObject(val)));
  } else if (value is List) {
    return value.map(_deepConvertJsObject).toList();
  }
  return value;
}
