import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../../services/providers.dart';
import '../widgets/todo_tile.dart';
import 'devices_screen.dart';
import 'todo_edit_sheet.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    Future.microtask(_bootSync);
  }

  Future<void> _bootSync() async {
    final engine = await ref.read(syncEngineProvider.future);
    await engine.start();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final todosAsync = ref.watch(todosProvider);
    final filter = ref.watch(todoFilterProvider);
    final lists = ref.watch(listsProvider).value ?? const <TodoList>[];
    final pairedPeers = ref.watch(pairedPeersProvider).value ?? const [];
    final discovered = ref.watch(discoveredPeersProvider).value ?? const [];
    final onlinePaired = pairedPeers
        .where((p) => discovered.any((d) => d.deviceId == p.id))
        .length;
    final selectedList = lists
        .where((l) => l.id == filter.listId)
        .cast<TodoList?>()
        .firstOrNull;

    return Scaffold(
      appBar: AppBar(
        title: Text(selectedList?.name ?? 'All todos'),
        actions: [
          IconButton(
            tooltip: filter.showDone ? 'Hide completed' : 'Show completed',
            icon: Icon(
              filter.showDone ? Icons.check_circle : Icons.check_circle_outline,
            ),
            onPressed: () => ref
                .read(todoFilterProvider.notifier)
                .update((f) => f.copyWith(showDone: !f.showDone)),
          ),
          IconButton(
            tooltip: pairedPeers.isEmpty
                ? 'Devices (none paired)'
                : 'Devices ($onlinePaired/${pairedPeers.length} online)',
            icon: Badge(
              isLabelVisible: pairedPeers.isNotEmpty,
              label: Text('$onlinePaired'),
              backgroundColor: onlinePaired > 0 ? Colors.green : Colors.grey,
              child: const Icon(Icons.devices),
            ),
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const DevicesScreen())),
          ),
        ],
      ),
      drawer: _ListsDrawer(),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Search…',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchCtrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchCtrl.clear();
                          ref
                              .read(todoFilterProvider.notifier)
                              .update((f) => f.copyWith(search: ''));
                        },
                      ),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onChanged: (v) => ref
                  .read(todoFilterProvider.notifier)
                  .update((f) => f.copyWith(search: v)),
            ),
          ),
          Expanded(
            child: todosAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Error: $e')),
              data: (todos) {
                if (todos.isEmpty) {
                  return const _EmptyState();
                }
                return ListView.separated(
                  itemCount: todos.length,
                  separatorBuilder: (_, _) => const Divider(height: 0),
                  itemBuilder: (_, i) => TodoTile(
                    todo: todos[i],
                    onTap: () => showTodoEditSheet(context, todo: todos[i]),
                  ),
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showTodoEditSheet(context),
        icon: const Icon(Icons.add),
        label: const Text('New todo'),
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
          Icon(
            Icons.check_circle_outline,
            size: 64,
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          const SizedBox(height: 12),
          const Text('Nothing here yet.'),
          const SizedBox(height: 4),
          Text(
            'Tap "New todo" to get started.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _ListsDrawer extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lists = ref.watch(listsProvider);
    final filter = ref.watch(todoFilterProvider);
    final mutationsAsync = ref.watch(mutationServiceProvider);

    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text(
                'Lists',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.inbox),
              title: const Text('All'),
              selected: filter.listId == null,
              onTap: () {
                ref
                    .read(todoFilterProvider.notifier)
                    .update((f) => f.copyWith(listId: null));
                Navigator.of(context).pop();
              },
            ),
            const Divider(),
            Expanded(
              child: lists.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text('Error: $e')),
                data: (data) => ListView(
                  children: [
                    for (final l in data)
                      ListTile(
                        leading: const Icon(Icons.list_alt),
                        title: Text(l.name),
                        selected: filter.listId == l.id,
                        onTap: () {
                          ref
                              .read(todoFilterProvider.notifier)
                              .update((f) => f.copyWith(listId: l.id));
                          Navigator.of(context).pop();
                        },
                        onLongPress: () async {
                          final m = await ref.read(
                            mutationServiceProvider.future,
                          );
                          await m.deleteList(l.id);
                        },
                      ),
                  ],
                ),
              ),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('New list'),
              onTap: mutationsAsync.maybeWhen(
                data: (m) => () async {
                  final name = await _promptListName(context);
                  if (name != null && name.trim().isNotEmpty) {
                    await m.createList(name: name.trim());
                  }
                },
                orElse: () => null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<String?> _promptListName(BuildContext context) async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New list'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'List name'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }
}
