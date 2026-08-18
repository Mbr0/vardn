import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/database.dart';
import '../../services/providers.dart';
import 'devices_screen.dart';
import 'note_editor_screen.dart';

class NotesScreen extends ConsumerStatefulWidget {
  const NotesScreen({super.key});

  @override
  ConsumerState<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends ConsumerState<NotesScreen> {
  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _newNote() async {
    final m = await ref.read(mutationServiceProvider.future);
    final note = await m.createNote();
    // Start every note with one empty text block so the editor has a caret.
    await m.createBlock(noteId: note.id, position: 1);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => NoteEditorScreen(noteId: note.id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final notesAsync = ref.watch(notesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notes'),
        actions: [
          IconButton(
            tooltip: 'Devices',
            icon: const Icon(Icons.devices),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const DevicesScreen())),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Search notes…',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchCtrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchCtrl.clear();
                          ref.read(noteSearchProvider.notifier).state = '';
                        },
                      ),
                isDense: true,
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onChanged: (v) =>
                  ref.read(noteSearchProvider.notifier).state = v,
            ),
          ),
          Expanded(
            child: notesAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Error: $e')),
              data: (notes) {
                if (notes.isEmpty) return const _EmptyState();
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 88),
                  itemCount: notes.length,
                  itemBuilder: (_, i) => _NoteCard(note: notes[i]),
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newNote,
        icon: const Icon(Icons.add),
        label: const Text('New note'),
      ),
    );
  }
}

class _NoteCard extends ConsumerWidget {
  const _NoteCard({required this.note});
  final Note note;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blocks = ref.watch(noteBlocksProvider(note.id)).value ?? const [];
    final preview = blocks
        .where((b) => b.type != 'checklist' && b.content.trim().isNotEmpty)
        .map((b) => b.content.trim())
        .firstOrNull;
    final checklist = blocks.where((b) => b.type == 'checklist').toList();
    final checked = checklist.where((b) => b.checked).length;

    return Card(
      child: ListTile(
        title: Row(
          children: [
            if (note.pinned)
              const Padding(
                padding: EdgeInsets.only(right: 6),
                child: Icon(Icons.push_pin, size: 16),
              ),
            Expanded(
              child: Text(
                note.title.isEmpty ? 'Untitled' : note.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: note.title.isEmpty
                    ? TextStyle(
                        color: Theme.of(context).colorScheme.outline,
                        fontStyle: FontStyle.italic)
                    : null,
              ),
            ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (preview != null)
              Text(preview, maxLines: 2, overflow: TextOverflow.ellipsis),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                [
                  if (checklist.isNotEmpty) '☑ $checked/${checklist.length}',
                  DateFormat.yMd().add_Hm().format(note.updatedAt.toLocal()),
                ].join(' · '),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => NoteEditorScreen(noteId: note.id)),
        ),
        onLongPress: () async {
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Delete note?'),
              content: Text(note.title.isEmpty ? 'Untitled' : note.title),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('Delete'),
                ),
              ],
            ),
          );
          if (confirmed != true) return;
          final m = await ref.read(mutationServiceProvider.future);
          await m.deleteNote(note.id);
        },
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.sticky_note_2_outlined,
              size: 64, color: Theme.of(context).colorScheme.outlineVariant),
          const SizedBox(height: 12),
          const Text('No notes yet.'),
          const SizedBox(height: 4),
          Text('Tap "New note" to get started.',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
