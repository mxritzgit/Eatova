-- /rezept-Vorschlaege ueberleben den Reload (Nachtrag zur Spec 2026-08-12).
--
-- Die Assistant-Zeile eines Rezept-Vorschlags traegt ab jetzt das (bereits
-- serverseitig geklemmte, s. coach-chat/recipe.ts RECIPE_LIMITS) Rezept-JSON
-- — der Client baut daraus nach einem Reload die Vorschlagskarte wieder auf.
-- NULL fuer alle anderen Zeilen; Bild-BYTES bleiben wie bei User-Fotos
-- draussen (geraetelokal, RecipeImageStore).
--
-- Geschrieben wird die Spalte ausschliesslich aus der Edge Function
-- (service_role) — der Client hat auf chat_messages weiterhin keine
-- INSERT/UPDATE-Policy. Der Groessen-Check spiegelt den content-Check aus
-- 20260811130000: die Function klemmt jedes Textfeld (<= 2000 Zeichen),
-- der Check ist Guertel + Hosentraeger gegen kuenftige Schreiber.
alter table public.chat_messages
  add column if not exists recipe jsonb;

alter table public.chat_messages
  drop constraint if exists chat_messages_recipe_size;
alter table public.chat_messages
  add constraint chat_messages_recipe_size
  check (recipe is null or pg_column_size(recipe) <= 16384);
