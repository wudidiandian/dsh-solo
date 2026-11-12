import 'package:flutter/material.dart';

import '../l10n/app_l10n.dart';

/// A live request, outside the paged/frozen historical timeline.
class InteractionCard extends StatefulWidget {
  const InteractionCard({
    super.key,
    required this.request,
    required this.onRespond,
  });
  final Map<String, dynamic> request;
  final Future<void> Function(Map<String, Object?> response) onRespond;
  @override
  State<InteractionCard> createState() => _InteractionCardState();
}

class _InteractionCardState extends State<InteractionCard> {
  final _selected = <String, Set<String>>{};
  final _custom = <String, TextEditingController>{};
  bool _sending = false;
  String? _error;
  bool get _approval => widget.request['type'] == 'approval';
  String tr(String zh, String en) => AppL10n.i.isEn ? en : zh;
  List<Map> get _questions =>
      (widget.request['questions'] as List? ?? []).whereType<Map>().toList();

  Future<void> _submit(Map<String, Object?> response) async {
    if (_sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.onRespond(response);
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = tr('提交失败：', 'Submission failed: ') + e.toString(),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  bool get _complete => _questions.every((q) {
    final id = q['id'].toString();
    return (_selected[id]?.isNotEmpty ?? false) ||
        (_custom[id]?.text.trim().isNotEmpty ?? false);
  });

  @override
  void dispose() {
    for (final controller in _custom.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Card(
    color: _approval
        ? Theme.of(context).colorScheme.tertiaryContainer
        : Theme.of(context).colorScheme.surfaceContainerHigh,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _approval
                ? tr('等待权限审批', 'Permission approval required')
                : tr('等待你的回答', 'Your answer is needed'),
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          if (_approval) ...[
            Text(widget.request['toolName']?.toString() ?? ''),
            if ((widget.request['reason']?.toString() ?? '').isNotEmpty)
              SelectionArea(child: Text(widget.request['reason'].toString())),
            if ((widget.request['details']?.toString() ?? '').isNotEmpty)
              ExpansionTile(
                title: Text(tr('查看操作详情', 'Operation details')),
                children: [
                  SelectionArea(
                    child: Text(
                      widget.request['details'].toString(),
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 8),
            Text(
              tr(
                '仅决定本次操作，不会修改电脑的全局权限。',
                'This decides this operation only, not global computer permissions.',
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: _sending
                      ? null
                      : () => _submit({'approved': false}),
                  child: Text(tr('拒绝', 'Deny')),
                ),
                FilledButton(
                  onPressed: _sending
                      ? null
                      : () => _submit({'approved': true}),
                  child: Text(tr('允许一次', 'Allow once')),
                ),
              ],
            ),
          ] else ...[
            for (final q in _questions) ...[
              if ((q['header']?.toString() ?? '').isNotEmpty)
                Text(
                  q['header'].toString(),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              Text(
                q['question']?.toString() ?? '',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if ((q['detail']?.toString() ?? '').isNotEmpty)
                SelectionArea(child: Text(q['detail'].toString())),
              for (final option
                  in (q['options'] as List? ?? []).whereType<Map>())
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(option['label']?.toString() ?? ''),
                  subtitle: option['description'] == null
                      ? null
                      : Text(option['description'].toString()),
                  value:
                      _selected[q['id'].toString()]?.contains(
                        option['label'],
                      ) ??
                      false,
                  onChanged: _sending
                      ? null
                      : (checked) => setState(() {
                          final selected = _selected.putIfAbsent(
                            q['id'].toString(),
                            () => {},
                          );
                          if (q['multiSelect'] != true) selected.clear();
                          if (checked == true) {
                            selected.add(option['label'].toString());
                          } else {
                            selected.remove(option['label']);
                          }
                        }),
                ),
              TextField(
                controller: _custom.putIfAbsent(
                  q['id'].toString(),
                  TextEditingController.new,
                ),
                enabled: !_sending,
                maxLength: 20000,
                minLines: 1,
                maxLines: 4,
                decoration: InputDecoration(
                  labelText: tr(
                    '补充或输入你的回答',
                    'Your own answer or additional details',
                  ),
                  counterText: '',
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
            ],
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: _sending ? null : () => _submit({'skipped': true}),
                  child: Text(tr('跳过', 'Skip')),
                ),
                FilledButton(
                  onPressed: _sending || !_complete
                      ? null
                      : () => _submit({
                          'answers': [
                            for (final q in _questions)
                              {
                                'id': q['id'].toString(),
                                'selected':
                                    (_selected[q['id'].toString()] ?? {})
                                        .toList(),
                                if (_custom[q['id'].toString()]?.text
                                        .trim()
                                        .isNotEmpty ??
                                    false)
                                  'custom': _custom[q['id'].toString()]!.text
                                      .trim(),
                              },
                          ],
                        }),
                  child: Text(tr('提交回答', 'Submit answers')),
                ),
              ],
            ),
          ],
          if (_sending) const LinearProgressIndicator(),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
  );
}
