/// Main screen showing list of notes with connect and sync options.
library;

import 'package:flutter/material.dart';
import 'package:locorda/locorda.dart';

import '../models/category.dart' as models;
import '../models/note_group_key.dart';
import '../models/note_index_entry.dart';
import '../services/categories_service.dart';
import '../services/notes_service.dart';
import 'categories_screen.dart';
import 'note_editor_screen.dart';

class NotesListScreen extends StatefulWidget {
  final NotesService notesService;
  final CategoriesService categoriesService;
  final UiAdapterRegistry uiAdapterRegistry;
  final SyncManager syncManager;

  const NotesListScreen({
    super.key,
    required this.notesService,
    required this.categoriesService,
    required this.uiAdapterRegistry,
    required this.syncManager,
  });

  @override
  State<NotesListScreen> createState() => _NotesListScreenState();
}

class _NotesListScreenState extends State<NotesListScreen> {
  NoteGroupKey? _selectedMonth;

  @override
  void initState() {
    super.initState();
    _initializeMonthSubscriptions();
  }

  /// Initialize subscription to current and previous month
  Future<void> _initializeMonthSubscriptions() async {
    // Initialize default subscriptions and get the actual month that was set
    final initialMonth =
        await widget.notesService.initializeDefaultSubscriptions();
    setState(() {
      _selectedMonth = initialMonth;
    });
  }

