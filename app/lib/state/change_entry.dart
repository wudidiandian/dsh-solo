import 'dart:convert';
import 'dart:typed_data';

import '../protocol/envelope.dart';

/// 会话内 Agent 的文件变更记录（Diff 查看器数据源，2026-10-28）
///
/// 数据来源（宿主 session/event）：
/// - `tool/result.meta.diffs`：dsh-tool-fs 写入/编辑工具自带的 hunks
///   （`[{path, oldText, newText}]`，oldText=null 表示新建），最权威
/// - `tool/call.arguments` 兜底：write/edit/str_replace_editor 的参数里
///   自带前后文（实机核实自 dsh-client-ui-tool diff-card-model 同款逻辑）
class ChangeEntry {
  const ChangeEntry({
    required this.path,
    required this.newText,
    this.oldText,
    required this.tool,
  });

  /// 文件路径（绝对或相对工作区）
  final String path;

  /// 变更前文本；null = 新建文件
  final String? oldText;

  /// 变更后文本
  final String newText;

  /// 产生变更的工具名（write / edit / str_replace_editor）
  final String tool;

  bool get isCreate => oldText == null;
}

/// 一行 diff（same/added/removed）
class DiffLine {
  const DiffLine(this.type, this.text);

  final String type;
  final String text;
}

/// 从会话事件流提取文件变更（按事件顺序）。
/// tool/result.meta.diffs 优先并抑制同 turn:step 的 call 兜底。
List<ChangeEntry> extractChanges(List<Envelope> events) {
  final out = <ChangeEntry?>[];
  final callIndex = <String, int>{}; // 'turn:step' → out 下标

  for (final env in events) {
    if (env.type != MsgType.sessionEvent) continue;
    final p = env.payloadMap;
    final kind = p['kind']?.toString();
    final data = p['data'];
    if (data is! Map) continue;
    final stepKey = '${data['turn']}:${data['step']}';

    if (kind == 'tool/call') {
      final e = _entryFromCall(data);
      if (e != null) {
        callIndex[stepKey] = out.length;
        out.add(e);
      }
    } else if (kind == 'tool/result') {
      final diffs = _metaDiffs(data);
      if (diffs.isEmpty) continue;
      // meta.diffs 权威：丢弃该 step 的 call 兜底条目
      final i = callIndex.remove(stepKey);
      if (i != null && i < out.length) out[i] = null;
      out.addAll(diffs);
    }
  }
  return out.whereType<ChangeEntry>().toList();
}

/// 从 tool/call 参数提取变更；非文件写入工具返回 null
ChangeEntry? _entryFromCall(Map data) {
  final name = data['name']?.toString() ?? '';
  final argsRaw = data['arguments'];
  if (argsRaw is! String || argsRaw.isEmpty) return null;
  try {
    final decoded = jsonDecode(argsRaw);
    if (decoded is! Map) return null;
    return _entryFromArgs(
        name, decoded.map((k, v) => MapEntry(k.toString(), v)));
  } on FormatException {
    return null;
  }
}

/// JSON 字符串参数 → ChangeEntry
ChangeEntry? _entryFromArgs(String tool, Map<String, dynamic> args) {
  if (tool == 'write') {
    final path = args['file_path']?.toString() ?? '';
    final content = args['content'];
    if (path.isEmpty || content is! String) return null;
    return ChangeEntry(path: path, oldText: null, newText: content, tool: tool);
  }
  if (tool == 'edit') {
    final path = args['file_path']?.toString() ?? '';
    final oldText = args['old_str'];
    final newText = args['new_str'];
    if (path.isEmpty || oldText is! String || newText is! String) return null;
    return ChangeEntry(path: path, oldText: oldText, newText: newText, tool: tool);
  }
  if (tool == 'str_replace_editor') {
    final command = args['command']?.toString() ?? '';
    final path = args['path']?.toString() ?? '';
    if (path.isEmpty) return null;
    if (command == 'create') {
      final ft = args['file_text'];
      if (ft is! String) return null;
      return ChangeEntry(path: path, oldText: null, newText: ft, tool: tool);
    }
    if (command == 'str_replace') {
      final oldText = args['old_str'];
      final newText = args['new_str'];
      if (oldText is! String || newText is! String) return null;
      return ChangeEntry(path: path, oldText: oldText, newText: newText, tool: tool);
    }
  }
  return null;
}

/// tool/result.meta.diffs → ChangeEntry 列表（结构不合法返回空）
List<ChangeEntry> _metaDiffs(Map data) {
  final meta = data['meta'];
  if (meta is! Map) return const [];
  final diffs = meta['diffs'];
  if (diffs is! List) return const [];
  final out = <ChangeEntry>[];
  for (final hunk in diffs) {
    if (hunk is! Map) continue;
    final path = hunk['path']?.toString() ?? '';
    final oldText = hunk['oldText'];
    final newText = hunk['newText'];
    if (path.isEmpty || newText is! String) continue;
    if (oldText != null && oldText is! String) continue;
    out.add(ChangeEntry(
      path: path,
      oldText: oldText == null ? null : oldText as String,
      newText: newText,
      tool: 'fs',
    ));
  }
  return out;
}

/// 行级 LCS diff（文本行数超上限时退化为“仅新增”展示）
List<DiffLine> diffLines(String? oldText, String newText, {int maxLines = 2000}) {
  final newLines = newText.split('\n');
  if (oldText == null || oldText.isEmpty) {
    return [for (final l in newLines) DiffLine('added', l)];
  }
  final oldLines = oldText.split('\n');

  // 超长保护：LCS O(n*m)，>2000 行直接全标新增
  if (oldLines.length > maxLines || newLines.length > maxLines) {
    return [for (final l in newLines) DiffLine('added', l)];
  }

  // 经典 DP LCS 表
  final n = oldLines.length, m = newLines.length;
  final dp = List.generate(n + 1, (_) => Uint32List(m + 1));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      dp[i][j] = oldLines[i] == newLines[j]
          ? dp[i + 1][j + 1] + 1
          : (dp[i + 1][j] >= dp[i][j + 1] ? dp[i + 1][j] : dp[i][j + 1]);
    }
  }

  final out = <DiffLine>[];
  var i = 0, j = 0;
  while (i < n && j < m) {
    if (oldLines[i] == newLines[j]) {
      out.add(DiffLine('same', newLines[j]));
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      out.add(DiffLine('removed', oldLines[i]));
      i++;
    } else {
      out.add(DiffLine('added', newLines[j]));
      j++;
    }
  }
  while (i < n) {
    out.add(DiffLine('removed', oldLines[i]));
    i++;
  }
  while (j < m) {
    out.add(DiffLine('added', newLines[j]));
    j++;
  }
  return out;
}
