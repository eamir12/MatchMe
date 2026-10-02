// Windows: Cloudflare Turnstile challenge via WebView2 (webview_windows).
//
// Same contract as turnstile_challenge_dialog_io.dart. The shared challenge
// HTML posts to window.CaptchaBridge; a shim injected via
// addScriptToExecuteOnDocumentCreated forwards it through
// chrome.webview.postMessage and Dart routes the webMessage stream.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_windows/webview_windows.dart';

import 'turnstile_challenge_shared.dart';

const String _turnstileBridgeShim = '''
(function(){
  function postToHost(message){
    try{
      if(window.chrome && window.chrome.webview && typeof window.chrome.webview.postMessage==='function'){
        window.chrome.webview.postMessage(JSON.stringify({channel:'CaptchaBridge',message:String(message)}));
      }
    }catch(_){}
  }
  try{ window.CaptchaBridge={postMessage:function(m){postToHost(m);}};}catch(_){}
})();
''';

Future<TurnstileChallengeResult?> showWindowsTurnstileChallengeDialog({
  required BuildContext context,
  required TurnstileChallengeRequest request,
}) {
  return showDialog<TurnstileChallengeResult>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _WindowsTurnstileChallengeDialog(request: request),
  );
}

class _WindowsTurnstileChallengeDialog extends StatefulWidget {
  const _WindowsTurnstileChallengeDialog({required this.request});

  final TurnstileChallengeRequest request;

  @override
  State<_WindowsTurnstileChallengeDialog> createState() =>
      _WindowsTurnstileChallengeDialogState();
}

class _WindowsTurnstileChallengeDialogState
    extends State<_WindowsTurnstileChallengeDialog> {
  final WebviewController _controller = WebviewController();
  final List<StreamSubscription> _subscriptions = [];
  bool _ready = false;
  String? _statusMessage;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _initController();
  }

  void _handleBridgeMessage(String raw) {
    final payload = decodeTurnstileBridgeMessage(raw);
    if (payload == null || !mounted) return;
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
  }

  void _onWebMessage(dynamic message) {
    if (message is! String) return;
    try {
      final decoded = jsonDecode(message);
      if (decoded is Map<String, dynamic> &&
          decoded['channel'] == 'CaptchaBridge') {
        _handleBridgeMessage(decoded['message']?.toString() ?? '');
      }
    } catch (_) {}
  }

  Future<void> _initController() async {
    try {
      final version = await WebviewController.getWebViewVersion();
      if (version == null) {
        if (mounted) {
          setState(() {
            _loadError = widget.request.failedWithErrorMessage.replaceAll(
              '{error}',
              'WebView2 runtime not installed',
            );
          });
        }
        return;
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loadError = e.toString());
      }
      return;
    }
    try {
      // Serve from https://matchme.local/captcha/ (same origin as mobile's
      // baseUrl) so the challenge runs in a secure context with a stable
      // hostname for sitekey verification.
      final captchaDir = Directory(
        '${Directory.systemTemp.path}/matchme_captcha/captcha',
      );
      await captchaDir.create(recursive: true);
      final captchaFile = File('${captchaDir.path}/index.html');
      await captchaFile.writeAsString(
        buildTurnstileChallengeHtml(widget.request),
        flush: true,
      );
      await _controller.initialize();
      _subscriptions.add(_controller.webMessage.listen(_onWebMessage));
      await _controller.addScriptToExecuteOnDocumentCreated(
        _turnstileBridgeShim,
      );
      await _controller.addVirtualHostNameMapping(
        'matchme.local',
        Directory(
          '${Directory.systemTemp.path}/matchme_captcha',
        ).path,
        WebviewHostResourceAccessKind.allow,
      );
      await _controller.loadUrl('https://matchme.local/captcha/index.html');
      if (!mounted) return;
      setState(() => _ready = true);
    } catch (e) {
      if (mounted) {
        setState(() => _loadError = e.toString());
      }
    }
  }

  Future<void> _reload() async {
    try {
      setState(() {
        _statusMessage = null;
      });
      final captchaFile = File(
        '${Directory.systemTemp.path}/matchme_captcha/captcha/index.html',
      );
      await captchaFile.writeAsString(
        buildTurnstileChallengeHtml(widget.request),
        flush: true,
      );
      await _controller.loadUrl('https://matchme.local/captcha/index.html');
    } catch (e) {
      if (mounted) {
        setState(() => _statusMessage = e.toString());
      }
    }
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      try {
        s.cancel();
      } catch (_) {}
    }
    try {
      _controller.dispose();
    } catch (_) {}
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
              height: 200,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.dividerColor),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: _loadError != null
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              _loadError!,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.error,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        )
                      : !_ready
                          ? const Center(
                              child: CircularProgressIndicator(),
                            )
                          : Webview(_controller),
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
          onPressed: !_ready ? null : _reload,
          child: Text(widget.request.retryLabel),
        ),
      ],
    );
  }
}
