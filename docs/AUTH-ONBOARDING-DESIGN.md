# Authentication and onboarding

## Scope and visual direction

The September 2026 redesign covers email/password login, registration, email
verification and initial profile setup. These are task-oriented native screens:
the primary action remains clear, fields support platform input behavior, and
decoration never delays account access.

The entry surfaces use Eatova's existing Balance Duo palette, Bricolage Grotesque
headings, Archivo body text and custom icon family. Lavender/violet provides
brand emphasis, while the open layout and borderless soft-fill fields retain
the app's input/focus contract. Both themes and German/English are supported.
No global palette, dependency or nutrition-calculation change is part of this
redesign.

## Six-step setup

The previous flow could require eleven screens. The new flow groups related
questions and removes the passive introductory screen:

1. **Basics:** the personal details used by the existing energy calculation.
2. **Body:** height and current weight together.
3. **Activity:** a practical description of the usual activity level.
4. **Goal:** maintain, lose or gain; target and pace appear when applicable.
5. **Diet:** optional dietary preference, with a clear way to continue without
   choosing a restriction.
6. **Plan:** review the calculated target and edit earlier answers before
   completing setup.

Related controls remain scrollable on small screens and with enlarged text.
Back navigation preserves the draft. A summary edit returns directly to the
summary, without repeating the remaining steps. Numeric ranges come from
`ProfileLimits`, and goal consistency and energy estimates use the existing
model/calculator. Reselecting the current goal must preserve a custom target.

Completing setup does not opt into reminders or trigger a notification
permission prompt. The existing explicit reminder setting remains available.
There is no extra permissions tour, upsell or forced tutorial.

## Behavioral boundaries

- Login, signup, Google sign-in, recovery, resend and email verification retain
  their real repository operations. An exposed Apple sign-in flow is not added.
- Login accepts an existing nonempty password for server validation. New-account
  password rules remain on registration and password creation/change.
- A signup awaiting email confirmation does not unlock authenticated data.
- Credential exchanges must not let a late response replace a newer session or
  undo a sign-out. The native Google account chooser is inside that boundary.
- The profile is completed only after the final user action. The existing
  account-scoped sync/outbox path persists it; returning accounts do not repeat
  setup after a successful save.
- Legal links, sanitized errors, anti-enumeration behavior, OTP cooldowns,
  keyboard access, autofill, reduced motion and accessible control labels remain
  part of the entry contract.

## Verification and delivery

### Rendered previews

These are Flutter test frames with bundled production fonts and synthetic
profiles, not device screenshots. Content scrolls; the plan's edit rows are
shown separately from its first viewport.

| Login / signup | Profile setup |
| --- | --- |
| ![Login, light theme](auth-onboarding-preview/login-light.png) | ![Basics, light theme](auth-onboarding-preview/basics-light.png) |
| ![Signup, dark theme](auth-onboarding-preview/signup-dark.png) | ![Body details, dark theme, English](auth-onboarding-preview/body-dark-en.png) |
| ![Plan, dark theme](auth-onboarding-preview/summary-dark.png) | ![Editable answers, light theme](auth-onboarding-preview/review-light.png) |

Reproduce the complete theme/language/text-size matrix locally:

```sh
flutter test test/auth_entry_design_test.dart --dart-define=AUTH_PREVIEW_DIR=build/auth-entry-preview
flutter test test/onboarding_redesign_test.dart --dart-define=ONBOARDING_CAPTURE=review
```

### Checks and boundaries

Validation evidence and the protected PR are recorded in the dated
[project handoff](PROJECT_HANDOFF.md). The verification includes real-font
Flutter renders, focused authentication/profile regressions, a combined
signup-to-onboarding-to-returning-login test, strict analysis and the full
Flutter suite with dummy service configuration.

Passing local checks and merging the PR do not install a new application.
Physical-device Google account selection, OS keyboard/autofill and real email
delivery require their own device/provider checks. This change does not deploy
backend functions or change live authentication settings.
