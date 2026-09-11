# Keyboard and gesture navigation

The Coach composer must never require sending a message to leave the keyboard
or the tab. The same input behavior applies to pages, dialogs and sheets across
Eatova, while existing unsaved-work and in-progress-save guards remain in force.

## Interaction contract

- Releasing a touch outside an input dismisses its keyboard. Waiting for release
  keeps actions under the finger until their tap completes. Moving directly to
  another field preserves the newly acquired focus.
- Dragging a scroll view dismisses the keyboard. Switching tabs releases focus,
  including programmatic tab changes; mounted tabs retain their local drafts.
- Ordinary iOS pushed pages retain Cupertino's interactive edge-back transition.
  Where a root tab or `PopScope` disables that gesture, a narrow leading-edge
  pull reaches the existing exit policy through `Navigator.maybePop`. With the
  keyboard open, the first pull only dismisses it. A subsequent pull from a
  secondary root tab returns to Today.
- Android keeps the framework's native back and predictive-back transitions.
  No full-screen horizontal recognizer competes with lists or carousels.
- The training editor has a visible sheet handle and accepts a downward pull or
  backdrop tap. Unsaved changes still require the existing discard decision;
  an active save cannot be dismissed. The guard owns the drag from pointer-down
  so edits or saves begun during that drag cannot bypass the current policy.
- Guarded pulls have restrained finger-following feedback and a short reset.
  Reduced-motion settings disable that displacement. Pointer cancellation,
  reverse flings and short pulls do not exit. A delayed completion cannot pop a
  newly covering dialog or steal focus from another field.

The implementation is shared in `AppInteractions`, the iOS page transition
builder and `SheetDismissGuard`. It does not submit messages, save forms or
change the data/service architecture as a side effect of navigation.

## Verification, 2026-09-12

Verified with the repository-pinned Flutter 3.47.2 / Dart 3.13.2:

- All **4,358** Flutter tests pass without skips; coverage is **95.12%**
  (25,357 of 26,657 lines, excluding generated localization).
- Fourteen new interaction regressions cover empty Coach chats on iOS/Android,
  multiline drafts, action taps, focus transfer, native and guarded iOS edges,
  root-tab navigation, sheet dismissal and dirty/busy races.
- Before-fix and targeted mutation runs demonstrate failures for keyboard traps,
  canceled/reversed gestures, changed focus and changes begun during a drag.
- Strict analysis passes with warnings and infos fatal; the normal Android
  debug APK builds with dummy runtime defines.
- Independent general and security reviews identified cancellation, velocity,
  focus and sheet-state races. These were fixed and the final review was clean.

Real Android keyboard verification was attempted using an offline fixture. The
local emulator repeatedly terminated, including a System UI not responding
dialog, so this is **not** a passed native-device check. The iOS behavior was
exercised through Flutter's iOS platform variant and actual route widgets; a
physical iPhone check remains outstanding. Widget tests do not establish
physical-device frame pacing or native keyboard animation quality.
The emulator's original APK was restored and verified by SHA-256; no app data
was cleared.

Framework references: [keyboard dismissal behavior](https://api.flutter.dev/flutter/widgets/ScrollViewKeyboardDismissBehavior.html)
and [Android predictive back](https://docs.flutter.dev/release/breaking-changes/android-predictive-back).

## Delivery boundary

The topic branch is `fix/gesture-navigation`, based on main `198b74b` (PR #80).
The user authorized pushing and merging through a PR after green CI. The PR is
the source of delivery status. This is a client-only change: no migration,
backend deployment or new dependency is required. A new installed app build is
needed for a device to receive it.
