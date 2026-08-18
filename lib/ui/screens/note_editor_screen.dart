import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/database.dart';
import '../../services/blobs/blob_store.dart';
import '../../services/mutation_service.dart';
import '../../services/providers.dart';

/// Full-screen block editor for one note: a title plus an ordered list of
/// text / checklist / link blocks. Edits are saved with a short debounce, so
/// each pause becomes one mutation event rather than one per keystroke.
class NoteEditorScreen extends ConsumerStatefulWidget {
  const NoteEditorScreen({super.key, required this.noteId});
  final String noteId;

  @override
  ConsumerState<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

class _NoteEditorScreenState extends ConsumerState<NoteEditorScreen> {
  final _titleCtrl = TextEditingController();
  final _titleFocus = FocusNode();
  Timer? _titleDebounce;

  @override
  void dispose() {
    _titleDebounce?.cancel();
    _titleCtrl.dispose();
    _titleFocus.dispose();
    super.dispose();
  }

  Future<MutationService> get _mutations =>
      ref.read(mutationServiceProvider.future);

  void _onTitleChanged(String value) {
    _titleDebounce?.cancel();
    _titleDebounce = Timer(const Duration(milliseconds: 600), () async {
      (await _mutations).updateNote(widget.noteId, title: value.trim());
    });
  }

  Future<void> _addBlock(List<NoteBlock> blocks, String type) async {
    if (type == 'image') return _addImage(blocks);
    final last = blocks.isEmpty ? 0.0 : blocks.last.position;
    await (await _mutations)
        .createBlock(noteId: widget.noteId, type: type, position: last + 1);
  }

  Future<void> _addImage(List<NoteBlock> blocks) async {
    // Resize on pick so a phone photo becomes a few hundred KB, not 10 MB —
    // these bytes get replicated to every paired device.
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 2048,
      maxHeight: 2048,
      imageQuality: 85,
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    final store = await ref.read(blobStoreProvider.future);
    final hash = await store.put(bytes);
    final last = blocks.isEmpty ? 0.0 : blocks.last.position;
    await (await _mutations).createBlock(
      noteId: widget.noteId,
      type: 'image',
      content: hash,
      position: last + 1,
    );
  }

  Future<void> _reorder(List<NoteBlock> blocks, int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) newIndex--;
    if (newIndex == oldIndex) return;
    final moved = blocks[oldIndex];
    final without = [...blocks]..removeAt(oldIndex);
    // Fractional indexing: land between the new neighbours.
    final before = newIndex == 0 ? null : without[newIndex - 1].position;
    final after = newIndex >= without.length ? null : without[newIndex].position;
    final double position;
    if (before == null && after == null) {
      position = 1;
    } else if (before == null) {
      position = after! - 1;
    } else if (after == null) {
      position = before + 1;
    } else {
      position = (before + after) / 2;
    }
    await (await _mutations).updateBlock(moved.id, position: position);
  }

  @override
  Widget build(BuildContext context) {
    final note = ref.watch(noteProvider(widget.noteId)).value;
    final blocks = ref.watch(noteBlocksProvider(widget.noteId)).value ?? const [];

    // Keep the title field in sync with remote edits, but never while typing.
    final title = note?.title ?? '';
    if (!_titleFocus.hasFocus && _titleCtrl.text != title) {
      _titleCtrl.text = title;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Note'),
        actions: [
          IconButton(
            tooltip: (note?.pinned ?? false) ? 'Unpin' : 'Pin',
            icon: Icon((note?.pinned ?? false)
                ? Icons.push_pin
                : Icons.push_pin_outlined),
            onPressed: () async => (await _mutations)
                .updateNote(widget.noteId, pinned: !(note?.pinned ?? false)),
          ),
          IconButton(
            tooltip: 'Delete note',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              final m = await _mutations;
              await m.deleteNote(widget.noteId);
              if (context.mounted) Navigator.of(context).pop();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              controller: _titleCtrl,
              focusNode: _titleFocus,
              style: Theme.of(context).textTheme.headlineSmall,
              decoration: const InputDecoration(
                hintText: 'Title',
                border: InputBorder.none,
              ),
              onChanged: _onTitleChanged,
            ),
          ),
          Expanded(
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              padding: const EdgeInsets.only(bottom: 24),
              itemCount: blocks.length,
              // onReorderItem is too new for the oldest Flutter we support.
              // ignore: deprecated_member_use
              onReorder: (o, n) => _reorder(blocks, o, n),
              itemBuilder: (_, i) => _BlockTile(
                key: ValueKey(blocks[i].id),
                block: blocks[i],
                index: i,
              ),
            ),
          ),
          _AddBlockBar(onAdd: (type) => _addBlock(blocks, type)),
        ],
      ),
    );
  }
}

class _AddBlockBar extends StatelessWidget {
  const _AddBlockBar({required this.onAdd});
  final void Function(String type) onAdd;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            TextButton.icon(
              icon: const Icon(Icons.notes),
              label: const Text('Text'),
              onPressed: () => onAdd('text'),
            ),
            TextButton.icon(
              icon: const Icon(Icons.check_box_outlined),
              label: const Text('Checklist'),
              onPressed: () => onAdd('checklist'),
            ),
            TextButton.icon(
              icon: const Icon(Icons.link),
              label: const Text('Link'),
              onPressed: () => onAdd('link'),
            ),
            TextButton.icon(
              icon: const Icon(Icons.image_outlined),
              label: const Text('Image'),
              onPressed: () => onAdd('image'),
            ),
          ],
        ),
      ),
    );
  }
}

