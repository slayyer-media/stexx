-- One-time role + database setup. Run as the postgres superuser (peer auth):
--   sudo -u postgres env STEXX_APP_PW=... STEXX_OWNER_PW=... psql -v ON_ERROR_STOP=1 -f roles.sql
-- Re-running is safe: it re-applies passwords and limits, never drops anything.
--
--   stexx_owner   owns the schema; used ONLY by migrations (deploy.sh). Not used by the running service.
--   stexx_app     what the API connects as: DML on application tables, nothing else.
--   stexxbackup   read-only (pg_read_all_data) for pg_dump; peer auth as the OS user of the same name.

-- Database name defaults to `stexx` (override with -v db=name for rehearsals).
\if :{?db} \else \set db stexx \endif
\getenv app_pw STEXX_APP_PW
\getenv owner_pw STEXX_OWNER_PW
\if :{?app_pw} \else \echo 'STEXX_APP_PW is not set' \quit \endif
\if :{?owner_pw} \else \echo 'STEXX_OWNER_PW is not set' \quit \endif

SELECT format('CREATE ROLE stexx_owner LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 5', :'owner_pw')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stexx_owner') \gexec
SELECT format('ALTER ROLE stexx_owner PASSWORD %L', :'owner_pw') \gexec

SELECT format('CREATE ROLE stexx_app LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 20', :'app_pw')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stexx_app') \gexec
SELECT format('ALTER ROLE stexx_app PASSWORD %L', :'app_pw') \gexec

SELECT 'CREATE ROLE stexxbackup LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION CONNECTION LIMIT 2'
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stexxbackup') \gexec
GRANT pg_read_all_data TO stexxbackup;

SELECT format('CREATE DATABASE %I OWNER stexx_owner ENCODING ''UTF8'' TEMPLATE template0', :'db')
 WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db') \gexec

-- Statements must not run unbounded or sit in an open transaction holding locks.
ALTER ROLE stexx_app SET statement_timeout = '30s';
ALTER ROLE stexx_app SET idle_in_transaction_session_timeout = '30s';
ALTER ROLE stexx_app SET lock_timeout = '10s';
ALTER ROLE stexxbackup SET statement_timeout = 0;

REVOKE ALL ON DATABASE :"db" FROM PUBLIC;
GRANT CONNECT ON DATABASE :"db" TO stexx_app, stexxbackup;
GRANT CONNECT, CREATE ON DATABASE :"db" TO stexx_owner;

\connect :"db"
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO stexx_app, stexxbackup;
GRANT ALL ON SCHEMA public TO stexx_owner;
