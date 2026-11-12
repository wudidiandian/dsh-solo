import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:dsh_solo/ui/conversation_markdown.dart';
import 'package:dsh_solo/l10n/app_l10n.dart';

void main() {
  setUpAll(() => AppL10n.init('zh'));

  testWidgets('many paragraphs share one selection region without editable text scrollables', (tester) async {
    final cache = ConversationMarkdownCache();
    final text = [for (var i = 1; i <= 20; i++) '段落 $i **可选择文本**'].join('\n\n');
    await cache.document(text);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
      child: Builder(builder: (context) => ConversationMarkdown(text: text,
        cache: cache, styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))))))));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableRegion), findsOneWidget);
    expect(find.byType(EditableText), findsNothing);
    expect(find.byType(SelectableText), findsNothing);
    expect(find.byType(Scrollable), findsOneWidget,
      reason: 'Paragraphs must not add their own editable-text viewports');
    expect(find.textContaining('段落 1', findRichText: true), findsWidgets);
    await tester.longPress(find.textContaining('段落 1', findRichText: true).first);
    await tester.pumpAndSettle();
    expect(find.text('Copy'), findsOneWidget,
      reason: 'Long-press selection and copy must remain available');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a very long reply builds a bounded block page and can expand', (
    tester,
  ) async {
    final cache = ConversationMarkdownCache();
    final source = [for (var i = 1; i <= 100; i++) '段落 $i'].join('\n\n');
    await cache.document(source);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Builder(
              builder: (context) => ConversationMarkdown(
                text: source,
                cache: cache,
                styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('段落 24'), findsOneWidget);
    expect(find.text('段落 25'), findsNothing);
    final more = find.byKey(const ValueKey('load-more-reply-blocks'));
    await tester.ensureVisible(more);
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.text('段落 48'), findsOneWidget);
    expect(find.text('段落 49'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  test(
    'parsed documents are reused and bounded by entries and source size',
    () async {
      final cache = ConversationMarkdownCache(
        maxEntries: 2,
        maxCharacters: 100,
      );
      final first = cache.document('**first**');
      await first;
      expect(identical(first, cache.document('**first**')), isTrue);
      expect(cache.peek('**first**'), isNotNull);
      await cache.document('second');
      await cache.document('third');
      expect(cache.length, 2);
      expect(cache.peek('**first**'), isNull);
      await cache.document('large' * 30);
      expect(cache.length, 2);
      expect(cache.peek('large' * 30), isNull);
      cache.clear();
      expect(cache.length, 0);
    },
  );

  test('large responses parse in the background and preserve references and tables', () async {
    final cache = ConversationMarkdownCache();
    final source =
        '# 标题\n\n[链接][ref]\n\n| 列 | 值 |\n| --- | --- |\n| A | B |\n\n'
        '${'正文🚀\n\n' * 2000}[ref]: https://example.com\n';
    final nodes = await cache.document(source);
    expect(nodes.first.textContent, '标题');
    expect(nodes.any((node) => node.textContent.contains('A')), isTrue);
    expect(identical(nodes, cache.peek(source)), isTrue);
  });

  testWidgets(
    'remounted cached Markdown renders without a loading flash and follows theme',
    (tester) async {
      final cache = ConversationMarkdownCache();
      const text = '# 标题\n\n**正文**\n\n```dart\nprint(1);\n```';
      await cache.document(text);
      Widget page(Brightness brightness) => MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: Scaffold(
          body: Builder(
            builder: (context) => ConversationMarkdown(
              text: text,
              cache: cache,
              styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
            ),
          ),
        ),
      );
      await tester.pumpWidget(page(Brightness.light));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('标题'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(page(Brightness.dark));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('标题'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
