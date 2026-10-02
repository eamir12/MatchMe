import 'package:flutter/material.dart';

class AppRecoveryBanner extends StatelessWidget {
  final String? title;
  final String message;
  final String retryLabel;
  final VoidCallback onRetry;
  final bool isLoading;
  final IconData icon;

  const AppRecoveryBanner({
    super.key,
    required this.message,
    required this.retryLabel,
    required this.onRetry,
    this.title,
    this.isLoading = false,
    this.icon = Icons.error_outline_rounded,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final accessibleLabel = title == null ? message : '$title. $message';

    return Semantics(
      container: true,
      liveRegion: true,
      label: accessibleLabel,
      child: Material(
        color: colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: colorScheme.onErrorContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (title != null) ...[
                      Text(
                        title!,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: colorScheme.onErrorContainer,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                    ],
                    Text(
                      message,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onErrorContainer,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Semantics(
                button: true,
                enabled: !isLoading,
                label: retryLabel,
                child: FilledButton.tonal(
                  onPressed: isLoading ? null : onRetry,
                  child: isLoading
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: colorScheme.onErrorContainer,
                          ),
                        )
                      : Text(retryLabel),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
