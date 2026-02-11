import 'parameter_info.dart';

/// Generates the initLocorda.g.dart file.
class CodeGenerator {
  final bool hasGeneratedWorker;
  final bool hasInitMapper;
  final List<ParameterInfo> locordaParams;
  final List<ParameterInfo> mapperParams;
  final Set<String> detectedFrameworkParams;

  const CodeGenerator({
    required this.hasGeneratedWorker,
    required this.hasInitMapper,
    required this.locordaParams,
    required this.mapperParams,
    required this.detectedFrameworkParams,
  });

  /// Generate the complete initLocorda.g.dart content.
  String generate() {
    final buffer = StringBuffer();
    
    // Header
    buffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
    buffer.writeln('// ignore_for_file: unused_import, depend_on_referenced_packages');
    buffer.writeln();
    
    // Imports
    _writeImports(buffer);
    buffer.writeln();
    
    // Documentation
    _writeDocumentation(buffer);
    
    // Function signature
    _writeFunctionSignature(buffer);
    
    // Function body
    _writeFunctionBody(buffer);
    
    return buffer.toString();
  }

  void _writeImports(StringBuffer buffer) {
    buffer.writeln("import 'package:locorda_flutter/locorda_flutter.dart';");
    
    if (hasGeneratedWorker) {
      buffer.writeln("import 'worker_generated.g.dart' show generatedWorkerSetup;");
    }
    
    if (hasInitMapper) {
      buffer.writeln("import 'init_rdf_mapper.g.dart' show initRdfMapper;");
    }
  }

  void _writeDocumentation(StringBuffer buffer) {
    buffer.writeln('/// Convenience wrapper for Locorda.create with auto-detected settings.');
    buffer.writeln('///');
    buffer.writeln('/// Auto-configures:');
    
    if (hasGeneratedWorker) {
      buffer.writeln('/// - workerSetup: generatedWorkerSetup (from worker_generated.g.dart)');
      buffer.writeln("/// - jsScript: 'worker_generated.dart.js'");
    }
    
    if (hasInitMapper) {
      buffer.writeln('/// - mapperInitializer: Generated from initRdfMapper');
    }
  }

  void _writeFunctionSignature(StringBuffer buffer) {
    buffer.writeln('Future<Locorda> initLocorda({');
    
    // Add custom mapper params first
    for (final param in mapperParams) {
      _writeParameter(buffer, param);
    }
    
    // Add Locorda.create params (filtered)
    final filteredParams = _filterLocordaParams();
    for (final param in filteredParams) {
      _writeParameter(buffer, param);
    }
    
    buffer.writeln('}) async {');
  }

  void _writeParameter(StringBuffer buffer, ParameterInfo param) {
    final parts = <String>[];
    
    if (param.isRequired) parts.add('required');
    parts.add(param.type);
    parts.add(param.name);
    
    final line = '  ${parts.join(' ')}';
    if (param.defaultValue != null) {
      buffer.writeln('$line = ${param.defaultValue},');
    } else {
      buffer.writeln('$line,');
    }
  }

  List<ParameterInfo> _filterLocordaParams() {
    return locordaParams.where((param) {
      // Remove auto-configured params
      if (hasGeneratedWorker && (param.name == 'workerSetup' || param.name == 'jsScript')) {
        return false;
      }
      if (hasInitMapper && param.name == 'mapperInitializer') {
        return false;
      }
      return true;
    }).toList();
  }

  void _writeFunctionBody(StringBuffer buffer) {
    buffer.writeln('  return Locorda.create(');
    
    // Auto-configured params
    if (hasGeneratedWorker) {
      buffer.writeln('    workerSetup: generatedWorkerSetup,');
      buffer.writeln("    jsScript: 'worker_generated.dart.js',");
    }
    
    if (hasInitMapper) {
      buffer.writeln('    mapperInitializer: (context) => initRdfMapper(');
      buffer.writeln('      rdfMapper: context.baseRdfMapper,');
      
      // Framework params
      for (final frameworkParam in detectedFrameworkParams) {
        final contextParam = frameworkParam.substring(1); // Remove $
        buffer.writeln('      $frameworkParam: context.$contextParam,');
      }
      
      // Custom params
      for (final param in mapperParams) {
        buffer.writeln('      ${param.name}: ${param.name},');
      }
      
      buffer.writeln('    ),');
    }
    
    // Pass-through params
    final filteredParams = _filterLocordaParams();
    for (final param in filteredParams) {
      buffer.writeln('    ${param.name}: ${param.name},');
    }
    
    buffer.writeln('  );');
    buffer.writeln('}');
  }
}
