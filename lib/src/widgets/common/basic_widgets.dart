import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';

class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(text, style: AppType.eyebrow(context.t.ink2, size: 11));
  }
}
