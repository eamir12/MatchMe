import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import 'turnstile_challenge_dialog_windows.dart' as windows_dialog;
import 'turnstile_challenge_shared.dart';

/// webview_flutter has no Windows/Linux implementation, so
/// WebViewPlatform.instance stays null there. Windows uses WebView2
/// (see turnstile_challenge_dialog_windows.dart) with the same challenge HTML.
/// Only Linux has no WebView and shows an error.
bool _isTurnstileWebViewSupported() {
  try {
    return Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
  } catch (_) {
    return false;
  }
}

Future<TurnstileChallengeResult?> showTurnstileChallengeDialog({
  required BuildContext context,
  required TurnstileChallengeRequest request,
}) {
  try {
    if (Platform.isWindows) {
      return windows_dialog.showWindowsTurnstileChallengeDialog(
        context: context,
        request: request,
      );
    }
  } catch (_) {}
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
  WebViewController? _controller;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    _initController();
  }

  Future<void> _initController() async {
    if (!_isTurnstileWebViewSupported()) {
      if (mounted) {
        setState(() {
          _statusMessage = widget.request.failedWithErrorMessage.replaceAll(
            '{error}',
            'WebView not supported on ${Platform.operatingSystem}',
          );
        });
      }
      return;
    }
    PlatformWebViewControllerCreationParams params =
        const PlatformWebViewControllerCreationParams();
    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      params =
          WebKitWebViewControllerCreationParams.fromPlatformWebViewControllerCreationParams(
            params,
            allowsInlineMediaPlayback: true,
            mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
          );
    } else if (WebViewPlatform.instance is AndroidWebViewPlatform) {
      params =
          AndroidWebViewControllerCreationParams.fromPlatformWebViewControllerCreationParams(
            params,
          );
    }

    final controller = WebViewController.fromPlatformCreationParams(params)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'CaptchaBridge',
        onMessageReceived: (message) {
          final payload = decodeTurnstileBridgeMessage(message.message);
          if (payload == null || !mounted) return;

          final type = (payload['type'] ?? '').toString();
          if (type == 'success') {
            final token = (payload['token'] ?? '').toString();
            final action = (payload['action'] ?? widget.request.action)
                .toString();
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
        },
      )
      ..loadHtmlString(
        buildTurnstileChallengeHtml(widget.request),
        baseUrl: 'https://matchme.local/captcha/',
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            if (request.url.startsWith('https://challenges.cloudflare.com/') ||
                request.url.startsWith('https://matchme.local/captcha/')) {
              return NavigationDecision.navigate;
            }
            return NavigationDecision.prevent;
          },
        ),
      );

    if (!mounted) return;
    setState(() {
      _controller = controller;
    });
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
                  child: _controller == null
                      ? const Center(child: CircularProgressIndicator())
                      : WebViewWidget(controller: _controller!),
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
          onPressed: _controller == null
              ? null
              : () {
                  setState(() {
                    _statusMessage = null;
                  });
                  _controller!.loadHtmlString(
                    buildTurnstileChallengeHtml(widget.request),
                    baseUrl: 'https://matchme.local/captcha/',
                  );
                },
          child: Text(widget.request.retryLabel),
        ),
      ],
    );
  }
}
