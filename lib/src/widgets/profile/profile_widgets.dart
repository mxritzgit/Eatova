/// Profil-Widgets — als Bibliothek aus mehreren `part`-Dateien zusammengesetzt.
///
/// Rein mechanischer Split: die kohaerenten Widget-Gruppen liegen in den unten
/// referenzierten `part of`-Dateien. Importe + Sichtbarkeit (library-private
/// `_`-Klassen) bleiben unveraendert, kein Import-Site aendert sich.
library;

import 'package:flutter/material.dart';

import '../../models/lifetime_stats.dart';
import '../../models/user_profile.dart';
import '../../models/weight_log.dart';
import '../../services/health_service.dart';
import '../../services/kcal_calculator.dart';
import '../../theme/app_colors.dart';
import '../common/basic_widgets.dart';
import '../common/motion.dart';
import 'profile_charts.dart';

part 'profile_widgets_hero.dart';
part 'profile_widgets_body.dart';
part 'profile_widgets_goals.dart';
part 'profile_widgets_stats.dart';
part 'profile_widgets_actions.dart';
