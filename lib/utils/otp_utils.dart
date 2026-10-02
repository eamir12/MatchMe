/// Shared helpers for email OTP handling.
///
/// All OTP verification paths (signup, password recovery, sensitive-action
/// reauthentication, email change) must normalize the email and the code in
/// exactly the same way for both the "send" and the "verify" step. Otherwise
/// a code that was correctly received via email can be rejected as
/// "incorrect or expired" because of copy/paste artifacts (spaces, dashes,
/// newlines, non-breaking spaces, RTL marks) or email casing.
class OtpUtils {
  OtpUtils._();

  /// Normalizes an email address for OTP requests and verifications.
  static String normalizeEmail(String email) => email.trim().toLowerCase();

  /// Sanitizes a user-entered OTP code.
  ///
  /// Removes surrounding whitespace plus any internal separators users
  /// commonly paste from email clients (spaces, non-breaking spaces,
  /// zero-width/RTL marks, dashes), and converts common Unicode digits
  /// (Arabic-Indic, Eastern Arabic-Indic, fullwidth) to ASCII digits.
  /// The result is what must be sent to the backend for verification.
  static String sanitizeCode(String code) {
    var result = code.trim();
    if (result.isEmpty) return '';
    final buffer = StringBuffer();
    for (final rune in result.runes) {
      final ascii = _toAsciiDigit(rune);
      if (ascii != null) {
        buffer.write(ascii);
        continue;
      }
      if (_isSeparator(rune)) continue;
      buffer.writeCharCode(rune);
    }
    return buffer.toString().trim();
  }

  static String? _toAsciiDigit(int rune) {
    // ASCII 0-9
    if (rune >= 0x30 && rune <= 0x39) return String.fromCharCode(rune);
    // Arabic-Indic ٠-٩
    if (rune >= 0x0660 && rune <= 0x0669) {
      return String.fromCharCode(0x30 + (rune - 0x0660));
    }
    // Eastern Arabic-Indic (Persian/Urdu) ۰-۹
    if (rune >= 0x06F0 && rune <= 0x06F9) {
      return String.fromCharCode(0x30 + (rune - 0x06F0));
    }
    // Fullwidth ０-９
    if (rune >= 0xFF10 && rune <= 0xFF19) {
      return String.fromCharCode(0x30 + (rune - 0xFF10));
    }
    return null;
  }

  static bool _isSeparator(int rune) {
    // ASCII whitespace and common separators.
    if (rune == 0x20 || // space
        rune == 0x09 || // tab
        rune == 0x0A || // LF
        rune == 0x0D || // CR
        rune == 0x2D || // hyphen-minus
        rune == 0x5F) {
      // underscore (some clients group as 123_456)
      return true;
    }
    // Unicode spaces.
    if (rune == 0x00A0 || // NBSP
        rune == 0x1680 ||
        (rune >= 0x2000 && rune <= 0x200F) || // spaces + ZWSP/ZWNJ/ZWJ/LRM/RLM
        (rune >= 0x2028 && rune <= 0x202F) ||
        rune == 0x205F ||
        rune == 0x3000 ||
        rune == 0xFEFF) {
      // BOM / zero-width no-break space
      return true;
    }
    // Unicode dashes.
    if (rune == 0x2010 || // hyphen
        rune == 0x2011 || // non-breaking hyphen
        rune == 0x2012 || // figure dash
        rune == 0x2013 || // en dash
        rune == 0x2014 || // em dash
        rune == 0x2212) {
      // minus sign
      return true;
    }
    return false;
  }
}