  /// Switch to a different month group
  Future<void> _selectMonth(NoteGroupKey monthKey) async {
    setState(() {
      _selectedMonth = monthKey;
    });

    // Update the service to filter by selected month (handles subscription internally)
    await widget.notesService.setMonthFilter(monthKey);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Switched to ${monthKey.displayName}'),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  /// Filter notes by category using reactive streams
  void _filterByCategory(String? categoryId) {
    if (categoryId == 'null') {
      categoryId = null; // Clear filter
    }
    // Update the service filter - this will automatically update the stream
    widget.notesService.setCategoryFilter(categoryId);
  }

  /// Navigate to previous month
  Future<void> _navigateToPreviousMonth() async {
    if (_selectedMonth == null) return;
    final selectedDate = _selectedMonth!.createdMonth;
    final prevMonth = DateTime(selectedDate.year, selectedDate.month - 1, 1);
    await _selectMonth(NoteGroupKey.fromDate(prevMonth));
  }

  /// Navigate to next month
  Future<void> _navigateToNextMonth() async {
    if (_selectedMonth == null) return;
    final currentDate = DateTime.now();
    final selectedDate = _selectedMonth!.createdMonth;
    final nextMonth = DateTime(selectedDate.year, selectedDate.month + 1, 1);

    // Don't allow navigation to future months
    if (nextMonth
        .isAfter(DateTime(currentDate.year, currentDate.month + 1, 0))) {
      return;
    }

    await _selectMonth(NoteGroupKey.fromDate(nextMonth));
  }

  /// Show date picker for quick month selection
  Future<void> _showDatePicker() async {
    if (_selectedMonth == null) return;
    final currentDate = DateTime.now();
    final selectedDate = _selectedMonth!.createdMonth;

    final picked = await showDatePicker(
      context: context,
      initialDate: selectedDate,
      firstDate: DateTime(2020, 1),
      lastDate: currentDate,
      initialDatePickerMode: DatePickerMode.year,
      helpText: 'Select Month',
      fieldLabelText: 'Month',
    );

    if (picked != null) {
      await _selectMonth(NoteGroupKey.fromDate(picked));
    }
  }

  void _openCategories() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => CategoriesScreen(
          categoriesService: widget.categoriesService,
        ),
      ),
    );
  }

  void _createNote() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => NoteEditorScreen(
          notesService: widget.notesService,
          categoriesService: widget.categoriesService,
          // Notes will update automatically via reactive streams
        ),
      ),
    );
  }

  Future<void> _editNote(NoteIndexEntry noteEntry) async {
    // Load full note data on-demand for editing
    final note = await widget.notesService.getNote(noteEntry.id);
    if (note == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Note not found: ${noteEntry.id}')),
        );
      }
      return;
    }

    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => NoteEditorScreen(
            notesService: widget.notesService,
            categoriesService: widget.categoriesService,
            note: note,
            // Notes will update automatically via reactive streams
          ),
        ),
      );
    }
  }

  Future<void> _deleteNote(NoteIndexEntry noteEntry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Note'),
        content: Text('Are you sure you want to delete "${noteEntry.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await widget.notesService.deleteNote(noteEntry.id);
      // Notes will update automatically via reactive streams
    }
  }

  /// Build compact month navigation for AppBar
  Widget _buildAppBarMonthNavigation() {
    final currentDate = DateTime.now();
    if (_selectedMonth == null) {
      return const SizedBox(); // Return empty widget during initialization
    }
    final selectedDate = _selectedMonth!.createdMonth;
    final isCurrentMonth = _selectedMonth == NoteGroupKey.currentMonth;
    final canGoNext =
        selectedDate.isBefore(DateTime(currentDate.year, currentDate.month, 1));

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Previous month button
        IconButton(
          onPressed: _navigateToPreviousMonth,
          icon: const Icon(Icons.chevron_left),
          tooltip: 'Previous Month',
          iconSize: 20,
        ),
        // Current month display (tappable for date picker)
        GestureDetector(
          onTap: _showDatePicker,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 8,
            ),
            decoration: BoxDecoration(
              color: isCurrentMonth
                  ? Theme.of(context).colorScheme.primaryContainer
                  : Theme.of(context).colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(20),
              border: isCurrentMonth
                  ? Border.all(
                      color: Theme.of(context)
                          .colorScheme
                          .primary
                          .withValues(alpha: 0.3),
                      width: 1,
                    )
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.calendar_today,
                  size: 16,
                  color: isCurrentMonth
                      ? Theme.of(context).colorScheme.onPrimaryContainer
                      : Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  _selectedMonth!.displayName,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: isCurrentMonth
                            ? Theme.of(context).colorScheme.onPrimaryContainer
                            : Theme.of(context).colorScheme.onSurface,
                      ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.expand_more,
                  size: 14,
                  color: isCurrentMonth
                      ? Theme.of(context)
                          .colorScheme
                          .onPrimaryContainer
                          .withValues(alpha: 0.7)
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
        // Next month button
        IconButton(
          onPressed: canGoNext ? _navigateToNextMonth : null,
          icon: const Icon(Icons.chevron_right),
          tooltip: canGoNext ? 'Next Month' : 'Cannot go to future months',
          iconSize: 20,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _buildAppBarMonthNavigation(),
        elevation: 0,
        centerTitle: true,
        actions: [
          // Category filter dropdown - demonstrates group loading
          StreamBuilder<String?>(
            stream: widget.notesService.categoryFilterStream,
            builder: (context, filterSnapshot) {
              final selectedFilter = filterSnapshot.data;
              return StreamBuilder<List<models.Category>>(
                stream: widget.categoriesService.getAllCategories(),
                builder: (context, categoriesSnapshot) {
                  final categories = categoriesSnapshot.data ?? [];
                  return PopupMenuButton<String?>(
                    icon: Icon(selectedFilter != null
                        ? Icons.filter_alt
                        : Icons.filter_alt_outlined),
                    tooltip: 'Filter by Category',
                    onSelected: _filterByCategory,
                    itemBuilder: (context) => [
                      const PopupMenuItem<String?>(
                        value: 'null',
                        child: Row(
                          children: [
                            Icon(Icons.clear_all),
                            SizedBox(width: 8),
                            Text('All Notes'),
                          ],
                        ),
                      ),
                      if (categories.isNotEmpty) const PopupMenuDivider(),
                      // Dynamic categories from the reactive categories service
                      ...categories.map((category) => PopupMenuItem<String>(
                            value: category.id,
                            child: Row(
                              children: [
                                Icon(_getCategoryIcon(category.settings?.icon)),
                                const SizedBox(width: 8),
                                Text(category.name),
                              ],
                            ),
                          )),
                    ],
                  );
                },
              );
            },
          ),
          // Categories button
          IconButton(
            onPressed: _openCategories,
            icon: const Icon(Icons.category),
            tooltip: 'Manage Categories',
          ),
          // Multi-backend connection and sync status
          MultiBackendStatusWidget(
            registry: widget.uiAdapterRegistry,
            syncManager: widget.syncManager,
          ),
        ],
      ),
      body: SyncRefreshIndicator(
        syncManager: widget.syncManager,
        onSyncComplete: () {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Sync completed'),
                duration: Duration(seconds: 1),
              ),
            );
          }
        },
        onSyncError: (error) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Sync failed: $error'),
                backgroundColor: Colors.red,
              ),
            );
          }
        },
        child: StreamBuilder<List<NoteIndexEntry>>(
          stream: widget.notesService.filteredNoteIndexEntries,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }

            if (snapshot.hasError) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.error_outline,
                        size: 64, color: Colors.red),
                    const SizedBox(height: 16),
                    Text('Error: ${snapshot.error}'),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () {
                        // Force refresh by changing filter
                        final currentFilter =
                            widget.notesService.currentCategoryFilter;
                        widget.notesService.setCategoryFilter(null);
                        widget.notesService.setCategoryFilter(currentFilter);
                      },
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              );
            }

            final noteEntries = snapshot.data ?? [];
            return noteEntries.isEmpty
                ? _buildEmptyState()
                : _buildNotesList(noteEntries);
          },
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _createNote,
        tooltip: 'Add Note',
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.note_alt_outlined, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          const Text(
            'No notes yet',
            style: TextStyle(fontSize: 18, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          const Text(
            'Tap + to create your first note',
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 24),
          const Text(
            'Working locally - use the cloud icon to connect to Solid Pod for sync',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildNotesList(List<NoteIndexEntry> noteEntries) {
    return ListView.builder(
      itemCount: noteEntries.length,
      itemBuilder: (context, index) {
        final noteEntry = noteEntries[index];
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: ListTile(
            title: Text(
              noteEntry.name.isEmpty ? 'Untitled' : noteEntry.name,
              style: TextStyle(
                fontWeight: FontWeight.w500,
                color: noteEntry.name.isEmpty ? Colors.grey : null,
              ),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Note: content not available in index entries - this is expected
                // Users need to tap to load full note for content
                const SizedBox(height: 4),
                Text(
                  'Tap to view content...',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey[600],
                    fontStyle: FontStyle.italic,
                  ),
                ),
                if (noteEntry.keywords.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 4,
                    children: noteEntry.keywords
                        .map((keyword) => Chip(
                              label: Text(keyword,
                                  style: const TextStyle(fontSize: 11)),
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              visualDensity: VisualDensity.compact,
                            ))
                        .toList(),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  'Modified ${_formatDate(noteEntry.dateModified)}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
            onTap: () => _editNote(noteEntry),
            trailing: PopupMenuButton(
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'delete',
                  child: const Row(
                    children: [
                      Icon(Icons.delete, color: Colors.red),
                      SizedBox(width: 8),
                      Text('Delete'),
                    ],
                  ),
                ),
              ],
              onSelected: (value) {
                if (value == 'delete') {
                  _deleteNote(noteEntry);
                }
              },
            ),
          ),
        );
      },
    );
  }

  IconData _getCategoryIcon(String? iconName) {
    switch (iconName) {
      case 'work':
        return Icons.work;
      case 'personal':
        return Icons.person;
      case 'archive':
        return Icons.archive;
      case 'folder':
        return Icons.folder;
      default:
        return Icons.category;
    }
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inDays == 0) {
      if (diff.inHours == 0) {
        return '${diff.inMinutes}m ago';
      }
      return '${diff.inHours}h ago';
    } else if (diff.inDays == 1) {
      return 'yesterday';
    } else if (diff.inDays < 7) {
      return '${diff.inDays}d ago';
    } else {
      return '${date.day}/${date.month}/${date.year}';
    }
  }
}
