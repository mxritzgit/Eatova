\set ON_ERROR_STOP on
-- Reserved synthetic identities only; no runtime or production input.
insert into auth.users (id, email, raw_user_meta_data) values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'restore-a@example.test', '{"display_name":"Restore A"}'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'restore-b@example.test', '{"display_name":"Restore B"}');
insert into public.logged_meals
  (user_id, meal_name, calories_kcal, estimated_g, payload, local_day) values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'Synthetic A', 400, 200, '{}', '2026-01-01'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'Synthetic B', 500, 250, '{}', '2026-01-01');
