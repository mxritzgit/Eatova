/// Meal-Analyse-Widgets — als Bibliothek aus mehreren `part`-Dateien gebaut.
///
/// Rein mechanischer Split: die kohaerenten Gruppen (Cards, Result-Karte,
/// Anpassungs-Sheets) liegen in den unten referenzierten `part of`-Dateien.
/// Importe + Sichtbarkeit (library-private `_`-Klassen) bleiben unveraendert,
/// kein Import-Site aendert sich.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/meal_analysis_result.dart';
import '../../models/meal_component.dart';
import '../../theme/app_tokens.dart';
import '../common/basic_widgets.dart';
import '../common/motion.dart';
import '../design/design.dart';

part 'meal_widgets_cards.dart';
part 'meal_widgets_result.dart';
part 'meal_widgets_adjust.dart';
