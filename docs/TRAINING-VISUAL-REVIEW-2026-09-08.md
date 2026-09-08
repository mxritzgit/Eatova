# Training visual review, 2026-09-08

Independent Flutter renders inspect the Page agent's implementation with real
bundled Archivo/Bricolage fonts and Material symbols. This is widget-render
evidence, not an installed-device capture or the final integrated app shell.

Only this report, the design spec, and the ignored local fixture
`.agents/training_design_capture_test.dart` are owned by the design assignment.
The fixture is machine-local render tooling, not a proposed CI test. Training
page/editor, five domain models and
ARBs in this worktree are copied dependencies; do not integrate those copies.
Localization was regenerated locally for the renders. No sibling source was
modified. Flutter 3.47.2 was verified; dummy Supabase defines were used.

## First rendered pass

Seven fixture cases produced 15 captures: light/dark 390x844 library, exercises
and empty state; 320x568 at 2x text library/start/exercises; review, editing and
focused input with a 220-pixel keyboard inset at normal and enlarged text.
Screenshots are ignored under `build/training-design/`; first-pass evidence is
preserved in its `before/` directory.

Normal phone layouts show a coherent hierarchy: the forest plan panel, open
exercise rows, plain navigation, consistent heading/body typography and one
dominant start action. Empty state, light/dark surfaces and long exercise names
remain readable. No visual redesign is needed for those normal layouts.

| Before | Required after | Why / evidence |
| --- | --- | --- |
| At 320/2x, the page title breaks into `Trainin` and `g` beside the add button. | Give the title enough horizontal room through responsive trailing-action placement. Preserve system text size. | H9/H11: `before/library-light-320-2x.png`; `TrainingScreen` shared `ScreenTitle` invocation. |
| Fixed-width exercise number wraps `01` into two lines, similarly `02`. | Keep the number unbroken with measured/scaled width or a deliberate compact alternative. | H12/H48: `before/start-light-320-2x.png` and `before/exercises-light-320-2x.png`; `TrainingExerciseList`. |
| At 320/2x, review and editor headers split inside words; keyboard leaves the focused title only about 20 pixels visible. | Use a responsive compact or scrolling header; focused field must remain readable above the footer and keyboard. | H9/H41: `before/review-light-2.0x.png`, `before/editor-keyboard-light-2.0x.png`; editor header and fixed footer. |
| Review-to-edit keeps the review scroll offset and opens in the middle of the form. | Reset editor scroll position so plan title is the first editing context. | H48/H50: `before/editor-light-1.0x.png`, `before/editor-light-2.0x.png`; `training-editor-edit` callback. |
| Selected workout's checkmark is near-white on lime in dark mode. | Set the checkmark's on-fill color explicitly, or use the existing selected-fill/on-selected pair. | H15/H16: `before/library-dark-390.png`; `ChoiceChip`. |

All findings were sent directly to the Page agent and root with exact screenshots
and changes to make. The initial fixture used the wrong title key; correcting
that fixture is not an app fix. A later tap after setting keyboard insets hit
the Save footer instead of the obscured input, demonstrating why absence of an
overflow exception does not establish usability. The final reproducer focuses
the title before introducing the inset and verifies hitability first.

## Verification status

The Page agent implemented all five fixes and added five actual-font geometry
regressions. Independent recopy and re-render repeated all seven capture cases
and refreshed all 15 images. Inspection closes every finding above: the Training
heading and ordinals stay intact, dark selection check is visible, editing opens
at the plan title, and the compact keyboard toolbar leaves the focused title
fully readable above Save at 320x568 with 2x text and a 220-pixel keyboard inset.
The shortened review heading wraps between words. Normal light/dark layouts
remain coherent; no new Page findings appeared.

Latest captures are directly under `build/training-design/`; compare with
`before/` for the original failures. All seven fixture cases pass. Final
shell/navigation, player states and actual device behavior are separate from
this Page-only pass. Coach visual verification follows separately below.

## Coach proposal, command menu and review

Four additional actual-font captures exercise German/English, normal 390x844
light and 320x568 at 2x text in dark mode. The fixture uses the real
`CoachChatScreen` with a stubbed `CoachChatService` history containing a typed plan
draft; every HTTP call is mocked. Geometry mirrors the app shell: five-item
`AppNavBar`, safe areas, 20 horizontal / 12 vertical padding. This is more
constrained than rendering Coach alone. Additional dependency copies are the
five changed Coach files, client service and chat-message model, plus their ARBs.

