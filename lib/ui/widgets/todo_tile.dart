import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/database.dart';
import '../../services/providers.dart';

class TodoTile extends ConsumerWidget {
  const TodoTile({
    super.key,
    required this.todo,
    required this.onTap,
  });

  final Todo todo;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tagsAsync = ref.watch(tagsForTodoProvider(todo.id));
    final mutationsAsync = ref.watch(mutationServiceProvider);

    return ListTile(
      onTap: onTap,
      leading: Checkbox(
        value: todo.done,
        onChanged: mutationsAsync.maybeWhen(
          data: (m) => (v) => m.toggleTodo(todo.id, v ?? false),
          orElse: () => null,
        ),
      ),
      title: Text(
        todo.title,
        style: TextStyle(
          decoration: todo.done ? TextDecoration.lineThrough : null,
          color: todo.done
              ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5)
              : null,
        ),
      ),
      subtitle: _buildSubtitle(context, tagsAsync.value ?? const []),
      trailing: _PriorityDot(priority: todo.priority),
    );
  }

  Widget? _buildSubtitle(BuildContext context, List<Tag> tags) {
    final parts = <String>[];
    if (todo.dueAt != null) {
      parts.add(DateFormat.yMMMd().add_Hm().format(todo.dueAt!.toLocal()));
    }
    if (tags.isNotEmpty) {
      parts.add(tags.map((t) => '#${t.name}').join(' '));
    }
    if (todo.description != null && todo.description!.trim().isNotEmpty) {
      parts.add(todo.description!.trim());
    }
    if (parts.isEmpty) return null;
    return Text(
      parts.join(' • '),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _PriorityDot extends StatelessWidget {
  const _PriorityDot({required this.priority});
  final int priority;

  @override
  Widget build(BuildContext context) {
    final color = switch (priority) {
      >= 2 => Colors.redAccent,
      1 => Colors.amber,
      _ => Colors.blueGrey,
    };
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
