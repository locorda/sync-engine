/// Code generation utilities for managing imports and aliases.
///
/// Adapted from locorda_rdf_mapper_generator for use in locorda_init_generator.
library;

/// Represents generated code with its import dependencies and type aliases.
///
/// This class manages code generation where types might come from different
/// packages/libraries and need to be properly imported and aliased in the
/// target file to avoid naming conflicts.
///
/// ## Propagation and Resolution
/// Code objects are designed to be propagated as-is through the data layer
/// without being converted to strings until the final template rendering stage.
/// This ensures that:
/// 1. Import information is preserved throughout the processing pipeline
/// 2. Aliases are correctly resolved with the final import context
/// 3. Type references maintain their import dependencies
class Code {
  static const String typeMarker = r'$Code$';
  static const String typeProperty = '__type__';

  final String _code;
  final Set<String> _imports; // Import URIs only

  // Special markers to safely identify aliases in code - these are invalid Dart syntax
  static const String _aliasStartMarker = '⟨@';
  static const String _aliasEndMarker = '@⟩';

  const Code._(this._code, this._imports);

  Map<String, dynamic> toMap() {
    return {
      'code': _code,
      'imports': _imports.toList(),
      typeProperty: typeMarker,
    };
  }

  static Code fromMap(Map<String, dynamic> map) {
    assert(map[typeProperty] == typeMarker, 'Invalid map for Code: $map');
    return Code._(
      map['code'] as String,
      Set<String>.from(map['imports'] as List<dynamic>),
    );
  }

  /// Creates a Code instance with the given code string and no imports
  const Code.literal(String code) : this._(code, const {});

  /// Creates a Code instance for a simple value that doesn't require imports
  const Code.value(String code) : this.literal(code);

  /// Creates a Code instance for a type reference that may require imports
  factory Code.type(String typeName, {String? importUri}) {
    if (importUri == null) {
      // No import needed - this is a built-in type or already available
      return Code.literal(typeName);
    }

    return Code._('${_wrapImportUri(importUri)}$typeName', {importUri});
  }

  /// Combines multiple Code instances to a parameter list
  factory Code.paramsList(Iterable<Code> params) =>
      Code.combine(params, separator: ', ', pre: '(', post: ')');

  factory Code.genericParamsList(Iterable<Code> params) =>
      Code.combine(params, separator: ', ', pre: '<', post: '>');

  factory Code.combine(Iterable<Code> codes,
      {String separator = '', String? pre, String? post}) {
    assert(pre == null && post == null || pre != null && post != null,
        'pre and post must be both provided or both null');
    if (codes.isEmpty && pre == null && post == null) return Code.literal('');
    if (codes.length == 1 && pre == null && post == null) return codes.first;

    final combinedImports = codes.expand((c) => c._imports).toSet();

    // Build the combined code by joining each code's internal representation
    String combinedCode =
        '${pre ?? ''}${codes.map((c) => c._code).join(separator)}${post ?? ''}';

    return Code._(combinedCode, combinedImports);
  }

  Code operator +(Object other) => Code.combine(
      [this, other is Code ? other : Code.literal(other.toString())]);

  /// The generated code string
  String get code => resolveAliases().$1;

  /// All import dependencies required by this code
  Set<String> get imports => Set.unmodifiable(_imports);

  /// Checks if this code has any import dependencies
  bool get hasImports => _imports.isNotEmpty;

  // The code without any import aliases, suitable for pure code generation or if
  // you are just interested in the name of a type for example.
  // To get the pure class name without imports, we resolve aliases
  // and use the class name without any import prefixes.
  String get codeWithoutAlias => resolveAliases(
      knownImports:
          Map.fromIterable(imports, key: (v) => v, value: (v) => '')).$1;

  /// Resolves alias markers in code to actual aliases
  /// Returns a record with the resolved code and a map of import URIs to aliases
  (String, Map<String, String>) resolveAliases(
      {Map<String, String> knownImports = const {},
      Map<String, String> broaderImports = const {}}) {
    String resolvedCode = _code;
    final importsWithAlias = <String, String>{};

    // Track which aliases are already used to avoid conflicts
    final usedAliases = <String>{};
    usedAliases.addAll(knownImports.values);

    for (final originalImportUri in _imports) {
      final importUri = broaderImports[originalImportUri] ?? originalImportUri;
      String alias;

      if (knownImports.containsKey(importUri)) {
        // Use the known alias
        alias = knownImports[importUri]!;
      } else {
        // Generate a new alias, ensuring it doesn't conflict
        alias = _generateAliasFromUri(importUri);
        if (alias.isNotEmpty) {
          int counter = 2;
          while (usedAliases.contains(alias)) {
            alias = '${_generateAliasFromUri(importUri)}$counter';
            counter++;
          }
        }
        usedAliases.add(alias);
      }

      importsWithAlias[importUri] = alias;
      final marker = _wrapImportUri(originalImportUri);
      resolvedCode =
          resolvedCode.replaceAll(marker, alias.isEmpty ? '' : '$alias.');
    }

    return (resolvedCode, importsWithAlias);
  }

