-- =============================================================================
-- Reference text: the source material a video is built from.
-- The client pastes it on the dashboard; workflow 01 copies it onto every job
-- made from the topic, and workflow 02 writes the script from it. Voice and
-- images follow the script, so they follow the reference too.
-- Safe to re-run.
-- =============================================================================

alter table topics add column if not exists reference text;
alter table jobs   add column if not exists reference text;
