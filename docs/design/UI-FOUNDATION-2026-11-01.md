# UI foundation, 2026-11-01

The shared base layer of the UI polish round: one icon layer, one button
family, one list anatomy, real enumerations, one status pill and one empty
state. It is the main reference for the screen rounds. Everything is
exported from `lib/src/widgets/design/design.dart` (including `AppIcons`);
tokens and type roles come from `lib/src/theme/app_tokens.dart`.

```dart
import '../../theme/app_tokens.dart';      // context.t, AppType, kSpace*, radii
import '../../widgets/design/design.dart'; // widgets, AppIcons, AppIconSize
```

Older class names stay as thin wrappers, so keys, finders and callers keep
working (see [Wrappers](#wrappers-you-must-not-break)). Previews of every new
component are in `design_previews.dart`.

## 1. Icons: `AppIcons` and `AppIconSize`

**Family: Material Icons from the SDK ("option B"), no new dependency.**
Material Symbols Rounded (option A) was built and measured with release
builds (`flutter build apk --release --target-platform android-arm64`, dummy
defines) and failed the size gate once fully migrated:

| Build | Symbols Rounded after shaking | APK (arm64) |
| --- | --- | --- |
| Base `4b319613`, no package | – (MaterialIcons 28,724 B) | 59,190,531 B |
| Package, foundation only | 18,080 B | 59,204,482 B (+13.9 kB) |
| Package, all 152 concepts referenced | **444,760 B** (limit 250 kB) | 59,422,594 B (+232 kB, limit 300 kB) |

The axes survive the subset (fvar FILL/GRAD/opsz/wght, gvar on 239 of 240
glyphs), but the fully migrated font is 1.8x the limit, so option B holds.
Pinning the weight to 400 and narrowing opsz/GRAD would bring the same 152
glyphs to about 116 kB with the fill axis intact; that needs a bundled,
pre-instanced font and is left for the owner. Switching families is a change
to `lib/src/theme/app_icons.dart` (plus the package): screens only name
concepts.

**Rules**

- Screens name a concept, never a font glyph: `Icon(AppIcons.edit)`.
- Objects are contours (`*_outline_rounded`, else `*_outlined`); line glyphs
  (check, plus, chevrons, arrows, close) are `*_rounded`.
- Filled means **on**: a set favourite, saved, done/eaten, listening. Use
  `StateIcon(AppIcons.favorite, on: isFavorite)` or
  `AppIconButton(selected: …)`; both draw `AppIcons.filled(icon)` when on.
- `AppIcons.aiMark` (sparkles) only as the AI origin mark right next to the
  word "KI"/"AI" (disclosure, consent, AI estimate). Elsewhere use the task's
  glyph (camera, note, document); the Coach keeps its conversation glyph.
- Steps are the custom `StepsIcon()`, never a walking person.
- The custom painters (`AppIcon`, `SlotIconTile`, `FoodGlyph`, `RecipeGlyph`,
  `TodayGlyph`, `TrainingWorkoutGlyph`) stay; no new painter sets.
- Missing concept: do not spell out `Icons.*` in a screen; report it. The
  integration adds it to `AppIcons`. `test/repo_rules_test.dart`
  ("Icon-Familie") forbids `Icons.*` in theme, design and common today and
  will be widened to all of `lib/`; it also forbids `IconData(` by hand and
  any `Symbols.*` outside `app_icons.dart`.

**Concepts** (152; the names follow appendix A of the brief, so a mechanical
`Icons.x` → `AppIcons.y` mapping works):

| Group | `AppIcons` (glyph) |
| --- | --- |
| Actions | `add` (add_rounded), `remove` (remove_rounded), `edit` (edit_outlined), `editNote` (edit_note_outlined), `editOff` (edit_off_outlined), `delete` (delete_outline_rounded), `close` (close_rounded), `check` (check_rounded), `doneAll` (done_all_rounded), `copy` (content_copy_outlined), `contentPaste` (content_paste_outlined), `folderCopy` (folder_copy_outlined), `search` (search_rounded), `searchOff` (search_off_rounded), `manageSearch` (manage_search_rounded), `imageSearch` (image_search_outlined), `refresh` (refresh_rounded), `replay` (replay_rounded), `restartAlt` (restart_alt_rounded), `restore` (restore_rounded), `autorenew` (autorenew_rounded), `sync` (sync_rounded), `syncProblem` (sync_problem_rounded), `undo` (undo_rounded), `redo` (redo_rounded), `iosShare` (ios_share_rounded), `fileDownload` (file_download_outlined), `openInNew` (open_in_new_rounded), `link` (link_rounded), `linkOff` (link_off_rounded), `logout` (logout_rounded), `tune` (tune_rounded), `sort` (sort_rounded), `swapHoriz` (swap_horiz_rounded), `moreHoriz` (more_horiz_rounded), `playlistAddCheck` (playlist_add_check_rounded), `playlistRemove` (playlist_remove_rounded), `translate` (translate_rounded) |
| Navigation | `chevronLeft`, `chevronRight`, `expandMore`, `expandLess`, `arrowBack`, `arrowForward`, `arrowUpward`, `arrowDownward`, `arrowOutward`, `northEast` (all `*_rounded`) |
| Status | `info` (info_outline_rounded), `error` (error_outline_rounded), `warning` (warning_amber_rounded), `priorityHigh` (priority_high_rounded), `lightbulb` (lightbulb_outline_rounded), `checkCircle` (check_circle_outline_rounded), `removeCircle` (remove_circle_outline_rounded), `cloudOff`, `cloudDone`, `cloudSync`, `cloudUpload` (`*_outlined`), `hourglassEmpty` (hourglass_empty_rounded), `hourglassTop` (hourglass_top_rounded), `schedule` (schedule_rounded), `timer` (timer_outlined), `history` (history_rounded), `historyToggleOff` (history_toggle_off_rounded), `lock` (lock_outline_rounded), `lockReset` (lock_reset_rounded), `lockClock` (lock_clock_outlined), `key` (key_outlined), `shield` (shield_outlined), `healthAndSafety` (health_and_safety_outlined), `visibility` (visibility_outlined), `visibilityOff` (visibility_off_outlined), `science` (science_outlined), `factCheck` (fact_check_outlined), `thumbDownAlt` (thumb_down_alt_outlined), `aiMark` (auto_awesome_outlined) |
| States | `favorite` (favorite_outline_rounded), `bookmarkAdded` (bookmark_added_outlined), `bookmarkAdd` (bookmark_add_outlined); filled forms via `AppIcons.filled` |
| Media | `playArrow`, `pause`, `stop`, `skipNext` (`*_rounded`), `pauseCircle` (pause_circle_outline_rounded), `mic` (mic_none_rounded) |
| People and messages | `person` (person_outline_rounded), `manageAccounts` (manage_accounts_outlined), `mail` (mail_outline_rounded), `markEmailRead`, `markEmailUnread` (`*_outlined`), `alternateEmail` (alternate_email_rounded), `chatBubble` (chat_bubble_outline_rounded), `forum` (forum_outlined), `notifications` (notifications_none_rounded), `notificationsActive`, `notificationsOff`, `settings`, `workspacePremium`, `phoneAndroid`, `keyboard`, `keyboardAlt`, `cake` (`*_outlined`), `female`, `male`, `height`, `accessibilityNew` (`*_rounded`) |
| Food and planning | `restaurant`, `restaurantMenu` (`*_rounded`), `setMeal`, `soupKitchen`, `menuBook`, `noFood`, `eco`, `spa`, `shoppingBasket`, `storefront`, `warehouse` (`*_outlined`), `flame` (local_fire_department_outlined), `calculate` (calculate_outlined), `balance` (balance_rounded), `calendar` (calendar_month_outlined), `eventAvailable`, `eventNote`, `description`, `tableRows`, `gridOn`, `flag` (`*_outlined`), `notes`, `formatListNumbered` (`*_rounded`) |
| Body and progress | `monitorWeight`, `straighten`, `trophy` (emoji_events), `donutSmall` (`*_outlined`), `fitnessCenter`, `speed`, `insights`, `queryStats`, `showChart`, `trendingUp`, `trendingDown`, `trendingFlat`, `contrast` (`*_rounded`) |
| Camera and images | `photoCamera`, `addAPhoto`, `noPhotography`, `photoLibrary`, `image`, `hideImage`, `imageNotSupported` (`*_outlined`), `flashOn`, `flashOff` (`*_rounded`) |

Merged concepts: every edit pencil → `edit`; `edit_note` → `editNote`;
`favorite_border`/`favorite_outline`/`favorite` → `favorite` (+ state);
`copy`/`copy_outlined`/`content_copy` → `copy`; `check_circle*`/`task_alt`
→ `checkCircle`; `calendar_today`/`today`/`calendar_month` → `calendar`;
`photo_outlined`/`image_outlined` → `image`; `directions_walk` → `StepsIcon`.

**Sizes** (`AppIconSize`; any other literal is off the scale):

| Constant | px | Where |
| --- | --- | --- |
| `meta` | 14 | meta lines, `StatusPill`, small chips |
| `small` | 16 | beside 13–14 px text, badge `sm`, chips |
| `button` | 18 | inside labelled buttons (primary, soft, text) |
| `standard` | 20 | icon buttons, menu rows, chevrons, badge `md` (theme default) |
| `tile` | 22 | badge `lg`, the tab roots' design glyphs |
| `large` | 24 | large icon buttons, empty states |

A glyph beside multi-line text centres on the **first** line (see
`BulletList`, `SignalNote`).

## 2. Tokens and type roles (additive)

Space: `kSpace4/8/12/16/20/24/32`, `kPageGutter` 20, `kCardInset` 18,
`kRowLeadingGap` 14, `kCardGap` 14, `kSectionGap` 28. New code uses only
these; existing code moves to them only where you touch it.

Type roles on `AppType` (half sizes move to the nearest role when touched:
10.5→11, 11.5/12.5→12, 13.5→14, 14.5/15.5→15; nothing below
`AppType.minSize` = 11; `AppType.eyebrow` now defaults to 11):

| Role | Style | Typical use |
| --- | --- | --- |
| `pageTitle` (existing) | Display 36/800 (subpage 24) | page title |
| `sheetTitleStyle` (existing) | Display 24 (compact 20) | sheet title |
| `title2(c)` | Display 19/700, h1.2 | card title, `CalmState` card |
| `section(c)` | Display 17/700 | `SectionHeading`, `ListSection` |
| `headline(c)` | UI 16/700, −0.2 | option card title, inline empty state |
| `rowTitle(c)` | UI 15/600 | row title |
| `body(c)` | UI 15/400, h1.45 | running text, steps, bullets |
| `callout(c)` | UI 14/400, h1.4 | card and empty-state copy |
| `subhead(c)` | UI 13/400, h1.35 | row subtitle, hints, footnotes |
| `caption(c)` | UI 12/600 | meta lines |
| `sectionEyebrow` (existing) | UI 12/700 caps | eyebrow above a card title |
| `micro(c)` | UI 11/600 | nav label, badge: the floor |
| `numeric(size, …)` | Display, tabular | numbers; in Figtree `AppType.ui(…, tabular: true)` |

`AppTokens.iconGrade` (dark −25, light 0) and the theme's icon axes are ready
for a variable icon font; Material Icons ignores them. The theme now sets
`focusColor` ink @ 10 % and `hoverColor` ink @ 4 % for plain InkWells.

## 3. Buttons

| Rank | Widget | Use |
| --- | --- | --- |
| Primary (lit) | `PrimaryActionButton` (unchanged; 54, `height: 48` in cards, `busy`, `destructive`) | the ONE most likely action of a view |
| Secondary | `SoftPillButton(tone: accent | neutral)` | "do something here" / an alternative |
| Quiet | `SoftPillButton(tone: quiet)`, `EatovaTextAction` | cancel, "Nicht jetzt", "Später", links |
| Destructive entry | `SoftPillButton(tone: danger)`, `ListRow(destructive: true)`, `MenuRow(destructive: true)` | red FILL only on the confirming action of the decision card |
| Icon only | `AppIconButton` | every icon-only action |

New on `SoftPillButton`: `size: SoftPillSize.regular` (54) and `busy`.

Rules: at most one lit action per view. A secondary action directly under the
primary one is `size: SoftPillSize.regular, expand: true`. A dismissal is
always `quiet`, never `neutral`. ARB texts stay word for word.

```dart
PrimaryActionButton(label: l10n.commonSave, onTap: save, busy: saving),
const SizedBox(height: kSpace8),
SoftPillButton(label: l10n.commonNotNow, onTap: later,
    tone: SoftPillTone.quiet, size: SoftPillSize.regular, expand: true),
```

### `AppIconButton`

```dart
AppIconButton(
  icon: AppIcons.add,               // or child: StepsIcon()
  semanticLabel: l10n.todayAddMeal, // required: spoken name + tooltip
  onTap: add,                       // null = disabled (45 %, reported)
  tone: IconButtonTone.accent,      // neutral | accent | primary | plain | danger
  size: IconButtonSize.regular,     // compact 36-in-44 | regular 44 | large 56
  selected: isFavorite,             // toggle: filled glyph + Semantics(toggled)
  busy: saving,                     // spinner instead of the glyph
  haptic: true,                     // light impact on tap (confirm, add)
  target: 48,                       // larger tap target if needed
  buttonKey: const ValueKey('…'),   // on the inner InkWell; `key` on the widget
)
```

`neutral` softFill/inkMuted (back, close, calendar); `accent` tint (add to a
slot, stepper); `primary` lit with cast light (the one main action, e.g. the
player's set check); `plain` no fill until pressed (delete, clear, menu in a
row); `danger` red tint. Always a circle; the target is at least 44 and a tap
on its margin counts. `onLongPress` is available (it disables the tooltip).

### `AppStepper`

```dart
AppStepper(
  value: '$grams', unit: 'g',
  semanticLabel: l10n.foodAmount,
  increasedValue: '${grams + 10} g', decreasedValue: '${grams - 10} g',
  onDecrement: grams > 10 ? () => setGrams(grams - 10) : null, // null = limit
  onIncrement: () => setGrams(grams + 10),
  onLongPressIncrement: fastForward,           // optional
  decrementKey: const ValueKey('…-minus'),     // go on the buttons
  incrementKey: const ValueKey('…-plus'),
  size: IconButtonSize.compact,                // in a dense row
)
```

One adjustable semantics node (swipe up/down); the buttons keep their own
labels (`commonDecrease`/`commonIncrease` unless you pass labels). Every step
clicks (`selectionClick`). `increasedValue`/`decreasedValue` are required:
Flutter asserts value and neighbours together.

## 4. `IconBadge`

| Size | Edge | Glyph | Radius | Use |
| --- | --- | --- | --- | --- |
| `IconBadgeSize.sm` | 32 | 16 | rChip | dense rows, plan, sessions |
| `IconBadgeSize.md` (default) | 40 | 20 | rChip | list rows |
| `IconBadgeSize.lg` | 44 | 22 | rControl | tab roots, empty states, option cards |

Tone: `IconBadgeTone.neutral` (tile/inkMuted), `.accent` (accentTint/
accentText), `.solid` (rare, never beside a lit action), or `color: t.protein`
for a tint at 15 % with a readable glyph. `child:` takes `StepsIcon`,
`TodayGlyphIcon` etc. Always decorative (`ExcludeSemantics`).

```dart
IconBadge(icon: AppIcons.flame, size: IconBadgeSize.lg, tone: IconBadgeTone.accent)
IconBadge(child: const StepsIcon(), color: t.activity)
```

## 5. Lists: `ListSection` and `ListRow`

```
| 18 | badge md 40 | 14 | title 15/600 / subtitle 13 | 12 | value 14/600 tnum | 6 | › 20 ink3 | 18 |
```

```dart
ListSection(
  title: l10n.settingsAccount,             // SectionHeading 17/700, level 2
  action: EatovaTextAction(label: l10n.commonAll, onTap: openAll), // optional
  footnote: l10n.settingsAccountNote,      // subhead under the card
  inset: ListDividerInset.text,            // text 72 | textLg 76 | edge 18
  children: [
    ListRow(icon: AppIcons.person, title: …, subtitle: …,
        trailing: ListTrailing.chevron, onTap: openProfile),
    ListRow(icon: AppIcons.translate, title: …, value: 'Deutsch',
        trailing: ListTrailing.chevron, onTap: pickLanguage),
    ListRow(icon: AppIcons.notifications, title: …,
        trailing: ListTrailing.toggle, toggled: on, onToggle: setOn,
        toggleKey: const ValueKey('settings-notifications')),
    ListRow(icon: AppIcons.shield, title: …, trailing: ListTrailing.external,
        onTap: openPrivacy),
    ListRow(icon: AppIcons.logout, title: …, destructive: true, onTap: signOut),
  ],
)
```

Trailing rule: `chevron` only when the row navigates to a page or sheet;
`external` for links out of the app; `check` with `selected:` in picker
lists; `toggle` (the whole row switches); `value`/`none` for actions (sign
out, delete, export) and plain values — no chevron. `leading:` takes any
widget (photo with `rThumb`, `SlotIconTile`) instead of `icon:`; `end:` adds
a widget before the trailing mark (a `StatusPill`); `below:` puts a control
on its own line (segments, retry) outside the row's tap area.

A row is one semantics node (title, subtitle and value in one label; button
when it has `onTap`; toggled; selected). Min height 56 (68 with a badge).
Long values (over 45 % of the width) move under the title; from 1.6x text the
badge moves above the text and the hairlines start at 18
(`listRowStacked(context)`). No scale on press (rows are tapped often).
`ListSection` adds `kSectionGap` below itself (`spacing: 0` to drop it).

`SectionHeading(title:, trailing: 'muted note', action: EatovaTextAction(…))`:
the action sits on the title's baseline with its label flush to the content
edge.

## 6. Enumerations (`lists.dart`)

```dart
BulletList(items: ingredients)                 // accent dot, body text, gap 6
BulletList(items: lines, gap: 12, markerColor: t.onBrandSurface)
BulletList.icons(entries: [(icon: AppIcons.checkCircle, color: t.success, text: …)])
NumberedSteps(steps: steps, hint: l10n.recipesStepsHint)   // StepNumber 26, "Schritt 2 von 5. …"
NumberedSteps(steps: steps, numberSize: 32, style: AppType.body(t.ink).copyWith(fontSize: 17)) // cooking mode
StepNumber(3)            // 26 inline
StepNumber(3, size: 32)  // leading a row or form section
```

Markers already in the data ("- ", "•", "*", "·", "–", "1.", "2)") give way
to the drawn ones (`BulletList.stripMarker`, `NumberedSteps.stripMarker`).
Fewer than two steps stay a paragraph. Numbers only for real sequences
(preparation, exercise order, import candidates, creation-form sections).
No "•" in strings.

Wrappers: `RecipeIngredientLines`, `RecipePreparationSteps`,
`RecipeStepBadge` (→ `StepNumber`), `DecisionConsequence` (→ one
`BulletList.icons` entry), `CreationSectionHeading` (now `StepNumber(32)` +
`title2`, the old "01" tile is gone).

## 7. `StatusPill`, `CalmState`, loading

`StatusPill` is a status or meta note that is **not** tappable:

```dart
StatusPill(label: l10n.todayStreakDays(n), dot: true, tone: StatusTone.success)
StatusPill(label: l10n.foodAiEstimate, icon: AppIcons.aiMark, tone: StatusTone.accent)
StatusPill(label: '3 g', color: t.protein, dot: true) // a macro hue on the mark only
```

Tones: `neutral`, `accent`, `success`, `warning`, `danger` (tile fill, only
the mark coloured). Tappable? Choice → `FilterChipPill`; action →
`SoftPillButton(size default, tone: neutral)`. `SourcePill` keeps its tap.

`CalmState(icon:, title:, text:, actions:)`: inline = neutral badge `lg`,
`headline` + `callout`; `card: true` = accent badge `lg`, `title2` (level-2
heading) + `callout`. At most two soft actions, never a lit one, never red.
Copy says what is and how to go on; errors say what happened and offer
retry. `SignalNote` (default glyph `AppIcons.info`, 16 px on the first line)
for inline notes and boxed banners.

Loading: `SkeletonCard`/`SkeletonRow`/`SkeletonBar` (static, tile 40, Food
44) for page and list loads; `AppSpinner` only, 18 in a button, 22 in a
module, never full-screen except boot; over about 10 s staged copy with
"Schritt n von m". `PrimaryActionButton(busy:)`, `SoftPillButton(busy:)`,
`AppIconButton(busy:)` instead of a spinner on top of a button.

## 8. Instead of X, use Y

| Instead of | Use |
| --- | --- |
| `Icons.*` in a screen | `AppIcons.*` (report a missing concept) |
| `Icon(size: 17/19/21/…)` | an `AppIconSize` constant |
| raw `IconButton(...)` | `AppIconButton(tone: plain/neutral/…)` |
| `_RoundButton`, `_AddButton`, `_RoundIconButton`, `TrainingRoundButton` internals | `AppIconButton` (keep the old class name as a wrapper where tests use it) |
| a private stepper / `GestureDetector` +/- | `AppStepper` |
| `IconTile(size: 30…48)` / private tiles | `IconBadge(size: sm/md/lg)` |
| `SettingsStudioGroup/Row`, private `*Row` | `ListSection` / `ListRow` |
| a chevron on an action row | `trailing: ListTrailing.none` |
| "01" text, `_StepBadge`, custom number circles | `StepNumber` / `NumberedSteps` |
| a hand-built dot list | `BulletList` |
| `_MetaChip`, `_Pill`, `_TintChip`, `_StreakPill`… (not tappable) | `StatusPill` |
| `_ShoppingEmpty`, `_ErrorCard`, `_EmptyDraft` | `CalmState` / `SignalNote(boxed: true)` |
| `CircularProgressIndicator` | `AppSpinner` or a `busy:` button |
| "Nicht jetzt" as `neutral` | `SoftPillTone.quiet` |
| `AppType.ui(10.5/11.5/12.5/13.5/14.5)` | the nearest role |
| `AppType.display(19, …)` card title | `AppType.title2` |

## Wrappers you must not break

| Old name | Now | Contract kept |
| --- | --- | --- |
| `HeaderIconButton(.custom)` | regular `AppIconButton`, `primary` → lit | `tester.widget<HeaderIconButton>(key).onTap`, 44 px |
| `SquareIconButton` | compact `AppIconButton` (round now) | 44 px target |
| `PageHeader` back | `HeaderIconButton(AppIcons.chevronLeft)` in both modes | `backKey`, label "Zurück" |
| `SheetCloseButton` | still Material `IconButton` (looks like a neutral regular `AppIconButton`) | `buttonKey` on the `IconButton`, 48 px target; do not wrap it |
| `IconTile(.custom)` | `IconBadge` at the nearest stage (<36 sm, ≤42 md, else lg) | `glyphSize`/`radius` still honoured if passed |
| `SettingsGroup` | `ListSection(inset: edge)`; the caps caption became a `SectionHeading` | heading level 2, same label |
| `SettingsRow` | `ListRow` with its old API and old (unmerged) semantics | `trailing` before the chevron, `titleColor` |
| `RecipeIngredientLines`, `RecipePreparationSteps`, `RecipeStepBadge`, `recipePreparationSteps()` | `BulletList`, `NumberedSteps`, `StepNumber` | same constructor |
| `DecisionConsequence(s)` | `BulletList.icons` entry | `find.byType(DecisionConsequence)` |
| `CreationAddButton` | `SoftPillButton(accent, expand, AppIcons.add)` | outer `key` |
| `OptionGlyphTile` | `IconBadge(lg, accent)` | – |

## Pitfalls

- `DecisionMedallion` acts out the sign-out glyph only for `AppIcons.logout`;
  pass that constant (not `Icons.logout_rounded`) when you migrate a sign-out
  card.
- `IconTile` sizes snap to 32/40/44: a screen test that pins 34/36/38/48 px
  changes when it is migrated; move it to `IconBadge` and test outcomes.
- Tests: `find.byIcon(AppIcons.x)`; keys stay where they were. The test
  count must not grow; a restyle needs no new test.
- `ListRow` merges its semantics. A row with an interactive `end:` widget
  merges that widget's action into the row; put a separate control into
  `below:` instead.
- `AppIconButton` shows a tooltip from `semanticLabel` on long press; with
  `onLongPress` it does not.
- `app_snack.dart` is still on the icon rule's allowlist; the snackbar round
  migrates it and drops the entry in `test/repo_rules_test.dart`.
