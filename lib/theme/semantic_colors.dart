import 'package:flutter/material.dart';

@immutable
class SemanticColors extends ThemeExtension<SemanticColors> {
  final Color success;
  final Color onSuccess;
  final Color successContainer;
  final Color onSuccessContainer;

  const SemanticColors({
    required this.success,
    required this.onSuccess,
    required this.successContainer,
    required this.onSuccessContainer,
  });

  /// Returns the semantic colors for the current theme, falling back to
  /// contrast-checked defaults when the extension is not registered.
  static SemanticColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<SemanticColors>() ??
        (theme.brightness == Brightness.dark
            ? const SemanticColors(
                success: Color(0xFF34D399),
                onSuccess: Color(0xFF052E16),
                successContainer: Color(0xFF064E3B),
                onSuccessContainer: Color(0xFFA7F3D0),
              )
            : const SemanticColors(
                success: Color(0xFF047857),
                onSuccess: Colors.white,
                successContainer: Color(0xFFDCFCE7),
                onSuccessContainer: Color(0xFF064E3B),
              ));
  }

  @override
  SemanticColors copyWith({
    Color? success,
    Color? onSuccess,
    Color? successContainer,
    Color? onSuccessContainer,
  }) {
    return SemanticColors(
      success: success ?? this.success,
      onSuccess: onSuccess ?? this.onSuccess,
      successContainer: successContainer ?? this.successContainer,
      onSuccessContainer: onSuccessContainer ?? this.onSuccessContainer,
    );
  }

  @override
  SemanticColors lerp(ThemeExtension<SemanticColors>? other, double t) {
    if (other is! SemanticColors) return this;
    return SemanticColors(
      success: Color.lerp(success, other.success, t) ?? success,
      onSuccess: Color.lerp(onSuccess, other.onSuccess, t) ?? onSuccess,
      successContainer:
          Color.lerp(successContainer, other.successContainer, t) ??
          successContainer,
      onSuccessContainer:
          Color.lerp(onSuccessContainer, other.onSuccessContainer, t) ??
          onSuccessContainer,
    );
  }
}
