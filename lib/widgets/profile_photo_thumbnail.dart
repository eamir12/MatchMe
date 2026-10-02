import 'package:flutter/material.dart';

class ProfilePhotoThumbnail extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final Widget child;

  const ProfilePhotoThumbnail({
    super.key,
    required this.label,
    required this.onTap,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      onTap: onTap,
      child: Tooltip(
        message: label,
        triggerMode: TooltipTriggerMode.longPress,
        excludeFromSemantics: true,
        child: GestureDetector(onTap: onTap, child: child),
      ),
    );
  }
}
