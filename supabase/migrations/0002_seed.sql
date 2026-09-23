-- Optional: a couple of topics so you can watch the pipeline move end to end.
insert into topics (raw_topic, source) values
  ('Why most people quit the gym in February', 'seed'),
  ('The hidden cost of buying a cheap laptop',  'seed')
on conflict do nothing;

-- Handy during the build:
--   select * from pipeline_status;
--   update jobs set status = 'idea_ready', attempts = 0 where id = '...';  -- replay a job
--   update topics set status = 'new' where source = 'seed';                -- replay ideation