  /// Generates a default alias from an import URI
  static String _generateAliasFromUri(String uri) {
    if (uri.startsWith('package:') ||
        uri.startsWith('asset:') ||
        uri.startsWith('file:')) {
      // Extract filename from URI: package:foo/bar/baz.dart -> baz, asset:foo/bar.dart -> bar
      final prefixLength = uri.split(":")[0].length + 1; // +1 for the colon
      final parts = uri.substring(prefixLength).split('/');
      if (parts.isNotEmpty) {
        final lastPart = parts.last;
        // Remove .dart extension if present
        final aliasName = lastPart.endsWith('.dart')
            ? lastPart.substring(0, lastPart.length - 5)
            : lastPart;
        return _sanitizeAlias(aliasName);
      }
    } else if (uri.startsWith('dart:')) {
      if (uri == 'dart:core') {
        // Special case for dart:core - no alias needed
        return '';
      }
      // dart:core -> core
      return _sanitizeAlias(uri.substring(5));
    }

    // Fallback: use a generic alias
    return 'lib${uri.hashCode.abs()}';
  }

  /// Wraps an import URI with special markers for safe replacement
  static String _wrapImportUri(String importUri) {
    return '$_aliasStartMarker$importUri$_aliasEndMarker';
  }

  /// Sanitizes an alias to ensure it's a valid Dart identifier
  /// If the result is too long, shortens it by using first letters of underscore-separated parts
  static String _sanitizeAlias(String input) {
    final sanitized = input.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');

    // If alias is reasonably short, return as is
    if (sanitized.length <= 12) {
      return sanitized;
    }

    // For long aliases, use first letter of each underscore-separated part
    final parts = sanitized.split('_').where((part) => part.isNotEmpty);
    if (parts.length > 1) {
      final abbreviated = parts.map((part) => part[0].toLowerCase()).join();
      return abbreviated.isNotEmpty ? abbreviated : sanitized;
    }

    // For single long words without underscores, truncate to reasonable length
    return sanitized.length > 12 ? sanitized.substring(0, 12) : sanitized;
  }

  @override
  String toString() => _code;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Code && _code == other._code;

  @override
  int get hashCode => _code.hashCode;

  Code _namedParam(Object name, Object value) {
    return Code.combine([
      Code.literal('$name'),
      Code.literal(': '),
      _toCode(value),
    ]);
  }

  Code _toCode(Object args) => switch (args) {
        Code c => c,
        String s => Code.literal(s),
        Map m => Code.combine(
            m.entries.map((entry) => _namedParam(entry.key, entry.value)),
            separator: ', ',
            pre: '{',
            post: '}',
          ),
        Set s => Code.combine(
            s.map((item) => _toCode(item)),
            separator: ', ',
            pre: '{',
            post: '}',
          ),
        Iterable i => Code.combine(
            i.map((item) => _toCode(item)),
            separator: ', ',
            pre: '[',
            post: ']',
          ),
        _ => Code.literal(args.toString()),
      };

  Iterable<Code> _toToplevelParams(Object args) sync* {
    if (args is Map) {
      // For top-level params, we want to yield each entry as a separate param (e.g. for named function arguments)
      for (final entry in args.entries) {
        yield _namedParam(entry.key, entry.value);
      }
    } else if (args is Iterable) {
      // For top-level params, we want to yield each item directly (e.g. for function arguments)
      for (final item in args) {
        yield _toCode(item);
      }
    } else {
      throw ArgumentError(
          'Top-level params must be a Map<String, Object> or an Iterable, was ${args.runtimeType}');
    }
  }

  /// Generates a constructor invocation with optional positional and named arguments.
  ///
  /// Combines this Code (typically a type reference) with constructor arguments.
  /// Supports four call patterns:
  /// - No args: `SomeClass()` - use `.newInstance()`
  /// - Positional only: `SomeClass(arg1, arg2)` - use `.newInstance([arg1, arg2])`
  /// - Named only: `SomeClass(param: value)` - use `.newInstance({'param': value})`
  /// - Mixed: `SomeClass(arg1, param: value)` - use `.newInstance([arg1], {'param': value})`
  ///
  /// Example usage (actual patterns from config_code_generator.dart):
  /// ```dart
  /// // No args: generateLocordaConfig()
  /// Code.type('generateLocordaConfig', importUri: '...').newInstance()
  ///
  /// // Named args only: LocordaConfig(resources: [...])
  /// Code.type('LocordaConfig', importUri: pkg).newInstance({'resources': list})
  ///
  /// // Positional + named: GroupIndexConfig(NoteGroupKey, localName: 'byDate')
  /// Code.type('GroupIndexConfig', importUri: pkg).newInstance(
  ///   [groupKeyClass],
  ///   {'localName': Code.value("'byDate'")}
  /// )
  ///
  /// // Positional only: IndexItemConfig(NoteIndexEntry, {propertySet})
  /// Code.type('IndexItemConfig', importUri: pkg).newInstance([itemClass, propSet])
  /// ```
  Code newInstance([Object args = const [], Map namedArgs = const {}]) {
    if (namedArgs.isEmpty) {
      return this + Code.paramsList(_toToplevelParams(args));
    }
    return this +
        Code.paramsList(
            [..._toToplevelParams(args), ..._toToplevelParams(namedArgs)]);
  }

