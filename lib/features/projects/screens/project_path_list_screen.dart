import 'package:flutter/material.dart';

import '../../../app_state_scope.dart';
import '../models/project_path_config.dart';

class ProjectPathListScreen extends StatelessWidget {
  const ProjectPathListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Project Paths')),
      body: state.projectPaths.isEmpty
          ? const Center(child: Text('暂无 Project Path'))
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: state.projectPaths.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final item = state.projectPaths[index];
                return ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(color: Colors.grey.shade300),
                  ),
                  title: Text(item.name),
                  subtitle: Text(item.path),
                  leading: Icon(
                    item.isDefault
                        ? Icons.folder_special_outlined
                        : Icons.folder_outlined,
                  ),
                  trailing: IconButton(
                    tooltip: 'Delete',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _confirmDelete(context, item),
                  ),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            ProjectPathFormScreen(projectPath: item),
                      ),
                    );
                  },
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Add Path'),
        onPressed: () {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const ProjectPathFormScreen(),
            ),
          );
        },
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    ProjectPathConfig item,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('删除 Project Path?'),
          content: Text(item.path),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
    if (confirmed == true && context.mounted) {
      await AppStateScope.of(context).deleteProjectPath(item.id);
    }
  }
}

class ProjectPathFormScreen extends StatefulWidget {
  const ProjectPathFormScreen({this.projectPath, super.key});

  final ProjectPathConfig? projectPath;

  @override
  State<ProjectPathFormScreen> createState() => _ProjectPathFormScreenState();
}

class _ProjectPathFormScreenState extends State<ProjectPathFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _pathController;
  bool _isDefault = false;

  @override
  void initState() {
    super.initState();
    final projectPath = widget.projectPath;
    _nameController = TextEditingController(text: projectPath?.name ?? '');
    _pathController = TextEditingController(text: projectPath?.path ?? '');
    _isDefault = projectPath?.isDefault ?? false;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _pathController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.projectPath == null
            ? 'Add Project Path'
            : 'Edit Project Path'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Name'),
              validator: _required,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _pathController,
              decoration: const InputDecoration(
                labelText: 'Remote project path',
                hintText: '/path/to/repo',
              ),
              validator: _required,
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              title: const Text('设为默认 Project Path'),
              value: _isDefault,
              onChanged: (value) => setState(() => _isDefault = value),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              icon: const Icon(Icons.save_outlined),
              label: const Text('Save Project Path'),
              onPressed: _save,
            ),
          ],
        ),
      ),
    );
  }

  String? _required(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Required';
    }
    return null;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    final state = AppStateScope.of(context);
    final now = DateTime.now();
    final existing = widget.projectPath;
    final item = ProjectPathConfig(
      id: existing?.id ?? 'project-${now.microsecondsSinceEpoch}',
      name: _nameController.text.trim(),
      path: normalizeRemoteProjectPath(_pathController.text),
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
      isDefault: _isDefault || state.projectPaths.isEmpty,
    );

    if (item.isDefault) {
      for (final path in state.projectPaths) {
        if (path.id != item.id && path.isDefault) {
          await state.saveProjectPath(path.copyWith(isDefault: false));
        }
      }
    }
    await state.saveProjectPath(item);
    if (mounted) {
      Navigator.of(context).pop();
    }
  }
}
