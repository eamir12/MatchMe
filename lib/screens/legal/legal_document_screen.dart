// lib/screens/legal/legal_document_screen.dart
//
// In-app viewer for the Terms of Service and Privacy Policy.
//
// The documents live as markdown in docs/legal/ and are bundled as Flutter
// assets, so they can be edited and reviewed without an app release. This
// screen renders a deliberately small subset of markdown — headings,
// paragraphs, bullets, bold and links — which is all the documents use, and
// avoids taking on a markdown-rendering dependency.
//
// Legal text is intentionally NOT sourced from the `translations` table. Those
// are UI chrome; these are versioned documents that need legal review, and
// they change on a completely different cadence from the interface. Each
// document is stored per language under `docs/legal/<languageCode>/` and
// bundled as an asset, so it can be revised without an app release, and is
// available offline.
//
// The user's UI language selects the file. English is the fallback, and when
// the fallback is used the screen says so rather than silently serving the
// wrong language.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/widgets/safe_text.dart';

/// Identifies which bundled document to show.
enum LegalDocument {
  termsOfService('TERMS_OF_SERVICE', 'legalTitleTerms'),
  privacyPolicy('PRIVACY_POLICY', 'legalTitlePrivacy');

  const LegalDocument(this.assetFile, this.titleKey);

  /// File name, without extension, under `docs/legal/<languageCode>/`.
  final String assetFile;

  /// Translation key for the screen title, so the AppBar is localised too.
  final String titleKey;
}

/// Displays one legal document, scrollable and selectable, with a shareable
/// text body the user can copy out.
class LegalDocumentScreen extends ConsumerStatefulWidget {
  const LegalDocumentScreen({
    super.key,
    required this.document,
    this.onOpenLinkedDocument,
  });

  final LegalDocument document;

  /// Called when the body contains a link to the other legal document, so the
  /// host can swap documents in place instead of pushing another route.
  final void Function(LegalDocument linked)? onOpenLinkedDocument;

  @override
  ConsumerState<LegalDocumentScreen> createState() =>
      _LegalDocumentScreenState();
}

class _LegalDocumentScreenState extends ConsumerState<LegalDocumentScreen> {
  static const String _privacyRoute = '/privacy';
  static const String _notesMarker = 'matchme:internal-notes-end';

  String _raw = '';
  bool _loading = true;
  bool _failed = false;

  /// Set when the document was served in English because the user's language
  /// has no translation. The user is told, rather than being left to assume.
  bool _showingEnglishFallback = false;

  static const String _fallbackLanguage = 'en';

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Loads the document in the user's current UI language, falling back to
  /// English only if that translation is missing.
  Future<void> _load() async {
    final requested = ref
        .read(localizationProvider)
        .currentLocale
        .languageCode
        .toLowerCase();

    var body = await _tryLoad(requested);
    var usedFallback = false;

    if (body == null && requested != _fallbackLanguage) {
      body = await _tryLoad(_fallbackLanguage);
      usedFallback = body != null;
    }

    if (!mounted) return;
    setState(() {
      _raw = body ?? '';
      _failed = body == null;
      _showingEnglishFallback = usedFallback;
      _loading = false;
    });
  }

