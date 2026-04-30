import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../../services/providers.dart';

class TodoEditSheet extends ConsumerStatefulWidget {
  const TodoEditSheet({super.key, this.todo});

  final Todo? todo;

  @override
  ConsumerState<TodoEditSheet> createState() => _TodoEditSheetState();
}

class _TodoEditSheetState extends ConsumerState<TodoEditSheet> {
  late final TextEditingController _title;
  late final TextEditingController _description;
  late final TextEditingController _tags;
  String? _listId;
  DateTime? _dueAt;
  int _priority = 1;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    final t = widget.todo;
    _title = TextEditingController(text: t?.title ?? '');
    _description = TextEditingController(text: t?.description ?? '');
    _tags = TextEditingController();
    _listId = t?.listId;
    _dueAt = t?.dueAt;
    _priority = t?.priority ?? 1;
    _done = t?.done ?? false;
    if (t != null) {
      Future.microtask(() async {
        final tags = await ref.read(tagsForTodoProvider(t.id).future);
        if (mounted) {
          _tags.text = tags.map((e) => e.name).join(', ');
        }
      });
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _tags.dispose();
    super.dispose();
  }

  Future<void> _pickDueDate() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _dueAt ?? now,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now.add(const Duration(days: 365 * 5)),
    );
    if (date == null) return;
    final time = await showTimePicker(
      // ignore: use_build_context_synchronously
      context: context,
      initialTime: TimeOfDay.fromDateTime(_dueAt ?? now.add(const Duration(hours: 1))),
    );
    if (time == null) return;
    setState(() {
      _dueAt = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    final mutations = await ref.read(mutationServiceProvider.future);
    final tagNames = _tags.text
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet();

    final existing = widget.todo;
    if (existing == null) {
      final created = await mutations.createTodo(
        title: title,
        description: _description.text.trim().isEmpty ? null : _description.text.trim(),
        listId: _listId,
        dueAt: _dueAt,
        priority: _priority,
      );
      for (final tag in tagNames) {
        await mutations.addTagToTodo(created.id, tag);
      }
    } else {
      await mutations.updateTodo(
        existing.id,
        title: title,
        description: _description.text.trim().isEmpty ? null : _description.text.trim(),
        listId: _listId,
        clearListId: _listId == null,
        dueAt: _dueAt,
        clearDueAt: _dueAt == null,
        priority: _priority,
        done: _done,
      );
      final current = await ref.read(tagsForTodoProvider(existing.id).future);
      final currentNames = current.map((t) => t.name).toSet();
      for (final t in tagNames.difference(currentNames)) {
        await mutations.addTagToTodo(existing.id, t);
      }
      for (final t in currentNames.difference(tagNames)) {
        await mutations.removeTagFromTodo(existing.id, t);
      }
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final t = widget.todo;
    if (t == null) return;
    final mutations = await ref.read(mutationServiceProvider.future);
    await mutations.deleteTodo(t.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final lists = ref.watch(listsProvider).value ?? const <TodoList>[];
    final isNew = widget.todo == null;
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(isNew ? 'New todo' : 'Edit todo', style: theme.textTheme.titleLarge),
            const SizedBox(height: 16),
            TextField(
              controller: _title,
              autofocus: isNew,
              decoration: const InputDecoration(labelText: 'Title'),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _description,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Notes'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _tags,
              decoration: const InputDecoration(
                labelText: 'Tags (comma separated)',
                hintText: 'home, urgent',
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              initialValue: _listId,
              decoration: const InputDecoration(labelText: 'List'),
              items: [
                const DropdownMenuItem(value: null, child: Text('— none —')),
                for (final l in lists)
                  DropdownMenuItem(value: l.id, child: Text(l.name)),
              ],
              onChanged: (v) => setState(() => _listId = v),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickDueDate,
                    icon: const Icon(Icons.event),
                    label: Text(_dueAt == null
                        ? 'No due date'
                        : '${_dueAt!.toLocal()}'.split('.').first),
                  ),
                ),
                if (_dueAt != null)
                  IconButton(
                    onPressed: () => setState(() => _dueAt = null),
                    icon: const Icon(Icons.clear),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('Priority'),
                const SizedBox(width: 12),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 0, label: Text('Low')),
                    ButtonSegment(value: 1, label: Text('Med')),
                    ButtonSegment(value: 2, label: Text('High')),
                  ],
                  selected: {_priority},
                  onSelectionChanged: (s) => setState(() => _priority = s.first),
                ),
              ],
            ),
            if (!isNew) ...[
              const SizedBox(height: 12),
              SwitchListTile(
                title: const Text('Done'),
                value: _done,
                onChanged: (v) => setState(() => _done = v),
              ),
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                if (!isNew)
                  TextButton.icon(
                    onPressed: _delete,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete'),
                    style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
                  ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _save, child: const Text('Save')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> showTodoEditSheet(BuildContext context, {Todo? todo}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => TodoEditSheet(todo: todo),
  );
}
