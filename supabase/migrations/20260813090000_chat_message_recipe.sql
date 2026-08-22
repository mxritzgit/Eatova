-- Recipe proposals survive a reload: the assistant row now carries the
-- server-clamped recipe JSON (coach-chat/recipe.ts RECIPE_LIMITS), NULL on
-- every other row. Image bytes stay out (device-local, RecipeImageStore).
--
-- Written only from the edge function (service_role); the client still has no
-- INSERT/UPDATE policy on chat_messages. The size check mirrors the content
-- check from 20260811130000 as a belt-and-braces guard for future writers.
alter table public.chat_messages
  add column if not exists recipe jsonb;

alter table public.chat_messages
  drop constraint if exists chat_messages_recipe_size;
alter table public.chat_messages
  add constraint chat_messages_recipe_size
  check (recipe is null or pg_column_size(recipe) <= 16384);
