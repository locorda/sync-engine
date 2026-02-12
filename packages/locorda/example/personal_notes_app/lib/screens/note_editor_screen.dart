/// Screen for creating and editing individual notes.
library;

import 'package:flutter/material.dart';
import '../models/note.dart';
import '../models/weblink.dart';
import '../models/comment.dart';
import '../models/category.dart' as models;
import '../services/notes_service.dart';
import '../services/categories_service.dart';
import '../utils/optional.dart';
import '../widgets/comment_section.dart';

class NoteEditorScreen extends StatefulWidget {
  final NotesService notesService;
  final CategoriesService categoriesService;
  final Note? note;

  const NoteEditorScreen({
    super.key,
    required this.notesService,
    required this.categoriesService,
    this.note,
  });

  @override
  State<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

class _NoteEditorScreenState extends State<NoteEditorScreen> {
  late final TextEditingController _titleController;
  late final TextEditingController _contentController;
  late final TextEditingController _tagController;
  late final TextEditingController _weblinkUrlController;
  late final TextEditingController _weblinkTitleController;
  late Set<String> _tags;
  late Set<Weblink> _weblinks;
  late Set<Comment> _comments;
  late String? _selectedCategoryId;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.note?.title ?? '');
    _contentController =
        TextEditingController(text: widget.note?.content ?? '');
    _tagController = TextEditingController();
    _weblinkUrlController = TextEditingController();
    _weblinkTitleController = TextEditingController();
    _tags = Set.from(widget.note?.tags ?? <String>{});
    _weblinks = Set.from(widget.note?.weblinks ?? <Weblink>{});
    _comments = Set.from(widget.note?.comments ?? <Comment>{});
    _selectedCategoryId = widget.note?.categoryId;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    _tagController.dispose();
    _weblinkUrlController.dispose();
    _weblinkTitleController.dispose();
    super.dispose();
  }

  Future<void> _saveNote() async {
    if (_saving) return;

    setState(() => _saving = true);

    try {
      // Auto-add pending weblink if URL field has content
      final pendingUrl = _weblinkUrlController.text.trim();
      final finalWeblinks = Set<Weblink>.from(_weblinks);
      if (pendingUrl.isNotEmpty) {
        finalWeblinks.add(Weblink(
          url: pendingUrl,
          title: _weblinkTitleController.text.trim().isEmpty
              ? null
              : _weblinkTitleController.text.trim(),
        ));
      }

      // Auto-add pending tag if tag field has content
      final pendingTag = _tagController.text.trim();
      final finalTags = Set<String>.from(_tags);
      if (pendingTag.isNotEmpty) {
        finalTags.add(pendingTag);
      }

      final note = widget.note?.copyWith(
            title: _titleController.text,
            content: _contentController.text,
            tags: finalTags,
            categoryId: Optional(_selectedCategoryId),
            weblinks: finalWeblinks,
            comments: _comments,
          ) ??
          widget.notesService
              .createNote(
                title: _titleController.text,
                content: _contentController.text,
                tags: finalTags,
              )
              .copyWith(
                categoryId: Optional(_selectedCategoryId),
                weblinks: finalWeblinks,
                comments: _comments,
              );

      await widget.notesService.saveNote(note);

      if (mounted) {
        Navigator.pop(context);
      }
    } catch (error) {
      setState(() => _saving = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving note: $error')),
        );
      }
    }
  }

  void _addTag() {
    final tag = _tagController.text.trim();
    if (tag.isNotEmpty && !_tags.contains(tag)) {
      setState(() {
        _tags.add(tag);
        _tagController.clear();
      });
    }
  }

  void _removeTag(String tag) {
    setState(() {
      _tags.remove(tag);
    });
  }

  void _addWeblink() {
    final url = _weblinkUrlController.text.trim();
    if (url.isNotEmpty) {
      setState(() {
        _weblinks.add(Weblink(
          url: url,
          title: _weblinkTitleController.text.trim().isEmpty
              ? null
              : _weblinkTitleController.text.trim(),
        ));
        _weblinkUrlController.clear();
        _weblinkTitleController.clear();
      });
    }
  }

  void _removeWeblink(Weblink weblink) {
    setState(() {
      _weblinks.remove(weblink);
    });
  }

  void _addComment(Comment comment) {
    setState(() {
      _comments.add(comment);
    });
  }

  void _removeComment(Comment comment) {
    setState(() {
      _comments.remove(comment);
    });
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.note != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? 'Edit Note' : 'New Note'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _saveNote,
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save'),
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title field
              TextField(
                controller: _titleController,
                decoration: const InputDecoration(
                  labelText: 'Title',
                  border: OutlineInputBorder(),
                ),
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
              ),

              const SizedBox(height: 16),

              // Content field
              TextField(
                controller: _contentController,
                decoration: const InputDecoration(
                  labelText: 'Content',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
                maxLines: 10,
                minLines: 5,
                textAlignVertical: TextAlignVertical.top,
              ),

              const SizedBox(height: 16),

              // Category selection
              StreamBuilder<List<models.Category>>(
                stream: widget.categoriesService.getAllCategories(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const CircularProgressIndicator();
                  }
                  final categories = snapshot.data ?? [];
                  final effectiveSelectedCategoryId = _selectedCategoryId !=
                              null &&
                          categories.every(
                              (category) => category.id != _selectedCategoryId)
                      ? null
                      : _selectedCategoryId;
                  return DropdownButtonFormField<String?>(
                    initialValue: effectiveSelectedCategoryId,
                    decoration: const InputDecoration(
                      labelText: 'Category',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('No Category'),
                      ),
                      ...categories.map((category) => DropdownMenuItem<String>(
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
                    onChanged: (value) {
                      setState(() {
                        _selectedCategoryId = value;
                      });
                    },
                  );
                },
              ),

              const SizedBox(height: 16),

              // Tags section
              const Text(
                'Tags',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
              ),

              const SizedBox(height: 8),

              // Tag input
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _tagController,
                      decoration: const InputDecoration(
                        hintText: 'Add a tag...',
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _addTag(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _addTag,
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              // Tags display
              if (_tags.isNotEmpty) ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: _tags
                      .map((tag) => Chip(
                            label: Text(tag),
                            deleteIcon: const Icon(Icons.close, size: 18),
                            onDeleted: () => _removeTag(tag),
                          ))
                      .toList(),
                ),
              ] else ...[
                const Text(
                  'No tags added',
                  style: TextStyle(color: Colors.grey),
                ),
              ],

              const SizedBox(height: 16),

              // Weblinks section
              const Text(
                'Weblinks',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
              ),

              const SizedBox(height: 8),

              // Weblink input
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: _weblinkUrlController,
                      decoration: const InputDecoration(
                        labelText: 'URL',
                        hintText: 'https://example.com',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 1,
                    child: TextField(
                      controller: _weblinkTitleController,
                      decoration: const InputDecoration(
                        labelText: 'Title (optional)',
                        hintText: 'Link title',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _addWeblink,
                    icon: const Icon(Icons.add),
                    padding: const EdgeInsets.only(top: 8),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              // Weblinks display
              if (_weblinks.isNotEmpty) ...[
                ...(_weblinks.map((weblink) => Card(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      child: ListTile(
                        leading: const Icon(Icons.link),
                        title: Text(weblink.title ?? weblink.url),
                        subtitle:
                            weblink.title != null ? Text(weblink.url) : null,
                        trailing: IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => _removeWeblink(weblink),
                        ),
                        onTap: () {
                          // Could add URL launcher here
                        },
                      ),
                    ))),
              ] else ...[
                const Text(
                  'No weblinks added',
                  style: TextStyle(color: Colors.grey),
                ),
              ],

              const SizedBox(height: 16),

              // Comments section
              CommentSection(
                comments: _comments,
                onAddComment: _addComment,
                onRemoveComment: _removeComment,
              ),

              const SizedBox(height: 16),

              // Offline-first info
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.withAlpha(50),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue.withAlpha(100)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.info_outline, color: Colors.blue, size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Changes are saved locally and will sync automatically when connected to your Solid Pod.',
                        style: TextStyle(fontSize: 12, color: Colors.blue),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
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
}
