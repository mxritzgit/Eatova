# Training design, 2026-09-08

Design specification for the Training tab, Coach `/plan` draft flow and workout
player. Implementation is coordinated in the ignored training worktrees; this
document records direction, not completion or live deployment.

## Design source and intent

The feature belongs to Eatova's existing native Flutter interface. Style comes
from `lib/src/theme/app_tokens.dart`, `docs/DESIGN_REFACTOR.md`, and the shared
design widgets. `docs/design.md` is absent. Craft uses the `design-better` and
`emil-design-eng` skills: one dominant task, visible feedback, easy reversal,
honest draft states, readable numbers, and restrained motion.

The visual signature is a forest workout panel, generous cream/dark page ground,
large tabular exercise timing, and simple open exercise rows. No decorative AI
stars, nutrient colors, invented progress statistics, stock fitness photos, or
multi-level card nesting. A contextual dumbbell is enough to identify Training.

| Element | Existing source |
| --- | --- |
| Page background / panels / separators | `t.bg`, `t.surf`, `t.surf2`, `t.line` |
| Main / secondary text | `t.ink`, `t.ink2` |
| Workout hero | `t.forest`, `t.onForest`, `rHero` |
| Graphic emphasis on ordinary surfaces | `t.accent` |
| Hero action or active nav accent | `t.lime`, `t.onLime` |
| Standard primary button | `PrimaryActionButton`: `t.ink` / `t.bg`, `rButton`, minimum 54 |
| Selected workout/day | `SelectionTone.selectedFill` / `onSelected` |
| Draft/editor inputs | `SheetField` / `FieldCapsule`, including focus and error fills |
| Page / section heading | `ScreenTitle` / `SectionHeading` with heading semantics |
| Titles and timing | `AppType.display`; bundled Bricolage, tabular figures |
| Instructions and controls | `AppType.ui`; bundled Archivo |
| Structural shape | `rControl`, `rCard`, `rSheet`; no new radius scale |

Spacing follows existing screen practice: 20 side gutters, 20-24 between major
sections, 12-16 panel padding, 8 between related controls, and 4-6 between a title
and its metadata. These are existing conventions, not new global tokens.

Use 30 for the shared page heading, 24-26 for plan/workout headings, 17-20 for
section/exercise headings, 14-15 for body and primary metadata, 12-13 for
secondary metadata. Eyebrows identify sections only; do not turn all metadata
into tiny letter-spaced uppercase text. Timer uses the display family at a
deliberately prominent size, with room to reflow when text is enlarged.

## Tab and plan library

Recommend five persistent tabs: Today, Food, Recipes, Training, Coach. Preserve
the existing nav bar and complete semantic labels; Training uses a contextual
fitness-center symbol. Existing historical four-tab guidance is superseded by
the current explicit request for a new tab. The player opens as a full-screen
route so the high-frequency controls do not compete with app navigation.

Screen hierarchy:

1. `ScreenTitle`: Training, one short explanatory subtitle, secondary add/menu
   action with a complete semantic label.
2. If a session exists, an obvious resumable workout entry with exercise name
   and paused state; its resume action has primary priority.
3. Active plan forest panel: plan name, optional description, wrapping day and
   exercise counts. Name the selected workout; never imply it is scheduled for
   today when the model contains no calendar schedule.
4. Workout/day selector with clear selected fill, text and selection semantics.
5. Selected workout name and estimated duration only if computed from actual
   plan data. Numbered exercise rows expose name, sets and repetitions OR timed
   duration, and rest. Use a calm divider rhythm rather than miniature cards.
6. One primary start action. Place the shared primary button outside the forest
   panel, or use a deliberate lime/onLime button inside it so its edges remain
   visible. Saved-plan switching/editing remain secondary actions.

Empty state: forest panel with a compact contextual symbol, "Dein Plan. Dein
Rhythmus.", and a short explanation. Primary "Mit Coach planen" opens Coach and
fills `/plan `, without sending. Secondary "Plan selbst erstellen" opens the
editor. Do not preload fabricated activity or silently adopt a sample plan.

Loading uses layout-matched neutral placeholders or the existing loading
pattern. Cached plans remain usable during sync. A failure shows readable
localized recovery text and Retry; it must not replace cached content with a
blank/error screen. Save-in-progress and offline-pending states must be truthful
about whether local persistence succeeded.

## Coach proposal and adoption

`/plan` is a sibling of `/recipe`, with a fitness-center icon and concise command
description. Commands remain unchanged across locales; explanations translate.
Tapping a suggestion completes a draft and never sends it immediately.

