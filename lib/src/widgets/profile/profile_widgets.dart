/// Profil-Widgets — als Bibliothek aus mehreren `part`-Dateien zusammengesetzt.
///
/// Rein mechanischer Split: die kohaerenten Widget-Gruppen liegen in den unten
/// referenzierten `part of`-Dateien. Importe + Sichtbarkeit (library-private
/// `_`-Klassen) bleiben unveraendert, kein Import-Site aendert sich.
///
/// Design-Refactor 2026-08-09: die Bibliothek liest Farbe ausschliesslich ueber
/// `context.t` ([AppTokens]) und Schrift ueber [AppType]; `app_colors.dart`
/// ist hier vollstaendig abgeloest.
library;

import 'package:flutter/material.dart';

import '../../models/user_profile.dart';
import '../../models/weight_log.dart';
import '../../services/health_service.dart';
import '../../services/kcal_calculator.dart';
import '../../theme/app_tokens.dart';
import '../design/design.dart';
import 'profile_charts.dart';

part 'profile_format.dart';
part 'profile_widgets_hero.dart';
part 'profile_widgets_body.dart';
part 'profile_widgets_goals.dart';
part 'profile_widgets_stats.dart';
part 'profile_widgets_actions.dart';
