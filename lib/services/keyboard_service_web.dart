// services/keyboard_service.dart
// Service for handling keyboard navigation in web browsers

import 'package:web/web.dart' as web;
import 'dart:js_interop';
import 'package:flutter/foundation.dart';

class KeyboardService {
  static final KeyboardService _instance = KeyboardService._internal();

  factory KeyboardService() => _instance;

  KeyboardService._internal();

  bool _isInitialized = false;

  void initialize() {
    if (_isInitialized || !kIsWeb) return;

    _isInitialized = true;

    // Add keyboard event listener for arrow key scrolling
    web.window.document.addEventListener('keydown', _handleKeyDown.toJS);

    // Prevent default behavior for arrow keys when not in input fields
    web.window.document.addEventListener(
      'keydown',
      _preventDefaultInInputs.toJS,
    );
  }

  void _handleKeyDown(web.Event event) {
    final keyboardEvent = event as web.KeyboardEvent;

    // Only handle scrolling when not in input fields
    final target = keyboardEvent.target as web.Element?;
    if (target != null) {
      if (target.tagName.toLowerCase() == 'input' ||
          target.tagName.toLowerCase() == 'textarea' ||
          target.tagName.toLowerCase() == 'select') {
        return;
      }
    }

    final docElement = web.window.document.documentElement;
    if (docElement == null) return;

    // Handle arrow key scrolling
    switch (keyboardEvent.key) {
      case 'ArrowDown':
        docElement.scrollTop += 100;
        keyboardEvent.preventDefault();
        break;
      case 'ArrowUp':
        docElement.scrollTop -= 100;
        keyboardEvent.preventDefault();
        break;
      case 'ArrowLeft':
        docElement.scrollLeft -= 100;
        keyboardEvent.preventDefault();
        break;
      case 'ArrowRight':
        docElement.scrollLeft += 100;
        keyboardEvent.preventDefault();
        break;
      case 'PageDown':
        docElement.scrollTop += ((web.window.innerHeight) * 0.8).toInt();
        keyboardEvent.preventDefault();
        break;
      case 'PageUp':
        docElement.scrollTop -= ((web.window.innerHeight) * 0.8).toInt();
        keyboardEvent.preventDefault();
        break;
      case 'Home':
        docElement.scrollTop = 0;
        keyboardEvent.preventDefault();
        break;
      case 'End':
        docElement.scrollTop = docElement.scrollHeight;
        keyboardEvent.preventDefault();
        break;
    }
  }

  void _preventDefaultInInputs(web.Event event) {
    final keyboardEvent = event as web.KeyboardEvent;
    final target = keyboardEvent.target as web.Element?;

    // Prevent arrow key scrolling when focused on form elements
    if (target != null) {
      final tagName = target.tagName.toLowerCase();
      if (tagName == 'input' || tagName == 'textarea' || tagName == 'select') {
        if ((keyboardEvent.key.startsWith('Arrow')) ||
            keyboardEvent.key == 'PageUp' ||
            keyboardEvent.key == 'PageDown' ||
            keyboardEvent.key == 'Home' ||
            keyboardEvent.key == 'End') {
          // Let the default behavior happen for text navigation in inputs
          return;
        }
      }
    }
  }

  void dispose() {
    if (!kIsWeb) return;
    web.window.document.removeEventListener('keydown', _handleKeyDown.toJS);
    web.window.document.removeEventListener(
      'keydown',
      _preventDefaultInInputs.toJS,
    );
  }
}
