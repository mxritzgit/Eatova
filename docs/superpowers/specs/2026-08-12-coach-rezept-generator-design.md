# Coach-Rezept-Generator (`/rezept`) — Design

Stand: 2026-08-12 · Status: vom Nutzer freigegeben

## Ziel

Der Nutzer tippt im Coach-Tab `/rezept <Wunsch>` (z. B. `/rezept Erstelle mir
einen Hühnchenauflauf mit passendem Bild`). Die App generiert daraus ein
komplettes Rezept (Titel, Beschreibung, Portion, Zutaten, Zubereitung, Makros)
plus ein KI-Foto, zeigt beides als Vorschlagskarte im Chat und bietet
„Rezept hinzufügen" an. Erst nach expliziter Bestätigung im Overlay landet das
Rezept als Eigen-Rezept im Rezepte-Tab.

**Sicherheits-Grundsatz (Nutzer-Anforderung):** Der Coach erhält KEINERLEI
Handlungsrechte. Die Edge Function liefert ausschließlich Daten zurück — kein
Tool-Calling, kein Schreibzugriff auf Rezepte/Statistiken/Account. Jede
Aktion läuft clientseitig über bestehende, nutzerbestätigte Pfade.

## Entscheidungen (mit Nutzer geklärt)

* **Quota:** Eine `/rezept`-Anfrage verbraucht 1 der 5 täglichen Coach-Slots
  (bestehender atomarer Claim + Refund-Pfade). Kein separates Limit.
* **Bilder bleiben lokal:** wie bei manuellen Rezept-Fotos (RecipeImageStore,
  `local:`-Referenz). Kein Storage-Bucket in diesem Feature; Bild-Sync über
  Geräte ist bewusst out of scope.

## Architektur / Datenfluss

```
Composer (/rezept …)
  → coach-chat Edge Function, mode: "recipe"   (Auth, Rate-Limits, Quota wie bisher)
      1) grok-4.3, response_format json_object  → Rezept-JSON (App-Sprache)
      2) OpenRouter Image API (POST /api/v1/images) → JPEG base64
      3) Verlauf: User-Message + Text-Zusammenfassung (KEIN Bild in der Historie)
  ← { recipe, image_base64?, image_mime_type?, remaining, daily_limit, session_id }
Chat: Vorschlagskarte (ephemer, nur laufende Session)
  → Tap „Rezept hinzufügen" → Bestätigungs-Sheet (Vorschau komplett)
      → Tap „Hinzufügen":
          RecipeImageStore.save(bytes) → 'local:<name>.jpg'
          FitnessRecipe(userCreated: true, categories: ['Eigene'], …)
          HomeStore.createUserRecipe(...)   (LocalCache + Outbox + Supabase, bestehend)
```

## Edge Function (coach-chat, neuer Zweig `mode: "recipe"`)

* Request neu: `mode?: 'recipe'`, `locale?: 'de'|'en'` (Default de); `message`
  = der Wunschtext OHNE Präfix. Session-/Auth-/Rate-Limit-/Quota-Mechanik
  unverändert; der Classifier-Call entfällt (eigener Scope im Prompt),
  Layer-1-Prefilter läuft weiter.
* Rezept-Call: `COACH_MODEL_ANSWER` (grok-4.3), `response_format:
  {type:'json_object'}`, niedrige Temperatur. System-Prompt: genau EIN Rezept
  als JSON `{title, description, portion, ingredients, preparation,
  calories_kcal, protein_g, carbs_g, fat_g, estimated_g}`; `ingredients` als
  "\n- "-Liste, `preparation` als "\n1. "-Liste (Format der bestehenden
  Freitext-Felder); Sprache = `locale`. Kein Essensrezept → Refusal-Marker
  wie bisher.
* Serverseitige KLEMMEN (Spiegel der Client-Grenzen aus dem manuellen
  Formular / LoggedMealLimits): kcal 1..10000, Gramm 1..10000, Makros
  0..1000, Titel ≤160 Zeichen; Textfelder gekappt (description ≤600,
  ingredients/preparation ≤2000). Anders als beim manuellen Formular wird
  geklemmt statt abgelehnt: Ablehnen ist die Regel für Menschen-Eingaben,
  ein abgelehnter KI-Request wäre ein bezahlter Slot ohne Ergebnis.
  Unlesbares JSON (kein Titel/keine kcal) → 502 + Quota-Refund
  (bestehendes Infra-Fehler-Muster).
