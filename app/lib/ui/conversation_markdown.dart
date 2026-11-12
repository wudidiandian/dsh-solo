import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

import '../l10n/app_l10n.dart';

List<md.Node> _parseDocument(String text) => md.Document(
  extensionSet: md.ExtensionSet.gitHubFlavored,
  encodeHtml: false,
).parseLines(const LineSplitter().convert(text));

/// Per-conversation LRU: syntax only, never BuildContexts or rendered layouts.
/// Styling remains responsive to theme, text scale and viewport width.
class ConversationMarkdownCache {
  ConversationMarkdownCache({
    this.maxEntries = 32,
    this.maxCharacters = 500000,
  });
  final int maxEntries;
  final int maxCharacters;
  final _entries = <String, Future<List<md.Node>>>{};
  int _characters = 0;
  final _ready = <String, List<md.Node>>{};

  List<md.Node>? peek(String text) => _ready[text];

  int get length => _entries.length;

  Future<List<md.Node>> document(String text) {
    final cached = _entries.remove(text);
    if (cached != null) {
      _entries[text] = cached;
      return cached;
    }
    // Parsing a large response must not block the scrolling UI isolate.
    List<md.Node>? parsed;
    late final Future<List<md.Node>> result;
    if (text.length >= 8000) {
      result = compute(_parseDocument, text).then((nodes) {
        if (identical(_entries[text], result)) _ready[text] = nodes;
        return nodes;
      });
    } else {
      parsed = _parseDocument(text);
      result = Future.value(parsed);
    }
    if (text.length <= maxCharacters && maxEntries > 0) {
      _entries[text] = result;
      if (parsed != null) _ready[text] = parsed;
      _characters += text.length;
      while (_entries.length > maxEntries || _characters > maxCharacters) {
        final oldest = _entries.keys.first;
        _characters -= oldest.length;
        _entries.remove(oldest);
        _ready.remove(oldest);
      }
    }
    return result;
  }

  void clear() {
    _entries.clear();
    _ready.clear();
    _characters = 0;
  }
}

/// Clone before rendering: flutter_markdown normalizes some AST lists in place.
md.Node _cloneNode(md.Node node) {
  if (node is md.Text) return md.Text(node.text);
  if (node is md.Element) {
    final copy = node.children == null
        ? md.Element.empty(node.tag)
        : md.Element(node.tag, node.children!.map(_cloneNode).toList());
    copy.attributes.addAll(node.attributes);
    copy.generatedId = node.generatedId;
    copy.footnoteLabel = node.footnoteLabel;
    return copy;
  }
  return md.Text(node.textContent);
}

class ConversationMarkdown extends StatefulWidget {
  const ConversationMarkdown({
    super.key,
    required this.text,
    required this.cache,
    required this.styleSheet,
  });
  final String text;
  final ConversationMarkdownCache cache;
  final MarkdownStyleSheet styleSheet;

  @override
  State<ConversationMarkdown> createState() => _ConversationMarkdownState();
}

class _ConversationMarkdownState extends State<ConversationMarkdown>
    implements MarkdownBuilderDelegate {
  final _recognizers = <GestureRecognizer>[];
  late Future<List<md.Node>> _document;
  List<Widget>? _blocks;
  List<md.Node>? _nodes;
  static const _blockPageSize = 24;
  int _visibleBlocks = _blockPageSize;

  @override
  void initState() {
    super.initState();
    _document = widget.cache.document(widget.text);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _blocks = null;
  }

  @override
  void didUpdateWidget(ConversationMarkdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.cache != widget.cache) {
      _document = widget.cache.document(widget.text);
      _visibleBlocks = _blockPageSize;
      _blocks = null;
    }
    if (oldWidget.styleSheet != widget.styleSheet) _blocks = null;
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  @override
  GestureRecognizer createLink(String text, String? href, String title) {
    final recognizer = TapGestureRecognizer();
    _recognizers.add(recognizer);
    return recognizer;
  }

  @override
  TextSpan formatText(MarkdownStyleSheet styleSheet, String code) => TextSpan(
    style: styleSheet.code,
    text: code.replaceFirst(RegExp(r'\n$'), ''),
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<List<md.Node>>(
    key: ValueKey(widget.text),
    initialData: widget.cache.peek(widget.text),
    future: _document,
    builder: (context, snapshot) {
      if (!snapshot.hasData) {
        if (snapshot.hasError) return SelectableText(widget.text);
        return const SizedBox(
          height: 64,
          child: Center(
            child: SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        );
      }
      if (_blocks == null || !identical(_nodes, snapshot.data)) {
        _disposeRecognizers();
        _nodes = snapshot.data;
        _blocks = MarkdownBuilder(
          delegate: this,
          selectable: false,
          styleSheet: widget.styleSheet,
          imageDirectory: null,
          sizedImageBuilder: null,
          checkboxBuilder: null,
          bulletBuilder: null,
          builders: {},
          paddingBuilders: {},
          listItemCrossAxisAlignment:
              MarkdownListItemCrossAxisAlignment.baseline,
          fitContent: true,
          softLineBreak: true,
        ).build(_nodes!.take(_visibleBlocks).map(_cloneNode).toList());
      }
      return SelectionArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ..._blocks!,
            if (_visibleBlocks < _nodes!.length)
              TextButton(
                key: const ValueKey('load-more-reply-blocks'),
                onPressed: () => setState(() {
                  _visibleBlocks += _blockPageSize;
                  _blocks = null;
                }),
                child: Text(
                  AppL10n.i.isEn ? 'Continue this reply' : '继续展开这条回复',
                ),
              ),
          ],
        ),
      );
    },
  );
}
