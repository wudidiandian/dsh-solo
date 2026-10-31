/// 深层目录浏览页：点击快照目录后按需通过 RPC 逐层读取子项。
import 'package:flutter/material.dart';

import '../l10n/app_l10n.dart';
import '../state/app_state.dart';

/// 目录浏览页（每页一层，点击子目录继续深入）
class DirBrowserPage extends StatefulWidget {
  const DirBrowserPage({
    super.key,
    required this.state,
    required this.path,
    required this.title,
  });

  final AppState state;
  final String path;
  final String title;

  @override
  State<DirBrowserPage> createState() => _DirBrowserPageState();
}

class _DirBrowserPageState extends State<DirBrowserPage> {
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Map<String, dynamic>>> _load() async {
    final resp = await widget.state.listDir(widget.path);
    final result = resp.payloadMap['result'];
    if (result is! List) return const [];
    return result
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(AppL10n.i.readFailed(snap.error!),
                    style: const TextStyle(color: Colors.red), textAlign: TextAlign.center),
              ),
            );
          }
          final items = snap.data ?? const [];
          if (items.isEmpty) return Center(child: Text(AppL10n.i.emptyDir));
          return ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, i) {
              final e = items[i];
              final isDir = e['type'] == 'dir';
              return ListTile(
                dense: true,
                leading: Icon(
                  isDir ? Icons.folder_outlined : Icons.insert_drive_file_outlined,
                  size: 20,
                ),
                title: Text((e['name'] ?? '').toString(),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: isDir ? const Icon(Icons.chevron_right) : null,
                onTap: isDir
                    ? () => Navigator.of(context).push(MaterialPageRoute<void>(
                          builder: (_) => DirBrowserPage(
                            state: widget.state,
                            path: (e['path'] ?? '').toString(),
                            title: (e['name'] ?? '').toString(),
                          ),
                        ))
                    : null,
              );
            },
          );
        },
      ),
    );
  }
}