class _BlockTile extends ConsumerStatefulWidget {
  const _BlockTile({super.key, required this.block, required this.index});
  final NoteBlock block;
  final int index;

  @override
  ConsumerState<_BlockTile> createState() => _BlockTileState();
}

class _BlockTileState extends ConsumerState<_BlockTile> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.block.content);
  final _focus = FocusNode();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<MutationService> get _mutations =>
      ref.read(mutationServiceProvider.future);

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () async {
      (await _mutations).updateBlock(widget.block.id, content: value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final block = widget.block;
    if (block.type == 'image') return _buildImage(context, block);
    // Accept remote edits only while this block isn't being typed in.
    if (!_focus.hasFocus && _ctrl.text != block.content) {
      _ctrl.text = block.content;
    }

    final field = TextField(
      controller: _ctrl,
      focusNode: _focus,
      maxLines: null,
      keyboardType:
          block.type == 'link' ? TextInputType.url : TextInputType.multiline,
      style: switch (block.type) {
        'checklist' when block.checked => const TextStyle(
            decoration: TextDecoration.lineThrough, color: Colors.grey),
        'link' => TextStyle(
            color: Theme.of(context).colorScheme.primary,
            decoration: TextDecoration.underline),
        _ => const TextStyle(),
      },
      decoration: InputDecoration(
        hintText: switch (block.type) {
          'checklist' => 'List item',
          'link' => 'https://…',
          _ => 'Write something…',
        },
        border: InputBorder.none,
        isDense: true,
      ),
      onChanged: _onChanged,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ReorderableDragStartListener(
            index: widget.index,
            child: Padding(
              padding: const EdgeInsets.only(top: 12, left: 4, right: 4),
              child: Icon(Icons.drag_indicator,
                  size: 18, color: Theme.of(context).colorScheme.outlineVariant),
            ),
          ),
          if (block.type == 'checklist')
            Checkbox(
              value: block.checked,
              onChanged: (v) async => (await _mutations)
                  .updateBlock(block.id, checked: v ?? false),
            )
          else if (block.type == 'link')
            Padding(
              padding: const EdgeInsets.only(top: 12, right: 4),
              child: Icon(Icons.link,
                  size: 18, color: Theme.of(context).colorScheme.primary),
            ),
          Expanded(child: field),
          if (block.type == 'link' && block.content.trim().isNotEmpty)
            IconButton(
              tooltip: 'Open link',
              icon: const Icon(Icons.open_in_new, size: 18),
              onPressed: () => _openLink(context, block.content),
            ),
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert,
                size: 18, color: Theme.of(context).colorScheme.outlineVariant),
            onSelected: (value) async {
              final m = await _mutations;
              if (value == 'delete') {
                await m.deleteBlock(block.id);
              } else {
                await m.updateBlock(block.id, type: value);
              }
            },
            itemBuilder: (_) => [
              if (block.type != 'text')
                const PopupMenuItem(value: 'text', child: Text('Make text')),
              if (block.type != 'checklist')
                const PopupMenuItem(
                    value: 'checklist', child: Text('Make checklist')),
              if (block.type != 'link')
                const PopupMenuItem(value: 'link', child: Text('Make link')),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _openLink(BuildContext context, String raw) async {
    var text = raw.trim();
    if (!text.contains('://')) text = 'https://$text';
    final uri = Uri.tryParse(text);
    final ok = uri != null &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open link')),
      );
    }
  }

  Widget _buildImage(BuildContext context, NoteBlock block) {
    final storeAsync = ref.watch(blobStoreProvider);
    final store = storeAsync.value;
    final file = store != null && BlobStore.looksLikeHash(block.content)
        ? store.fileFor(block.content)
        : null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ReorderableDragStartListener(
            index: widget.index,
            child: Padding(
              padding: const EdgeInsets.only(top: 12, left: 4, right: 4),
              child: Icon(Icons.drag_indicator,
                  size: 18, color: Theme.of(context).colorScheme.outlineVariant),
            ),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: file != null && file.existsSync()
                  ? GestureDetector(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              _ImageViewerScreen(file: file, tag: block.id),
                        ),
                      ),
                      child: Hero(
                        tag: block.id,
                        child: Image.file(file, fit: BoxFit.fitWidth),
                      ),
                    )
                  : Container(
                      height: 140,
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.cloud_download_outlined),
                          const SizedBox(height: 8),
                          Text('Image syncing…',
                              style: Theme.of(context).textTheme.bodySmall),
                        ],
                      ),
                    ),
            ),
          ),
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert,
                size: 18, color: Theme.of(context).colorScheme.outlineVariant),
            onSelected: (value) async {
              if (value == 'delete') {
                await (await _mutations).deleteBlock(block.id);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
    );
  }
}

/// Full-screen, pinch-zoomable image view. Tap anywhere to close.
class _ImageViewerScreen extends StatelessWidget {
  const _ImageViewerScreen({required this.file, required this.tag});
  final File file;
  final Object tag;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: Center(
          child: InteractiveViewer(
            maxScale: 6,
            child: Hero(tag: tag, child: Image.file(file)),
          ),
        ),
      ),
    );
  }
}
