-- Enable pg_cron and schedule room cleanup every 15 minutes
create extension if not exists pg_cron with schema pg_catalog;

grant usage on schema cron to postgres;
grant all privileges on all tables in schema cron to postgres;

select cron.schedule(
  'cleanup-expired-impostor-rooms',
  '*/15 * * * *',
  $$select public.cleanup_expired_rooms();$$
);
