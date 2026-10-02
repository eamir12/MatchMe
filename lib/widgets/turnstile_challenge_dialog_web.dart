import 'dart:js_interop';
import 'dart:ui_web' as ui_web;
import 'package:web/web.dart' as web;

import 'package:flutter/material.dart';

import 'turnstile_challenge_shared.dart';

int _turnstileWebViewCounter = 0;

Future<TurnstileChallengeResult?> showTurnstileChallengeDialog({
  required BuildContext context,
  required TurnstileChallengeRequest request,
}) {
  return showDialog<TurnstileChallengeResult>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _TurnstileChallengeDialog(request: request),
  );
}

class _TurnstileChallengeDialog extends StatefulWidget {
  const _TurnstileChallengeDialog({required this.request});

  final TurnstileChallengeRequest request;

  @override
  State<_TurnstileChallengeDialog> createState() =>
      _TurnstileChallengeDialogState();
}

class _TurnstileChallengeDialogState extends State<_TurnstileChallengeDialog> {
  late final String _viewType;
  late final web.HTMLIFrameElement _iframe;
  late final web.EventListener _messageListener;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    _viewType =
        'turnstile-view-${DateTime.now().microsecondsSinceEpoch}-${_turnstileWebViewCounter++}';
    _iframe = web.HTMLIFrameElement()
      ..style.border = '0'
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.backgroundColor = 'transparent'
      ..srcdoc = buildTurnstileChallengeHtml(widget.request).toJS;

    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int _) {
      return _iframe;
    });

    // `window.onMessage` has no package:web stream, so listen explicitly and
    // keep the callback reference to detach it in dispose().
    _messageListener = ((web.Event event) {
      final data = (event as web.MessageEvent).data;
      final raw = data != null && data.isA<JSString>()
          ? (data as JSString).toDart
          : null;
      if (raw == null || !mounted) return;

      final payload = decodeTurnstileBridgeMessage(raw);
      if (payload == null) return;

      final type = (payload['type'] ?? '').toString();
      if (type == 'success') {
        final token = (payload['token'] ?? '').toString();
        final action = (payload['action'] ?? widget.request.action).toString();
        if (token.isEmpty) {
          setState(() {
            _statusMessage = widget.request.emptyTokenMessage;
          });
          return;
        }
        Navigator.of(
          context,
        ).pop(TurnstileChallengeResult(token: token, action: action));
        return;
      }

      final error = (payload['error'] ?? '').toString().trim();
      setState(() {
        _statusMessage = error.isEmpty
            ? widget.request.failedRetryMessage
            : widget.request.failedWithErrorMessage.replaceAll(
                '{error}',
                error,
              );
      });
    }).toJS;
    web.window.addEventListener('message', _messageListener);
  }

  @override
  void dispose() {
    web.window.removeEventListener('message', _messageListener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      scrollable: true,
      title: Text(widget.request.title),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.request.description),
            const SizedBox(height: 16),
            SizedBox(
              height: 180,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.dividerColor),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: HtmlElementView(viewType: _viewType),
                ),
              ),
            ),
            if (_statusMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                _statusMessage!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.request.cancelLabel),
        ),
        TextButton(
          onPressed: () {
            setState(() {
              _statusMessage = null;
              _iframe.srcdoc = buildTurnstileChallengeHtml(widget.request).toJS;
            });
          },
          child: Text(widget.request.retryLabel),
        ),
      ],
    );
  }
}
