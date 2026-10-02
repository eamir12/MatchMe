import 'dart:convert';

class TurnstileChallengeRequest {
  const TurnstileChallengeRequest({
    required this.siteKey,
    required this.action,
    required this.title,
    required this.description,
    required this.cancelLabel,
    required this.retryLabel,
    required this.preparingMessage,
    required this.promptMessage,
    required this.completeMessage,
    required this.failedRetryMessage,
    required this.failedWithErrorMessage,
    required this.expiredRetryMessage,
    required this.timedOutRetryMessage,
    required this.emptyTokenMessage,
  });

  final String siteKey;
  final String action;
  final String title;
  final String description;
  final String cancelLabel;
  final String retryLabel;
  final String preparingMessage;
  final String promptMessage;
  final String completeMessage;
  final String failedRetryMessage;
  final String failedWithErrorMessage;
  final String expiredRetryMessage;
  final String timedOutRetryMessage;
  final String emptyTokenMessage;
}

class TurnstileChallengeResult {
  const TurnstileChallengeResult({required this.token, required this.action});

  final String token;
  final String action;
}

const String turnstileBridgeSource = 'matchme-turnstile';

Map<String, dynamic>? decodeTurnstileBridgeMessage(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    final map = Map<String, dynamic>.from(decoded);
    if (map['source'] != turnstileBridgeSource) return null;
    return map;
  } catch (_) {
    return null;
  }
}

String buildTurnstileChallengeHtml(TurnstileChallengeRequest request) {
  final siteKeyJson = jsonEncode(request.siteKey);
  final actionJson = jsonEncode(request.action);
  final preparingMessageJson = jsonEncode(request.preparingMessage);
  final promptMessageJson = jsonEncode(request.promptMessage);
  final completeMessageJson = jsonEncode(request.completeMessage);
  final failedRetryMessageJson = jsonEncode(request.failedRetryMessage);
  final expiredRetryMessageJson = jsonEncode(request.expiredRetryMessage);
  final timedOutRetryMessageJson = jsonEncode(request.timedOutRetryMessage);

  return '''
<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8">
    <meta
      name="viewport"
      content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no"
    >
    <style>
      html, body {
        margin: 0;
        padding: 0;
        background: transparent;
        font-family: sans-serif;
        overflow: hidden;
      }
      body {
        display: flex;
        min-height: 100vh;
        align-items: center;
        justify-content: center;
      }
      #wrap {
        width: 100%;
        display: flex;
        justify-content: center;
      }
      #widget {
        min-height: 70px;
      }
      #status {
        color: #666;
        font-size: 14px;
        text-align: center;
      }
    </style>
    <script
      src="https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit"
      async
      defer
    ></script>
  </head>
  <body>
    <div id="wrap">
      <div>
        <div id="widget"></div>
        <div id="status"></div>
      </div>
    </div>
    <script>
      const source = ${jsonEncode(turnstileBridgeSource)};
      const siteKey = $siteKeyJson;
      const action = $actionJson;
      const promptMessage = $promptMessageJson;
      const completeMessage = $completeMessageJson;
      const failedRetryMessage = $failedRetryMessageJson;
      const expiredRetryMessage = $expiredRetryMessageJson;
      const timedOutRetryMessage = $timedOutRetryMessageJson;
      let widgetId = null;

      function postMessageToHost(type, payload) {
        const message = JSON.stringify({
          source,
          type,
          ...payload,
        });

        if (window.CaptchaBridge && typeof window.CaptchaBridge.postMessage === 'function') {
          window.CaptchaBridge.postMessage(message);
        }

        if (window.parent && window.parent !== window) {
          window.parent.postMessage(message, '*');
        }
      }

      function setStatus(text) {
        const status = document.getElementById('status');
        if (status) {
          status.textContent = text;
        }
      }

      setStatus($preparingMessageJson);

      function renderWidget() {
        if (!window.turnstile) {
          window.setTimeout(renderWidget, 120);
          return;
        }

        setStatus(promptMessage);

        widgetId = window.turnstile.render('#widget', {
          sitekey: siteKey,
          action: action,
          appearance: 'interaction-only',
          theme: 'auto',
          size: 'flexible',
          retry: 'auto',
          'refresh-expired': 'auto',
          callback: function(token) {
            setStatus(completeMessage);
            postMessageToHost('success', { token: token, action: action });
          },
          'error-callback': function(code) {
            setStatus(failedRetryMessage);
            postMessageToHost('error', { error: String(code || 'unknown') });
          },
          'expired-callback': function() {
            setStatus(expiredRetryMessage);
            postMessageToHost('expired', { action: action });
          },
          'timeout-callback': function() {
            setStatus(timedOutRetryMessage);
            postMessageToHost('timeout', { action: action });
          }
        });
      }

      document.addEventListener('DOMContentLoaded', renderWidget);
    </script>
  </body>
</html>
''';
}
