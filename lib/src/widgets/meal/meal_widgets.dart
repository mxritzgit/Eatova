/// Meal analysis widgets — a library split mechanically into `part` files
/// (cards, result card, adjustment sheets). Imports and visibility unchanged.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../models/meal_analysis_result.dart';
import '../../models/meal_component.dart';
import '../../theme/app_tokens.dart';
import '../common/basic_widgets.dart';
import '../common/motion.dart';
import '../design/design.dart';

part 'meal_widgets_cards.dart';
part 'meal_widgets_result.dart';
part 'meal_widgets_adjust.dart';
