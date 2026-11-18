-- Re-applied by deploy.sh after every migration run, as the postgres superuser against database `stexx`:
--   ssh host 'sudo -u postgres psql -v ON_ERROR_STOP=1 -d stexx' < grants.sql
-- Explicit GRANTs (not default privileges) so a new table is never silently writable or invisible.

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO stexx_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO stexx_app;

-- The running service must not be able to rewrite its own migration history.
REVOKE ALL ON TABLE schema_migrations FROM stexx_app;

-- dev_bots is only meaningful in dev; production never writes it.
REVOKE INSERT, UPDATE, DELETE ON TABLE dev_bots FROM stexx_app;

-- Functions are executable by PUBLIC by default; make that explicit and keep them out of reach of other roles.
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO stexx_app;