  Future<String?> _tryLoad(String languageCode) async {
    try {
      return await rootBundle.loadString(
        'docs/legal/$languageCode/${widget.document.assetFile}.md',
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = ref.watch(localizationProvider);

    return Scaffold(
      appBar: AppBar(
        title: ShrinkText(l10n.getString(widget.document.titleKey)),
        centerTitle: false,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _failed
          ? _buildUnavailable(theme)
          : _buildBody(theme, l10n),
    );
  }

  Widget _buildUnavailable(ThemeData theme) {
    final l10n = ref.watch(localizationProvider);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.description_outlined,
              size: 40,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              l10n.getString('legalDocumentUnavailable'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _load,
              child: Text(l10n.getString('legalTryAgain')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme, LocalizationState l10n) {
    final blocks = _parse(_stripFrontMatter(_raw).split('\n'));

    return SelectionArea(
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 48),
        itemCount: blocks.length + (_showingEnglishFallback ? 1 : 0),
        itemBuilder: (context, i) {
          if (_showingEnglishFallback && i == 0) {
            return _buildFallbackNotice(theme, l10n);
          }
          final block = blocks[_showingEnglishFallback ? i - 1 : i];
          return _buildBlock(block, theme);
        },
      ),
    );
  }

  /// Shown when the document is not yet available in the user's language.
  /// Serving a document in the wrong language silently would be worse than
  /// saying so, so this is always visible rather than a debug-level detail.
  Widget _buildFallbackNotice(ThemeData theme, LocalizationState l10n) {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.translate,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              l10n.getString('legalEnglishFallbackNotice'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- parsing

  /// A document is a flat list of blocks. This is enough structure for legal
  /// text and much easier to reason about than a full markdown AST.
  List<_Block> _parse(List<String> lines) {
    final blocks = <_Block>[];
    final paragraph = <String>[];

    void flushParagraph() {
      if (paragraph.isEmpty) return;
      blocks.add(_Block.paragraph(paragraph.join(' ')));
      paragraph.clear();
    }

    for (final raw in lines) {
      final line = raw.trimRight();

      if (line.trim().isEmpty) {
        flushParagraph();
        continue;
      }

      // Drafting notes are internal and must never reach the user. The marker
      // is a comment rather than the heading, because the heading is
      // translated and would need six matching strings to stay in sync.
      if (line.contains(_notesMarker)) {
        break;
      }

      final heading = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(line);
      if (heading != null) {
        flushParagraph();
        blocks.add(
          _Block.heading(
            heading.group(1)!.length,
            heading.group(2)!.trim(),
          ),
        );
        continue;
      }

      final bullet = RegExp(r'^\s*[-*]\s+(.*)$').firstMatch(line);
      if (bullet != null) {
        flushParagraph();
        blocks.add(_Block.bullet(bullet.group(1)!.trim()));
        continue;
      }

      // Horizontal rule separates sections; skip it, the spacing does the job.
      if (RegExp(r'^\s*(-{3,}|\*{3,})\s*$').hasMatch(line)) {
        flushParagraph();
        continue;
      }

      paragraph.add(line.trim());
    }

    flushParagraph();
    return blocks;
  }

  /// Removes the title, status line and version metadata, which the AppBar
  /// already communicates.
  String _stripFrontMatter(String source) {
    final lines = source.split('\n');
    var i = 0;
    while (i < lines.length) {
      final t = lines[i].trimLeft();
      if (t.startsWith('# ') ||
          t.startsWith('**Effective date:') ||
          t.startsWith('**Version:') ||
          t.startsWith('**Status:') ||
          t == '---' ||
          t.isEmpty) {
        i++;
      } else {
        break;
      }
    }
    return lines.skip(i).join('\n');
  }

  // --------------------------------------------------------------- rendering

  Widget _buildBlock(_Block block, ThemeData theme) {
    switch (block.kind) {
      case _BlockKind.heading:
        return _buildHeading(block, theme);
      case _BlockKind.bullet:
        return _buildBullet(block, theme);
      case _BlockKind.paragraph:
        return _buildParagraph(block, theme);
    }
  }

  Widget _buildHeading(_Block block, ThemeData theme) {
    // h1 is the document title, already in the AppBar.
    if (block.level <= 1) return const SizedBox.shrink();

    final base = theme.textTheme.titleLarge;
    final style = switch (block.level) {
      2 => base?.copyWith(fontWeight: FontWeight.bold, fontSize: 18),
      3 => theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      _ => theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
    };

    return Padding(
      padding: EdgeInsets.only(top: block.level == 2 ? 24 : 16, bottom: 6),
      child: Text(block.text ?? '', style: style),
    );
  }

  Widget _buildBullet(_Block block, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(left: 6, bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6, right: 8),
            child: Text('•', style: theme.textTheme.bodyMedium),
          ),
          Expanded(
            child: _buildInlineText(
              block.text ?? '',
              theme.textTheme.bodyMedium?.copyWith(height: 1.5),
              theme,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildParagraph(_Block block, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: _buildInlineText(
        block.text ?? '',
        theme.textTheme.bodyMedium?.copyWith(height: 1.5),
        theme,
      ),
    );
  }

  /// Renders inline markdown: **bold**, `code`, and [label](/route) links.
  ///
  /// Bold and code are TextSpans. Links become a WidgetSpan wrapping a
  /// GestureDetector rather than a TextSpan with a TapGestureRecognizer:
  /// recognizers attached to spans must be disposed by hand, and a legal
  /// document is exactly the kind of long, link-bearing content that makes
  /// manual recognizer bookkeeping a leak waiting to happen.
  Widget _buildInlineText(String source, TextStyle? style, ThemeData theme) {
    final spans = <InlineSpan>[];
    final pattern = RegExp(
      r'(\*\*[^*]+\*\*)|(`[^`]+`)|(\[[^\]]+\]\(([^)]+)\))',
    );

    var cursor = 0;
    for (final match in pattern.allMatches(source)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: source.substring(cursor, match.start)));
      }

      final token = match.group(0)!;
      if (token.startsWith('**')) {
        spans.add(
          TextSpan(
            text: token.substring(2, token.length - 2),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        );
      } else if (token.startsWith('`')) {
        spans.add(
          TextSpan(
            text: token.substring(1, token.length - 1),
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        );
      } else {
        final label =
            RegExp(r'\[([^\]]+)\]').firstMatch(token)?.group(1) ?? token;
        final route = RegExp(r'\(([^)]+)\)').firstMatch(token)?.group(1) ?? '';
        final target = _targetFor(route);

        final linkStyle = style?.copyWith(
          color: theme.colorScheme.primary,
          decoration: TextDecoration.underline,
          decorationColor: theme.colorScheme.primary,
        );

        if (target == null) {
          spans.add(TextSpan(text: label, style: linkStyle));
        } else {
          spans.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: GestureDetector(
                onTap: () => _openLinked(target),
                child: Text(label, style: linkStyle),
              ),
            ),
          );
        }
      }

      cursor = match.end;
    }

    if (cursor < source.length) {
      spans.add(TextSpan(text: source.substring(cursor)));
    }

    return Text.rich(TextSpan(style: style, children: spans));
  }

  LegalDocument? _targetFor(String route) {
    switch (route.trim().toLowerCase()) {
      case _privacyRoute:
        return LegalDocument.privacyPolicy;
      case '/terms':
        return LegalDocument.termsOfService;
      default:
        return null;
    }
  }

  void _openLinked(LegalDocument target) {
    final handler = widget.onOpenLinkedDocument;
    if (handler != null) {
      handler(target);
      return;
    }
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => LegalDocumentScreen(
          document: target,
          onOpenLinkedDocument: widget.onOpenLinkedDocument,
        ),
      ),
    );
  }
}

enum _BlockKind { heading, bullet, paragraph }

class _Block {
  const _Block.heading(this.level, this.text) : kind = _BlockKind.heading;
  const _Block.bullet(this.text) : level = 0, kind = _BlockKind.bullet;
  const _Block.paragraph(this.text) : level = 0, kind = _BlockKind.paragraph;

  final _BlockKind kind;
  final int level;
  final String? text;
}