Normal phone captures show readable draft provenance, title/summary/counts, one
review action, both command suggestions and the explicit adoption sheet. The
large-text review is readable and scrollable with the corrected Page heading.

| Before | Required after | Why / evidence |
| --- | --- | --- |
| At 320x568/2x with the shell and a 220-pixel keyboard inset, the German command menu is only 18 pixels high including its 8-pixel margin. No command is readable or tappable. | Compact the header while available height is constrained, preserving title/info/sessions; make command rows concise enough to expose usable targets. | H20/H39/H41: `coach-before/coach-de-320-2x-dark-command-keyboard.png`; `coach-keyboard-red.log` fails expected menu height >=48, actual18. |

The English equivalent left one command title visible, but the second was
hidden below scroll. Absence of a RenderFlex error did not detect the failure;
the independent fixture checks usable command-menu geometry. Root and the Coach
UI agent received the capture, exact shell geometry and red proof.

The Coach agent reproduced the same 18-pixel German and 51-pixel English result,
then implemented a compact header for constrained available height and compact
command rows for short menus. A final independent recopy of `coach_chat_screen`,
`coach_top_bar` and `coach_recipe` repeated all four Coach capture cases with
the original geometry assertion. All four pass, recorded in
`build/training-design/coach-keyboard-green.log`.

Actual image inspection confirms that both `/recipe` and `/plan` are now fully
visible together above the composer with the keyboard open, in both locales.
The compact header retains Coach, information and conversations controls. Without
the keyboard the full header returns; ordinary 390-pixel captures retain the
original complete command descriptions and unchanged draft-card hierarchy.
The corrected review sheet remains readable. No new visual findings appeared.

All six findings from this bounded visual review are closed on the refreshed
agent snapshots. Eleven fixture cases generated 41 reference captures across the
Page and Coach flows; the critical normal and before/after states were visually
inspected. The final integrated shell/player, live AI
generation and device installation remain root-owned verification steps; these
renders do not establish their status.

## Final bounded validation-feedback check

The Coach owner found a related constrained-height issue after selecting the
bare `/plan ` command and pressing Send: its fixed validation feedback could
displace the composer. The final implementation bounds this feedback inside the
conversation area and keeps it scrollable. The design worktree recopied the
owner's final three Coach files and repeated the same actual-shell fixture.

Both German and English now pass the bare-command sequence at 320x568, 2x text
and a 220-pixel keyboard inset. Independent assertions verify that the entire
localized feedback exists, its viewport is hit-testable, scrolling reaches its
maximum extent, and input, information and conversations remain hit-testable.
All four Coach fixture cases pass in `coach-feedback-green.log`. Actual start/end
captures (`coach-*-validation-keyboard.png` and
`coach-*-validation-end-keyboard.png`) confirm that the whole instruction can be
read by scrolling while the composer stays visible. No new visual defects were
found in this bounded final check.

Final reviewed Coach source SHA-256 values (under `lib/src/screens/coach/`):

| File | SHA-256 |
| --- | --- |
| `coach_chat_screen.dart` | `75873A0DC7ED88D5B08027C60321370637A4D5D5EB803EEE22D11B8DCE13A097` |
| `coach_top_bar.dart` | `2F29E9ACED89648E7FECA6A83AB0BC3CD5B81DFE8E9F1115BEFC4C3DFC94B5A4` |
| `coach_recipe.dart` | `ACA825876C1B0305A998A578A31CEB7EF8B5D78EC9E37687BC37C90876970447` |

The broader Page/Coach hash manifest is
`build/training-design/reviewed-source-hashes.json`. These hashes describe the
reviewed dependency snapshots, not a commit or device build.

## Integrated logic follow-up

Root subsequently integrated a Training-only conversation-remap correction in
`coach_chat_screen.dart` (SHA-256
`39C57D7B54F4CB51927E600C7C5DAEA0522A8B6607CA082A8C3FE08211D62EAE`).
It preserves an explicitly adoptable buffered draft when assistant history is
unavailable, avoids duplicate assistant IDs, and rejects late account or
conversation results. It does not change the rendered layout reviewed above.
Eight additional behavioral cases and the existing compact-keyboard tests pass;
an independent bounded review found no remaining issue in this helper. See
`PROJECT_HANDOFF.md` for final integrated verification and delivery status.
