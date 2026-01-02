import 'package:flutter/material.dart';


class EmojiWidget extends StatefulWidget {
  final String emoji;
  final double size;
  /// If true, try rendering the native glyph first (like WhatsApp).
  /// If the glyph is not available (common on some browsers), fall back to
  /// images (bundled assets or CDN). Defaults to true.
  final bool preferGlyphs;

  const EmojiWidget({
    super.key,
    required this.emoji,
    this.size = 20,
    this.preferGlyphs = true,
  });

  @override
  State<EmojiWidget> createState() => _EmojiWidgetState();
}

class _EmojiWidgetState extends State<EmojiWidget> {
  late final List<String> _candidates;
  int _idx = 0;
  bool _useGlyph = true; // true => render native glyph Text; false => use images

  @override
  void initState() {
    super.initState();
    final hex = widget.emoji.runes.map((r) => r.toRadixString(16)).join('-').toLowerCase();
    // Candidate order (prefer non-FE0F local when FE0F present to avoid dev-server HTML/index fallback):
    // 1) local non-FE0F (if applicable)
    // 2) local exact hex
    // 3) CDN non-FE0F
    // 4) CDN exact hex
    final List<String> list = [];

    if (hex.contains('fe0f')) {
      final noFe0f = hex.replaceAll('-fe0f', '');
      // prefer bundled assets first
      list.add('asset:assets/twemoji/$noFe0f.png');
      list.add('asset:assets/twemoji/$hex.png');
      // then local web path
      list.add('/twemoji/$noFe0f.png');
      list.add('/twemoji/$hex.png');
      // then CDN
      list.add('https://cdn.jsdelivr.net/gh/twitter/twemoji@14.0.2/assets/72x72/$noFe0f.png');
      list.add('https://cdn.jsdelivr.net/gh/twitter/twemoji@14.0.2/assets/72x72/$hex.png');
    } else {
      // no FE0F in hex — try bundled asset then local and CDN, then fe0f variants
      list.add('asset:assets/twemoji/$hex.png');
      list.add('/twemoji/$hex.png');
      list.add('https://cdn.jsdelivr.net/gh/twitter/twemoji@14.0.2/assets/72x72/$hex.png');
      list.add('asset:assets/twemoji/$hex-fe0f.png');
      list.add('/twemoji/$hex-fe0f.png');
      list.add('https://cdn.jsdelivr.net/gh/twitter/twemoji@14.0.2/assets/72x72/$hex-fe0f.png');

    }

    _candidates = list;

    // If the widget prefers glyphs, probe availability (especially helpful on web)
    _useGlyph = widget.preferGlyphs;
    if (_useGlyph) {
      // run asynchronously to avoid doing layout in initState synchronously
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final ok = await _emojiGlyphAvailable(widget.emoji, widget.size);
        if (!ok && mounted) {
          setState(() {
            _useGlyph = false;
          });
        }
      });
    }
  }


  /// Heuristic: decide whether the native emoji glyph is rendered by the
  /// engine/font stack or whether it falls back to a replacement/box glyph.
  /// We compare the laid-out width of the emoji to the REPLACEMENT CHAR width.
  Future<bool> _emojiGlyphAvailable(String emoji, double size) async {
    try {
      final style = TextStyle(fontSize: size);
      final tpEmoji = TextPainter(
        text: TextSpan(text: emoji, style: style),
        textDirection: TextDirection.ltr,
      );
      tpEmoji.layout();
      final tpReplacement = TextPainter(
        text: TextSpan(text: '\uFFFD', style: style),
        textDirection: TextDirection.ltr,
      );
      tpReplacement.layout();

      // If the emoji width equals the replacement width it's likely not rendered
      // as an emoji glyph. This is a heuristic but works reasonably well.
      final diff = (tpEmoji.width - tpReplacement.width).abs();
      // tolerant threshold (pixels)
      return diff > 0.5;
    } catch (e) {
      debugPrint('EmojiWidget: glyph detection error: $e');
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // If we're currently using glyphs, show the native emoji text (WhatsApp-style)
    if (_useGlyph) {
      return Text(widget.emoji, style: TextStyle(fontSize: widget.size));
    }

    final url = _candidates[_idx];

    // If the candidate starts with 'asset:' use Image.asset, else Image.network
    if (url.startsWith('asset:')) {
      final assetPath = url.substring('asset:'.length);
      return Image.asset(
        assetPath,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.contain,
        key: ValueKey(url),
        errorBuilder: (context, error, stackTrace) {
          debugPrint('EmojiWidget: failed to load asset $assetPath : $error');
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            if (_idx < _candidates.length - 1) setState(() => _idx++);
          });
          // If asset fails, and preferGlyphs was requested, fall back to glyph rendering
          if (widget.preferGlyphs) return Text(widget.emoji, style: TextStyle(fontSize: widget.size));
          return SizedBox(width: widget.size, height: widget.size);
        },
      );
    }

    // Attempt the candidate url; on error, advance to next candidate.
    return Image.network(
      url,
      width: widget.size,
      height: widget.size,
      fit: BoxFit.contain,
      key: ValueKey(url),
      errorBuilder: (context, error, stackTrace) {
        debugPrint('EmojiWidget: failed to load $url : $error');
        // Schedule trying the next candidate *after* the current frame to avoid setState() during build
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (_idx < _candidates.length - 1) {
            setState(() { _idx++; });
          }
        });
        // If image fails and preferGlyphs is true, render glyph as fallback
        if (widget.preferGlyphs) return Text(widget.emoji, style: TextStyle(fontSize: widget.size));
        return SizedBox(width: widget.size, height: widget.size);
      },
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return SizedBox(width: widget.size, height: widget.size);
      },
    );
  }
}
