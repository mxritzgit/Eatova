import 'package:flutter/material.dart';

import 'app_icon.dart';

/// Two staggered shoe prints, shared by step counts and step goals.
class StepsIcon extends StatelessWidget {
  const StepsIcon({super.key, this.size, this.color});

  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) => AppIcon(
    AppSymbol.steps,
    size: size,
    color: color,
  );
}
