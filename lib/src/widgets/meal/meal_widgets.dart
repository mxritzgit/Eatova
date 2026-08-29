/// Meal analysis widgets — a library split mechanically into `part` files
/// (cards, result card, adjustment sheets). Imports and visibility unchanged.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../models/meal_analysis_result.dart';
import '../../models/meal_component.dart';
// P8-02c: the adjustment sheet's input bounds come from HERE, not from
// hand-copied literals. `show` keeps the part files' namespace narrow — only
// the two bound holders, none of the clamp helpers.
import '../../models/model_limits.dart'
    show LoggedMealLimits, PlausibilityLimits;
import '../../theme/app_tokens.dart';
import '../common/basic_widgets.dart';
import '../common/motion.dart';
import '../design/design.dart';

part 'meal_widgets_cards.dart';
part 'meal_widgets_result.dart';
part 'meal_widgets_adjust.dart';
