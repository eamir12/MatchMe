// web_imports_web.dart - Web-specific imports for dart:html functionality
// This file provides real dart:html imports when running on web platform

import 'dart:html' as html; // ignore: deprecated_member_use,avoid_web_libraries_in_flutter

// Re-export dart:html classes and functions for web platform
export 'dart:html' show document, window, KeyboardEvent, Event; // ignore: deprecated_member_use

// Top-level variables to match the interface used in main.dart
final html.HtmlDocument document = html.document;
final html.Window window = html.window;

// Track whether the user has interacted with the page (required by some browser APIs)
bool _hasUserInteracted = false;

void _onFirstUserGesture([html.Event? _]) {
	_hasUserInteracted = true;
	try {
		document.removeEventListener('pointerdown', _onFirstUserGesture);
		document.removeEventListener('touchstart', _onFirstUserGesture);
		document.removeEventListener('keydown', _onFirstUserGesture);
	} catch (_) {}
}

// Install lightweight listeners immediately so the flag is set on the first gesture
void _installGestureListeners() {
	try {
		document.addEventListener('pointerdown', _onFirstUserGesture);
		document.addEventListener('touchstart', _onFirstUserGesture);
		document.addEventListener('keydown', _onFirstUserGesture);
	} catch (e) {
		// ignore - defensive in case DOM APIs are unavailable
	}
}

// Run installer at import time (via initializer expression)
// ignore: unused_element
final bool _gestureListenersInitializer = (() {
	_installGestureListeners();
	return true;
})();

/// Safely vibrate the device if allowed by the browser — no-op otherwise.
/// `pattern` can be a single duration in ms or a list of durations.
void safeVibrate(Object pattern) {
	try {
		if (!_hasUserInteracted) return; // Browser blocks vibration until user gesture
		final nav = window.navigator;
		if (pattern is int) {
			(nav as dynamic).vibrate(pattern);
		} else if (pattern is List<int>) {
			(nav as dynamic).vibrate(pattern);
		}
	} catch (_) {
		// ignore any errors — vibration is non-critical
	}
}