* Bild-Call: `POST https://openrouter.ai/api/v1/images`, Modell
  `COACH_IMAGE_MODEL` (Env, Default `google/gemini-3.1-flash-image`),
  `aspect_ratio: '4:3'`, `output_format: 'jpeg'`, `resolution: '1K'`, n=1,
  Food-Fotografie-Prompt aus Titel + Beschreibung. Timeout eigenes Budget
  (~30 s). **Bild-Fehler ≠ Rezept-Fehler:** schlägt nur das Bild fehl, kommt
  das Rezept ohne `image_base64` zurück (Karte zeigt Platzhalter).
* Verlauf (`chat_messages`, service_role wie bisher): User-Zeile = Original-
  eingabe inkl. Präfix; Assistant-Zeile = kurze Text-Zusammenfassung in
  App-Sprache. Bild-Bytes werden nie persistiert.
* Response: `{ recipe: {…}, image_base64?, image_mime_type?, remaining?,
  daily_limit, session_id }`. Fehlerfälle wie bisher (429 quota_exceeded,
  Refusal-Format).

## Client

* **Präfix-Erkennung** in `_send` (coach_chat_screen.dart): `/rezept ` oder
  `/recipe ` (case-insensitive, beide in beiden Sprachen akzeptiert). Leerer
  Rest → Hinweistext statt Request.
* **Service:** `CoachChatService.requestRecipe(...)` → `CoachRecipeReply`
  (recipe: `CoachRecipeProposal`, imageBytes?: Uint8List). Fehler-Mapping wie
  `send()` (401/429/413/5xx).
* **ChatMessage:** neues optionales, NUR lokales Feld `recipeProposal`
  (Proposal + Bild-Bytes). Wird wie `imageBytes` nie aus `fromRow` befüllt —
  nach Reload/Session-Wechsel bleibt die Text-Zusammenfassung aus dem Verlauf.
* **Vorschlagskarte** (`_MessageView`-Zweig): Bild (160 px, oder
  ImagePlaceholder), Titel, kcal/Protein-Zeile, PrimaryActionButton
  „Rezept hinzufügen". Karte bleibt stehen; ignorieren = keine Aktion.
* **Bestätigungs-Sheet** („Rezept hinzufügen"): Bild, Titel, Makro-Grid,
  Portion, Zutaten, Zubereitung, Buttons Hinzufügen/Abbrechen. Bei
  Hinzufügen: RecipeImageStore.save → FitnessRecipe → `onCreateRecipe`
  (neuer Callback am Coach-Screen, verdrahtet auf
  `HomeStore.createUserRecipe`) → Erfolgs-Snack, Button auf der Karte wird
  „Hinzugefügt" (deaktiviert, kein Doppel-Add).
* **i18n:** neue ARB-Keys de+en (Kartenlabels, Sheet-Titel/Buttons,
  Fehler-/Hinweistexte). Kein hartkodierter deutscher Text in
  `lib/src/screens/coach/` (Wächter-Test).

## Fehlerfälle

| Fall | Verhalten |
|---|---|
| Quota aufgebraucht | bestehende 429-Behandlung (`CoachQuotaExceeded`) |
| Rezept-JSON unlesbar | 502, Quota-Refund, Fehlermeldung im Chat |
| Bild schlägt fehl | Rezept ohne Bild, Karte mit Platzhalter |
| `/rezept` ohne Text | lokaler Hinweis, kein Request, kein Slot |
| Offline | bestehende Fehlerpfade des Service |
| RecipeImageStore.save schlägt fehl | Rezept ohne Bild speichern + bestehender `recipesPhotoSaveFailedError`-Hinweis |

## Tests

* **Deno (coach-chat):** Recipe-Mode happy path; Klemmen (kcal 50000 → 10000
  abgelehnt/geklemmt gemäß Formular-Regel: ablehnen), Bild-Fehler tolerant;
  Refund bei Provider-Fehler; Refusal bei Nicht-Essens-Wunsch; Prefilter
  aktiv.
* **Flutter:** Präfix-Erkennung (beide Präfixe, ohne Text); Karte rendert
  (mit/ohne Bild); Sheet → `onCreateRecipe` mit erwartetem FitnessRecipe
  (slug user_*, userCreated, Kategorien); Doppel-Add gesperrt; ARB-Parität;
  EN-Render-Smoke; Hartkodierungs-Wächter bleibt grün.

## Out of Scope

* Bild-Sync über Geräte (Storage-Bucket) — späteres eigenes Feature.
* Rezept-Bearbeiten vor dem Speichern.
* Auto-Erkennung von Rezeptwünschen ohne `/rezept`.
* Discoverability-UI für den Befehl (kann später ins (i)-Sheet).