Proposal card hierarchy: draft label, plan title, short summary, wrapping day /
exercise counts, then "Plan prüfen". No image placeholder for a feature that
does not generate images. No saved/check marker before explicit acceptance.

Review opens a scrollable full-plan preview with every workout and prescription.
"Bearbeiten" preserves the draft, and the final primary action is
"Trainingsplan übernehmen". Cancel, Back and sheet dismissal do not mutate saved
plans. Validation errors attach to fields; saving disables duplicate submission.
After acceptance, the proposal clearly reads "Übernommen" and offers a route to
Training. If Undo is present, its state follows the actual stored plan, not only
a transient widget flag.

Manual creation and AI review use the same plan editor: plan title and optional
description, then workout sections, then exercises. Uncommon details such as
notes can be progressively disclosed. Numeric prescriptions have visible labels
and numeric keyboards. The choice between repetitions and duration is explicit;
switching does not leave contradictory hidden values. Adding/removing/reordering
items has a tap alternative. Keep unsaved edits when returning from a subsection;
confirm only a genuine destructive dismissal.

## Workout player

The screen's job is one exercise at a time. Its hierarchy is: compact Back and
workout progress header, workout/exercise context, prominent time or repetition
prescription, visible status, primary action, adjustment controls, then the next
exercise preview. Exercise instructions remain available in the same scrollable
route, above a safe-area-aware control area where space permits.

| State | Main readout | Primary action | Supporting controls |
| --- | --- | --- | --- |
| Ready, timed exercise | Duration and set X of Y | Start | Previous / next, reset |
| Running | Remaining time, explicit running state | Pause | Rewind 10 s / forward 10 s, reset, previous / next |
| Paused | Frozen time and "Pausiert" | Resume | Same adjustments; adjusting must not resume |
| Repetition exercise | Repetitions and set X of Y | Complete set | Previous / next, instructions |
| Rest | Remaining rest and "Satzpause" | Pause / Resume | Skip rest, rewind / forward, reset |
| Finished | Honest completion summary | Finish workout | Return to plan |

Rewind means undo elapsed time (increase remaining by ten seconds); forward means
consume elapsed time. Icon-only interpretation is ambiguous, so controls need
visible short labels where possible and unambiguous localized semantic labels.
Reset restores the current phase; Previous moves to the previous actual exercise
or set according to the controller contract, never just changes an index while
the old timer runs. Announce the destination when a phase changes. Do not mark
skipped exercises as performed in history.

Pause/resume is the visually dominant, largest target. Next/previous and timer
adjustments stay visible; do not hide requested core controls behind a menu or
swipe. Avoid placing destructive cancellation beside frequently tapped timer
adjustments. Back offers an explicit way to pause and leave or continue; discarding
requires a distinct destructive confirmation. Persisted resume is paused so the
user regains control after interruption. Backgrounding must not leave a timer
silently creating phantom completed sets.

A thin linear/ring progress indicator may reinforce time; digits are the source
of truth. No pulse on every second, rotating ornamental rings or decorative
confetti. Timers update instantly. Phase/context changes can use the existing
`motionDuration` helper with a short ease-out fade. Reduced motion keeps all
status feedback and removes nonessential transitions.

## Responsive and accessibility gate

At 320 logical pixels and 2x system text, labels wrap and rows stack instead of
shrinking text. Avoid fixed content heights, `FittedBox`, two-line truncation on
required instructions, and putting all player controls in one rigid row. Use
measured constraints or `Wrap`; controls remain at least 48 high, shared icon
controls at least 44. Five nav items can keep existing truncated visual labels
at large scales only because their complete semantic labels remain available.

Editor and preview content scroll above keyboard and safe areas. A bottom action
must never obscure the focused field. Every icon button has a localized label;
selected workout has selected semantics; page and group headings are structured.
Timer semantics should announce phase transitions and status, not flood the
screen reader every second. Remaining time stays manually discoverable. Pair
state colors with text/icons and keep `ink2` on supported surfaces.

## Independent rendered review plan

Use real bundled fonts and Material symbols with stubbed plan data. Capture and
inspect: empty page; two-day active plan; long-name exercise; Coach draft and
confirmation; running/paused/rest player; manual editor with keyboard. Cover
German/English, light/dark, normal 393x852 and 320x568 at 2x text. Tests should
assert functional visibility/geometry, not only absence of an overflow exception.

Exercise pause/resume, rewind/forward/reset, previous/next, cancel/resume, complete,
double adoption, dismissal and offline/error recovery. Root performs integration
verification separately. Any reviewed source is a snapshot; final captures must
match the integrated implementation before claiming design verification.