  /// Generates a method invocation on this Code object.
  ///
  /// Appends `.methodName(args)` or `.methodName(args, namedArgs)` to generate method calls.
  /// Supports positional args (as List or Map) and optional named args (as Map).
  ///
  /// Example usage (actual patterns from code_generator.dart and config_code_generator.dart):
  /// ```dart
  /// // Locorda.create(config: configCode, storage: storageCode)
  /// Code.type('Locorda', importUri: pkg).call('create', {
  ///   'config': configCode,
  ///   'storage': storageCode,
  /// })
  ///
  /// // Uri.parse('https://...')
  /// core('Uri').call('parse', [
  ///   Code.value("'https://example.com/mapping.ttl'"),
  /// ])
  /// ```
  Code call(String methodName,
      [Object args = const [], Map<String, Object> namedArgs = const {}]) {
    if (namedArgs.isEmpty) {
      return this +
          Code.literal('.' + methodName) +
          Code.paramsList(_toToplevelParams(args));
    }
    return this +
        Code.literal('.' + methodName) +
        Code.paramsList(
            [..._toToplevelParams(args), ..._toToplevelParams(namedArgs)]);
  }

  /// Generates field/enum access on this Code object.
  ///
  /// Appends `.fieldName` for accessing static fields, enum values,
  /// or object properties.
  ///
  /// Example usage (actual patterns from config_code_generator.dart):
  /// ```dart
  /// // RootResourceFetchPolicy.prefetch
  /// Code.type('RootResourceFetchPolicy', importUri: locordaCorePkg).field('prefetch')
  ///
  /// // RootResourceFetchPolicy.onRequest
  /// Code.type('RootResourceFetchPolicy', importUri: locordaCorePkg).field('onRequest')
  /// ```
  Code field(String fieldName) => this + Code.literal('.' + fieldName);

  /// Generates a generic type with type parameters.
  ///
  /// Appends `<T1, T2, ...>` to create generic type references.
  ///
  /// Example usage (actual patterns from code_generator.dart):
  /// ```dart
  /// // Future<Locorda>
  /// core('Future').withGenericParams([
  ///   Code.type('Locorda', importUri: locordaPkg),
  /// ])
  ///
  /// // List<ResourceConfig>
  /// core('List').withGenericParams([
  ///   Code.type('ResourceConfig', importUri: locordaObjectsPkg),
  /// ])
  /// ```
  Code withGenericParams(List<Code> list) =>
      this + Code.genericParamsList(list);
}

const importDartCore = 'dart:core';

class CodeResolver {
  final Map<String, String> _broaderImports = {};
  final Map<String, String> _knownImports = {};
  final Map<String, String> _usedImports = {};
  bool _finalized = false;
  CodeResolver._(
      {Map<String, String> broaderImports = const {},
      Map<String, String> knownImports = const {}}) {
    _broaderImports.addAll(broaderImports);
    _knownImports.addAll(knownImports);
  }
  Map<String, String> get usedImports => Map.unmodifiable(_usedImports);

  static String toDartFileContent(
      String header, Map<String, String> importAliases, Code body,
      {Map<String, String> broaderImports = const {}}) {
    CodeResolver codeResolver = CodeResolver._(
        broaderImports: broaderImports, knownImports: importAliases);
    StringBuffer buffer = StringBuffer(header);
    buffer.writeln();
    final codeBody = codeResolver._writeCode(body);
    codeResolver._writeImports(buffer);
    buffer.write(codeBody);
    return buffer.toString();
  }

  void _writeImports(StringBuffer buffer) {
    _finalized = true;
    // Add all imports with their aliases
    final sortedImports = _usedImports.keys.toSet().toList()..sort();

    for (final importUri in sortedImports) {
      final alias = _usedImports[importUri];
      if (alias != null && alias.isNotEmpty) {
        buffer.writeln("import '$importUri' as $alias;");
      } else {
        buffer.writeln("import '$importUri';");
      }
    }
    buffer.writeln();
  }

  String _writeCode(Code code) {
    if (_finalized) {
      throw StateError(
          'Cannot resolve code after finalization. All imports should be resolved before finalization.');
    }
    final (resolvedCode, moreImports) = code.resolveAliases(
        knownImports: _knownImports, broaderImports: _broaderImports);

    // Update knownImports with new imports
    _knownImports.addAll(moreImports);
    _usedImports.addAll(moreImports);
    return resolvedCode;
  }
}

/// Convenience function for creating Code instances for dart:core types.
///
/// Shorthand for `Code.type(typeName, importUri: 'dart:core')`.
/// Use this for built-in Dart types like Future, List, Map, Uri, etc.
///
/// Example usage:
/// ```dart
/// // Future<Locorda>
/// core('Future').withGenericParams([locordaType])
///
/// // List<String>
/// core('List').withGenericParams([core('String')])
///
/// // Uri.parse(...)
/// core('Uri').call('parse', [urlString])
/// ```
Code core(String typeName) {
  return Code.type(typeName, importUri: importDartCore);
}
