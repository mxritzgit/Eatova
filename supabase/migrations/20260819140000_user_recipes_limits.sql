-- Eatova — Groessen- und Wertegrenzen fuer public.user_recipes und
-- public.chat_sessions.title (Komplettreview 2026-08-19, Fund "niedrig").
--
-- BEFUND / WARUM DIESE TABELLE DIE LINIE VERPASST HAT
--
-- 20260517220000_security_hardening.sql hat jede damals existierende
-- client-beschreibbare Tabelle mit einem `<tabelle>_safe_ranges_check`
-- versehen (profiles, daily_logs, logged_meals, favorite_meals, weight_log,
-- caffeine_entries, lifetime_stats). `user_recipes` entstand 13 Tage SPAETER
-- (20260530091000_user_recipes.sql) und ist deshalb nie in diesen Block
-- gewandert: sie traegt bis heute nur die fuenf Spalten-Checks `>= 0` und
-- KEINE einzige Laengen- oder Obergrenze. Faktische Grenze sind der
-- `integer`-Typ (2 147 483 647) und bei den sechs `text`-Spalten gar nichts.
-- `chat_sessions.title` (20260517170000, drei Tage NACH der Haertung
-- geschrieben, aber im selben Fenster uebersehen) ist der zweite Fall.
--
-- Auswirkung: kein Datenleck — RLS haelt, ein Nutzer erreicht nur eigene
-- Zeilen. Es ist ein Kosten- und Verfuegbarkeitshebel: ein manipulierter
-- Client (die App selbst tut das nie, s.u.) kann pro Zeile beliebig grosse
-- Texte und absurde Naehrwerte schreiben, und `UserRecipesSync.load` liest
-- sie beim Start wieder komplett zurueck.
--
-- GRENZENWAHL — bewusst GROSSZUEGIG
--
-- Eine Grenze, die legitime Nutzerdaten abweist, waere schlimmer als keine.
-- Deshalb liegt jede Zahl hier weit ueber dem, was die beiden Schreibpfade
-- real erzeugen koennen:
--
--   Spalte         | real geschrieben                        | Grenze hier
--   ---------------+-----------------------------------------+------------
--   slug           | 'user_<13 Ziffern>' / 'user_coach_<id>' |   200
--   title          | 160 (maxLength im Sheet, titleMaxChars) |   300
--   description    | 600 (RECIPE_LIMITS.descriptionMaxChars) |  4 000
--   portion        | 200 (portionMaxChars); Sheet-Feld frei   |  1 000
--   ingredients    | 2 000 (longTextMaxChars); Feld frei      | 20 000
--   preparation    | 2 000 (longTextMaxChars); Sheet: ''      | 20 000
--   image_asset    | 'local:img_<hex>.jpg' (~40)             |  2 048
--   calories_kcal  | 1..10 000 (Sheet lehnt ab, Coach klemmt) | 10 000
--   protein/carbs/ | 0..1 000                                 |  1 000
--   fat_g          |                                          |
--   estimated_g    | 0..10 000                                | 10 000
--   categories     | genau ['Eigene']                         | 32 Eintraege
--
-- Die Zahlenbereiche sind identisch zu `logged_meals_safe_ranges_check` —
-- Rezepte werden ohnehin ueber `FitnessRecipe.toMealResult` in eine Mahlzeit
-- konvertiert und muessen dort durch dieselben Grenzen. Die Textgrenzen sind
-- gegenueber logged_meals absichtlich weiter: `ingredients`/`preparation`
-- sind mehrzeilige Freitextfelder, keine Etiketten.
--
-- `chat_sessions.title`: der Auto-Titel der Edge Function kappt bei 40
-- Zeichen + Ellipse (handler.ts), der Client legt Sessions immer mit dem
-- ARB-Default an, und ein Umbenennen-UI gibt es nicht. 500 ist damit rund das
-- Zwoelffache des laengsten legitimen Titels.
--
-- WARUM `not valid`
--
-- ADD CONSTRAINT validiert sonst den kompletten Bestand und schlaegt fehl,
-- sobald EINE Altzeile die Grenze reisst — auf der Produktivdatenbank waere
-- die Migration damit nicht wiederholbar deploybar. `not valid` prueft nur
-- kuenftige INSERTs und UPDATEs; genau das ist der Schutz, um den es geht.
-- Wer den Bestand nachziehen will, macht das getrennt und beobachtet:
--   alter table public.user_recipes  validate constraint user_recipes_safe_ranges_check;
--   alter table public.chat_sessions validate constraint chat_sessions_safe_ranges_check;
--
-- Idempotent ueber die `pg_constraint`-Probe wie im Vorbild
-- (20260517220000_security_hardening.sql, Abschnitt 3).

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'user_recipes_safe_ranges_check') then
    alter table public.user_recipes add constraint user_recipes_safe_ranges_check
      check (
        char_length(slug) between 1 and 200 and
        char_length(title) between 1 and 300 and
        char_length(description) <= 4000 and
        char_length(portion) <= 1000 and
        char_length(ingredients) <= 20000 and
        char_length(preparation) <= 20000 and
        char_length(image_asset) <= 2048 and
        calories_kcal between 0 and 10000 and
        protein_g between 0 and 1000 and
        carbs_g between 0 and 1000 and
        fat_g between 0 and 1000 and
        estimated_g between 0 and 10000 and
        -- cardinality allein liesse die EINZELNE Kategorie unbegrenzt (ein
        -- Eintrag mit 100 MB waere weiter erlaubt); die zweite Zeile deckelt
        -- deshalb die Gesamtlaenge des Arrays.
        cardinality(categories) <= 32 and
        char_length(array_to_string(categories, ',')) <= 2000
      ) not valid;
  end if;

  if not exists (select 1 from pg_constraint where conname = 'chat_sessions_safe_ranges_check') then
    alter table public.chat_sessions add constraint chat_sessions_safe_ranges_check
      check (char_length(title) between 1 and 500) not valid;
  end if;
end $$;
