# Eatova documentation

Current product review: **2026-09-14**, main through PR #88; security follow-up
**2026-09-15**, implementation and verified rollout in PR #92, based on main through PR #91. Begin with the
guides below. Dated reviews, plans and delivery notes remain useful evidence,
but their old feature gaps, branch snapshots and test counts are not live state.

## Current guides

| Document | Read it for |
| --- | --- |
| [Project README](../README.md) | Product overview, screenshots, stack and quick start |
| [Features and platforms](FEATURES.md) | What is implemented, entry points and current limitations |
| [Development and builds](DEVELOPMENT.md) | Client defines, toolchain, localization and release signing |
| [Backend](BACKEND.md) | AI defaults/overrides, data contracts, search credentials and deployment evidence |
| [Offline sync](OFFLINE_SYNC.md) | Transactional local storage, conflict policy, background delivery, limits and rollout |
| [Weight trend](WEIGHT-TREND.md) | How weigh-ins re-anchor the profile weight, live goals and forecast; the planned adaptive check |
| [Contributing](../CONTRIBUTING.md) | Local validation, CI gates and protected PR workflow |
| [Changelog](../CHANGELOG.md) | Merged changes and dated release history |
| [Privacy data flows](../PRIVACY.md) | Current app data processing and the separate published-policy follow-up |
| [Security policy](../SECURITY.md) | Reporting vulnerabilities and trust boundaries |
| [Security checkbook](../SECURITY_AUDIT.md) | All 91 audit points, confirmed findings, corrections and evidence limits |
| [Verified security rollout](SECURITY-ROLLOUT-2026-09-15.json) | Tested commit, green CI, deployed functions, catalog comparison and published privacy evidence |
| [Operations and recovery](OPERATIONS.md) | Backups, synthetic restore, incident response, stop switches and remaining operator decisions |
| [Build-tool security](../android/BUILD_TOOL_SECURITY.md) | Resolved toolchain advisories, actual usage and update candidates, separate from app runtime |
| [Coach evaluation](../supabase/eval/README.md) | Bounded synthetic model evaluation and offline harness tests |
| [Evaluation results, 2026-09-15](../supabase/eval/results/2026-09-15.md) | Real-model cases, budget ledger and semantic/clinical limits |
| [Local Auth probe](../scripts/security/README.md) | Disposable GoTrue tests with restricted tokens and stubbed provider calls |
| [Website privacy correction](PRIVACY-WEBSITE-CORRECTION-2026-09-14.md) | Published single-file corrections and their dated verification records |
| [Google sign-in](../supabase/OAUTH_SETUP.md) | Native Google clients and web callback setup |
| [Email OTP](../supabase/AUTH_EMAIL_OTP.md) | Current client contract and dated Auth settings/history |
| [Agent entry point](../AGENTS.md) | Repository working conventions |

## Database reference

- [Schema access state](../supabase/SCHEMA_STATE.md) is generated from all current
  migrations; use its regeneration instructions, not manual edits.
- [Migrations](../supabase/migrations) define columns, constraints, functions and
  access rules. The generated document intentionally is not a full column schema.
- [June schema snapshot](../supabase/SCHEMA_STATE_2026-06-07.md) is historical.

## Design contracts and previews

