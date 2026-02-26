import 'package:locorda/annotations.dart';
import 'package:locorda_rdf_terms_schema/schema.dart';

import 'note.dart';

@GroupKey(
  Note,
  groupingProperties: [
    GroupingProperty(
      SchemaNoteDigitalDocument.dateCreated,
      transforms: [
        RegexTransform(
          r'^([0-9]{4})-([0-9]{2})-([0-9]{2}).*',
          r'${1}-${2}',
        ),
      ],
    ),
  ],
)
class NoteGroupKey {
  @RdfProperty(SchemaNoteDigitalDocument.dateCreated)
  final DateTime createdMonth;

  NoteGroupKey(DateTime createdMonth)
      : createdMonth = DateTime.utc(
            createdMonth.year, createdMonth.month, 1, 0, 0, 0, 0, 0);

  /// Helper for current month group
  @RdfIgnore()
  static NoteGroupKey get currentMonth => NoteGroupKey(DateTime.now());

  /// Helper for previous month group
  @RdfIgnore()
  static NoteGroupKey get previousMonth {
    final now = DateTime.now();
    final prevMonth = DateTime.utc(now.year, now.month - 1, 1);
    return NoteGroupKey(prevMonth);
  }

  /// Create group key from a DateTime
  static NoteGroupKey fromDate(DateTime date) => NoteGroupKey(date);

  /// Format DateTime to YYYY-MM string for grouping
  static String _formatMonth(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}';
  }

  /// Get a human-readable month name
  @RdfIgnore()
  String get displayName {
    final formatted = _formatMonth(createdMonth);
    final parts = formatted.split('-');
    if (parts.length != 2) return formatted;

    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    if (year == null || month == null) return formatted;

    final monthNames = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];

    if (month < 1 || month > 12) return formatted;
    return '${monthNames[month - 1]} $year';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NoteGroupKey &&
          runtimeType == other.runtimeType &&
          createdMonth == other.createdMonth;

  @override
  int get hashCode => createdMonth.hashCode;

  @override
  String toString() => 'NoteGroupKey(createdMonth: $createdMonth)';
}
