// services/keyboard_service.dart
// Service for handling keyboard navigation in web browsers

import 'dart:html' as html; // ignore: deprecated_member_use,avoid_web_libraries_in_flutter
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
    html.document.addEventListener('keydown', _handleKeyDown);
    
    // Prevent default behavior for arrow keys when not in input fields
    html.document.addEventListener('keydown', _preventDefaultInInputs);
  }

  void _handleKeyDown(html.Event event) {
    final keyboardEvent = event as html.KeyboardEvent;
    
    // Only handle scrolling when not in input fields
    final target = keyboardEvent.target;
    if (target is html.InputElement || 
        target is html.TextAreaElement || 
        target is html.SelectElement) {
      return;
    }

    final docElement = html.document.documentElement;
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
        docElement.scrollTop += ((html.window.innerHeight ?? 0) * 0.8).toInt();
        keyboardEvent.preventDefault();
        break;
      case 'PageUp':
        docElement.scrollTop -= ((html.window.innerHeight ?? 0) * 0.8).toInt();
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

  void _preventDefaultInInputs(html.Event event) {
    final keyboardEvent = event as html.KeyboardEvent;
    final target = keyboardEvent.target;
    
    // Prevent arrow key scrolling when focused on form elements
    if (target is html.InputElement || 
        target is html.TextAreaElement || 
        target is html.SelectElement) {
      if ((keyboardEvent.key?.startsWith('Arrow') ?? false) ||
          keyboardEvent.key == 'PageUp' ||
          keyboardEvent.key == 'PageDown' ||
          keyboardEvent.key == 'Home' ||
          keyboardEvent.key == 'End') {
        // Let the default behavior happen for text navigation in inputs
        return;
      }
    }
  }

  void dispose() {
    if (!kIsWeb) return;
    
    html.document.removeEventListener('keydown', _handleKeyDown);
    html.document.removeEventListener('keydown', _preventDefaultInInputs);
    _isInitialized = false;
  }
}