The dark redesign of 2026-09-28 (PR #118, summarized in the
[handoff](PROJECT_HANDOFF.md#dark-redesign-of-the-five-tabs-2026-09-28-to-2026-09-30))
rebuilt the five tab roots and the tab bar. Sheets, detail pages, settings,
auth and onboarding kept their structure and only took over the dark tokens,
Figtree/Bricolage Grotesque and the shared controls. For those surfaces the
older contracts below still describe behavior; their palette, typography and
light-mode previews are dated. Later focused polish takes precedence over an
earlier baseline in the same area.

| Area | Current references |
| --- | --- |
| Today | [Today (dark redesign)](TODAY-DESIGN.md) |
| Food and favorites | [Food (dark redesign)](FOOD-DESIGN.md), [Favorites](FAVORITES-DESIGN.md) |
| Meal entry and calendar | [Entry baseline](MEAL-ENTRY-DESIGN.md), [camera/manual/search/calendar polish](FOOD-ENTRY-POLISH-2026-09-14.md) |
| Recipes, plan and shopping | [Recipes (dark redesign root, Spotlight details/plan/shopping)](RECIPES-DESIGN.md) |
| Training | [Training (dark redesign root, Nachtstudio library/player)](TRAINING-DESIGN.md), [artwork provenance](../assets/training/README.md) |
| Coach | No separate contract; see the [handoff](PROJECT_HANDOFF.md#dark-redesign-of-the-five-tabs-2026-09-28-to-2026-09-30) and `test/design/coach_redesign_capture_test.dart` |
| Shared navigation and icons | [Gestures](GESTURE-NAVIGATION.md), [original icon family](ICON-FAMILY-2026-09-14.md) |
| Account and headers | [App polish](APP-POLISH-2026-09-13.md) |
| Login, signup and onboarding | [Entry](AUTH-ONBOARDING-DESIGN.md), [onboarding questions and redesign (2026-10-04)](ONBOARDING-2026-10-04.md) |

Current tab renders: [Today](dark-redesign-preview/today.png),
[Food](dark-redesign-preview/food.png), [Recipes](dark-redesign-preview/recipes.png)
and [Training](dark-redesign-preview/training.png). Regenerate them with the
`test/design/*_redesign_capture_test.dart` suites and
`--dart-define=DARK_REDESIGN_CAPTURE=true` (output in `build/dark-redesign/`; the committed copies are the `*-00` shots
at half resolution).

## Delivery records

- [Shared project handoff](PROJECT_HANDOFF.md): chronological records with
  specific source and PR evidence. Its initial September 6 snapshot is historical.
- [Core feature implementation](CORE-FEATURES-IMPLEMENTATION-2026-09-10.md):
  recipes, training history, Android steps, Coach briefs and meal planning;
  linked follow-up records the completed backend rollout.
- [Recipe completion investigation](SENTRY-RECIPE-2026-09-13.md): bounded
  investigation, regression evidence, deployed v46 and final PR #83 delivery.

## Historical reviews and migration plans

These are retained as dated reasoning/evidence. An unchecked item or an old
provider name here is not a current roadmap or configuration declaration.

- [Design-Refactor 2026-08-09 — Briefing für alle Screen-Pakete](DESIGN_REFACTOR.md)
- [i18n-Screen-Pakete — Briefing (2026-08-10)](I18N_PAKETE.md)
- [Eatova – Review wichtiger Feature-Lücken](FEATURE-REVIEW-2026-09-10.md)
- [Eatova – Feature-Lücken, zweite Runde (2026-10-10)](FEATURE-REVIEW-2026-10-10.md)
- [App design review, 2026-09-07](DESIGN-REVIEW-2026-09-07.md)
- [Eatova — Vollständiger Code-Review](REVIEW-2026-08-08.md)
- [Projektreview Eatova — 2026-09-07](REVIEW-2026-09-07.md)
- [Eatova review and fixes, 2026-09-08](REVIEW-2026-09-08.md)
- [Eatova — Review der Kalorien-Berechnungen (2026-08-21)](REVIEW-KCAL-2026-08-21.md)
- [Training design, 2026-09-08](TRAINING-DESIGN-2026-09-08.md)
- [Training visual review, 2026-09-08](TRAINING-VISUAL-REVIEW-2026-09-08.md)
- [Nativer Google Sign-In Implementation Plan](superpowers/plans/2026-08-05-google-native-signin.md)
- [i18n-Grundgerüst (Deutsch + Englisch) — Implementierungsplan](superpowers/plans/2026-08-10-i18n-grundgeruest.md)
- [Coach-Rezept-Generator (`/rezept`) Implementation Plan](superpowers/plans/2026-08-12-coach-rezept-generator.md)
- [Manueller Mahlzeiten-Eintrag + /recipe-„Hinzugefügt"-Fix — Implementation Plan](superpowers/plans/2026-08-13-manuelle-mahlzeit-und-coach-added-fix.md)
- [Eatova — Performance-Härtung (60 FPS, saubere Übergänge, robuste Listen)](superpowers/specs/2026-06-01-eatova-performance-design.md)
- [Eatova — Komplett-Review & Roadmap „von gut zu richtig gut"](superpowers/specs/2026-06-02-app-review-and-roadmap.md)
- [Eatova — Verlauf im Food-Tab per Swipe löschen](superpowers/specs/2026-06-02-food-history-swipe-delete-design.md)
- [Eatova — Mahlzeit-Slot im Food-Add-Flow wählbar machen](superpowers/specs/2026-06-02-food-slot-selector-design.md)
- [Eatova — Snackbar-Toasts kürzen & polieren](superpowers/specs/2026-06-02-snackbar-toasts-design.md)
- [Eatova — Deep-Dive-Follow-up „von gut zu richtig gut" (Stand nach Welle-A/B-Ausführung)](superpowers/specs/2026-06-04-deepdive-followup.md)
- [Eatova — Umsetzungs-Brief (Deep-Dive 2026-06-04)](superpowers/specs/2026-06-04-implementation-plan.md)
- [Eatova — Umsetzungs-Status (Deep-Dive 2026-06-04, Abschluss)](superpowers/specs/2026-06-04-implementation-status.md)
- [Design: Nativer Google Sign-In — „Eatova" statt „…supabase.co"](superpowers/specs/2026-08-05-google-native-signin-design.md)
- [Abarbeitung des Reviews vom 2026-08-08 — Design](superpowers/specs/2026-08-08-review-abarbeitung-design.md)
- [Mehrsprachigkeit (i18n) — Design, 2026-08-10](superpowers/specs/2026-08-10-i18n-design.md)
- [Coach-Rezept-Generator (`/rezept`) — Design](superpowers/specs/2026-08-12-coach-rezept-generator-design.md)
- [Manueller Mahlzeiten-Eintrag + /recipe-„Hinzugefügt"-Fix — Design](superpowers/specs/2026-08-13-manuelle-mahlzeit-und-coach-added-fix-design.md)

## Platform scaffolding

[iOS launch-image notes](../ios/Runner/Assets.xcassets/LaunchImage.imageset/README.md)
describe the platform asset folder, not the current in-app splash design.

## Keeping these docs current

Update README/feature/platform entries when behavior changes, and Backend when
models, overrides or data flows change. Keep setup commands aligned with code
and workflows. Add a dated delivery record for consequential rollout changes;
do not rewrite historical observations as if the new behavior existed then.
Distinguish code verified, CI passed, PR merged, backend deployed and app installed.
The published website policy has its own deployment and currently needs the
[documented follow-up](BACKEND.md#published-privacy-documentation-follow-up).
