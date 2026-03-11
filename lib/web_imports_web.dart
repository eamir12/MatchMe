// web_imports_web.dart - Web-specific imports for dart:html functionality
// This file provides real dart:html imports when running on web platform

import 'dart:html' as html; // ignore: deprecated_member_use,avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:js_interop';
import 'package:web/web.dart' as web;
import 'package:matchme/providers/locale_provider.dart';

// Re-export dart:html classes and functions for web platform
export 'dart:html' show document, window, KeyboardEvent, Event, Location; // ignore: deprecated_member_use

// Send beacon for reliable offline notification during page unload
bool sendOfflineBeacon(String url, String data) {
  try {
    final dataBytes = utf8.encode(data);
    final success = html.window.navigator.sendBeacon(
      url,
      dataBytes,
    );
    return success;
  } catch (e) {
    return false;
  }
}

// Web-specific implementation of camera functionality
Future<Uint8List?> pickImageBytesFromCamera({
  String capture = 'user',
  String? captureButtonText,
  String? cancelButtonText,
}) async {
	try {
		// Use getUserMedia API to access camera directly
		final mediaDevices = html.window.navigator.mediaDevices;
		if (mediaDevices == null) {
			return null;
		}

		// Request camera access
		final constraints = {
			'video': {
				'facingMode': capture,
				'width': {'ideal': 1920},
				'height': {'ideal': 1080}
			}
		};

		final stream = await mediaDevices.getUserMedia(constraints);
		
		// Create overlay container for camera preview
		final overlay = html.DivElement()
			..style.position = 'fixed'
			..style.top = '0'
			..style.left = '0'
			..style.width = '100%'
			..style.height = '100%'
			..style.backgroundColor = 'rgba(0, 0, 0, 0.8)'
			..style.display = 'flex'
			..style.flexDirection = 'column'
			..style.alignItems = 'center'
			..style.justifyContent = 'center'
			..style.zIndex = '999999';

		// Create video element for camera preview
		final video = html.VideoElement()
			..srcObject = stream
			..autoplay = true
			..controls = false
			..muted = true
			..style.maxWidth = '90%'
			..style.maxHeight = '70%'
			..style.borderRadius = '8px';

		// Create capture button
    final resolvedCaptureButtonText =
        captureButtonText ?? LocalizationState.defaultTranslation('cameraCapturePhoto');
		final captureButton = html.ButtonElement()
			..text = resolvedCaptureButtonText
			..style.padding = '16px 32px'
			..style.fontSize = '18px'
			..style.backgroundColor = '#007AFF'
			..style.color = 'white'
			..style.border = 'none'
			..style.borderRadius = '8px'
			..style.marginTop = '20px'
			..style.cursor = 'pointer';

		// Create cancel button
    final resolvedCancelButtonText =
        cancelButtonText ?? LocalizationState.defaultTranslation('commonCancel');
		final cancelButton = html.ButtonElement()
			..text = resolvedCancelButtonText
			..style.padding = '16px 32px'
			..style.fontSize = '18px'
			..style.backgroundColor = '#666'
			..style.color = 'white'
			..style.border = 'none'
			..style.borderRadius = '8px'
			..style.marginTop = '10px'
			..style.cursor = 'pointer';

		// Add elements to overlay
		overlay.append(video);
		overlay.append(captureButton);
		overlay.append(cancelButton);

		// Add overlay to document
		html.document.body?.append(overlay);

		// Wait for video to be ready
		await video.onLoadedMetadata.first;

		// Create a completer to wait for user action
		final actionCompleter = Completer<String>();

		// Handle capture button click
		captureButton.onClick.listen((_) {
			if (!actionCompleter.isCompleted) {
				actionCompleter.complete('capture');
			}
		});

		// Handle cancel button click
		cancelButton.onClick.listen((_) {
			if (!actionCompleter.isCompleted) {
				actionCompleter.complete('cancel');
			}
		});

		// Wait for user action
		final action = await actionCompleter.future;

		Uint8List? result;
		if (action == 'capture') {
			try {
				// Create canvas to capture frame
				final canvas = html.CanvasElement(
					width: video.videoWidth,
					height: video.videoHeight
				);
				final ctx = canvas.context2D;
				ctx.drawImage(video, 0, 0);

				// Convert to blob and then to bytes
				final blob = await canvas.toBlob('image/jpeg', 0.9);
				final reader = html.FileReader();
				
				// Create a completer for the file reading
				final readCompleter = Completer<Uint8List?>();
				
				reader.onLoadEnd.listen((_) {
					try {
						final result = reader.result;
						if (result != null) {
							try {
								// Try to convert the result to Uint8List
								try {
									if (result is ByteBuffer) {
										if (!readCompleter.isCompleted) readCompleter.complete(Uint8List.view(result));
									} else if (result is List<int>) {
										if (!readCompleter.isCompleted) readCompleter.complete(Uint8List.fromList(result));
									} else {
										if (!readCompleter.isCompleted) readCompleter.complete(null);
									}
								} catch (e) {
									if (!readCompleter.isCompleted) readCompleter.complete(null);
								}
							} catch (e) {
								if (!readCompleter.isCompleted) readCompleter.complete(null);
							}
						} else {
							if (!readCompleter.isCompleted) readCompleter.complete(null);
						}
					} catch (e) {
						if (!readCompleter.isCompleted) readCompleter.complete(null);
					}
				});

				reader.onError.listen((_) {
					if (!readCompleter.isCompleted) readCompleter.complete(null);
				});

				reader.readAsArrayBuffer(blob);
				
				// Wait for the file reading to complete
				result = await readCompleter.future;

			} catch (e) {
				result = null;
			}
		}

		// Cleanup
		stream.getTracks().forEach((track) => track.stop());
		overlay.remove();
		
		return result;

	} catch (e) {
		// Fallback to file input method if getUserMedia fails
		try {
			final input = html.FileUploadInputElement();
			input.accept = 'image/*';
			input.multiple = false;
			input.setAttribute('capture', capture);

			final completer2 = Completer<Uint8List?>();
			late final StreamSubscription<html.Event> sub;
			
			sub = input.onChange.listen((_) async {
				try {
					sub.cancel();
				} catch (_) {}

				final files = input.files;
				if (files == null || files.isEmpty) {
					if (!completer2.isCompleted) completer2.complete(null);
					return;
				}

				final file = files.first;
				final reader = html.FileReader();

				reader.onError.listen((_) {
					if (!completer2.isCompleted) completer2.complete(null);
				});

				reader.onLoadEnd.listen((_) {
					try {
						final result = reader.result;
						if (result is ByteBuffer) {
							if (!completer2.isCompleted) completer2.complete(Uint8List.view(result));
						} else {
							if (!completer2.isCompleted) completer2.complete(null);
						}
					} catch (_) {
						if (!completer2.isCompleted) completer2.complete(null);
					}
				});

				reader.readAsArrayBuffer(file);
			});

			input.click();
			
			return await completer2.future;
		} catch (e) {
			return null;
		}
	}
}

// Safe vibration for web platform
void safeVibrate(Object pattern) {
	try {
		if (pattern is int) {
      web.window.navigator.vibrate(pattern.toJS);
      return;
    }
    if (pattern is List<int>) {
      final jsPattern = pattern.map((v) => v.toJS).toList().toJS;
      web.window.navigator.vibrate(jsPattern);
      return;
    }
    web.window.navigator.vibrate(20.toJS);
	} catch (_) {
		// Silently fail if vibration is not supported
	}
}
