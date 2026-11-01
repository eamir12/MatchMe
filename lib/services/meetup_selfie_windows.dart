// Windows selfie capture for the Spot me card.
//
// The camera plugin has no Windows implementation, so the same live flow runs
// in WebView2: a small local page opens the front camera, mirrors the preview,
// and posts one JPEG frame back through the standard PhotoCapture bridge.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/services/meetup_selfie_contract.dart';
import 'package:matchme/widgets/safe_text.dart';
import 'package:webview_windows/webview_windows.dart';

const String _bridgeShim = '''
(function(){
  function postToHost(channel, message){
    try{
      if(window.chrome && window.chrome.webview && typeof window.chrome.webview.postMessage==='function'){
        window.chrome.webview.postMessage(JSON.stringify({channel:channel,message:String(message)}));
      }
    }catch(_){}
  }
  try{ window.PhotoCapture={postMessage:function(m){postToHost('PhotoCapture',m);}};}catch(_){}
  try{ window.ValidationLog={postMessage:function(m){postToHost('ValidationLog',m);}};}catch(_){}
})();
''';

Future<MeetupSelfieResult> captureMeetupSelfieWindows({
  required BuildContext context,
  required LocalizationState l10n,
}) {
  final completer = Completer<MeetupSelfieResult>();
  Navigator.of(context)
      .push<void>(
        MaterialPageRoute<void>(
          builder: (_) => _WindowsSelfiePage(
            l10n: l10n,
            onResult: (result) {
              if (!completer.isCompleted) completer.complete(result);
            },
          ),
        ),
      )
      .then((_) {
        if (!completer.isCompleted) {
          completer.complete(const MeetupSelfieResult.cancelled());
        }
      });
  return completer.future;
}

class _WindowsSelfiePage extends StatefulWidget {
  final LocalizationState l10n;
  final ValueChanged<MeetupSelfieResult> onResult;

  const _WindowsSelfiePage({required this.l10n, required this.onResult});

  @override
  State<_WindowsSelfiePage> createState() => _WindowsSelfiePageState();
}

class _WindowsSelfiePageState extends State<_WindowsSelfiePage> {
  final WebviewController _controller = WebviewController();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool _ready = false;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_init());
    });
  }

  void _finish(MeetupSelfieResult result) {
    if (_finished) return;
    _finished = true;
    widget.onResult(result);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _init() async {
    try {
      final version = await WebviewController.getWebViewVersion();
      if (version == null) {
        _finish(const MeetupSelfieResult.failed('unavailable'));
        return;
      }
    } catch (_) {
      _finish(const MeetupSelfieResult.failed('unavailable'));
      return;
    }

    try {
      final html = await rootBundle.loadString(
        'assets/meetup_selfie/index.html',
      );
      final prepared = html
          .replaceFirst(
            '__TITLE_JSON__',
            jsonEncode(widget.l10n.getString('meetupSpotMeTitle')),
          )
          .replaceFirst(
            '__HINT_JSON__',
            jsonEncode(widget.l10n.getString('meetupSpotMeSelfieHint')),
          )
          .replaceFirst(
            '__CAPTURE_JSON__',
            jsonEncode(widget.l10n.getString('meetupSpotMeSelfie')),
          )
          .replaceFirst(
            '__CANCEL_JSON__',
            jsonEncode(widget.l10n.getString('cancel')),
          )
          .replaceFirst(
            '__ERROR_JSON__',
            jsonEncode(widget.l10n.getString('meetupSpotMeCameraUnavailable')),
          );

      final dir = Directory('${Directory.systemTemp.path}/matchme_selfie');
      await dir.create(recursive: true);
      final file = File('${dir.path}/index.html');
      await file.writeAsString(prepared, flush: true);

      await _controller.initialize();
      _subscriptions.add(_controller.webMessage.listen(_onWebMessage));
      await _controller.addScriptToExecuteOnDocumentCreated(_bridgeShim);
      await _controller.addVirtualHostNameMapping(
        'matchme-selfie.local',
        dir.path,
        WebviewHostResourceAccessKind.allow,
      );
      await _controller.loadUrl('https://matchme-selfie.local/index.html');

      if (!mounted) return;
      setState(() => _ready = true);
    } catch (_) {
      _finish(const MeetupSelfieResult.failed('failed'));
    }
  }

  void _onWebMessage(dynamic message) {
    if (message is! String) return;
    try {
      final decoded = jsonDecode(message);
      if (decoded is! Map<String, dynamic>) return;
      final channel = decoded['channel']?.toString();
      final payload = decoded['message']?.toString() ?? '';
      if (channel == 'PhotoCapture') {
        try {
          final bytes = base64Decode(payload);
          _finish(MeetupSelfieResult(bytes: bytes));
        } catch (_) {
          _finish(const MeetupSelfieResult.failed('failed'));
        }
        return;
      }
      if (channel == 'ValidationLog') {
        try {
          final event = jsonDecode(payload);
          if (event is Map<String, dynamic>) {
            final type = event['type']?.toString();
            if (type == 'selfieCancel') {
              _finish(const MeetupSelfieResult.cancelled());
            } else if (type == 'selfieError') {
              final code = event['code']?.toString() ?? 'failed';
              _finish(MeetupSelfieResult.failed(code));
            }
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<WebviewPermissionDecision> _onPermissionRequested(
    String url,
    WebviewPermissionKind kind,
    bool isUserInitiated,
  ) async => WebviewPermissionDecision.allow;

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      try {
        subscription.cancel();
      } catch (_) {}
    }
    try {
      _controller.dispose();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: ShrinkText(widget.l10n.getString('meetupSpotMeSelfie')),
      ),
      body: _ready
          ? Webview(_controller, permissionRequested: _onPermissionRequested)
          : const Center(child: CircularProgressIndicator()),
    );
  }
}
