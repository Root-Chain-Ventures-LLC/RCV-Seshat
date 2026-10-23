-- Seshat PostgreSQL roles: least privilege, own schema, no superuser.
--
--   psql "$ADMIN_URL" -v ON_ERROR_STOP=1 \
--        -v app_password="$SESHAT_APP_PASSWORD" -v ro_password="$SESHAT_RO_PASSWORD" \
--        -f deploy/postgres/roles.sql
--
-- Run it once, as a role that may create roles (the database owner or a superuser), connected to
-- the database Seshat will use. Passwords arrive as psql variables so they never sit in this file.
-- It is idempotent: running it again resets the passwords and re-applies the grants.
--
-- Optional variables (defaults in brackets): app_role [seshat_app], ro_role [seshat_readonly],
-- schema [seshat], tracker_schema [tracker_public].
--
-- What it sets up
--   * seshat_app      owns the schema `seshat`; may create its tables, the change feed, the leader
--                     lease and the tracker_public views. Not a superuser, cannot create roles or
--                     databases, cannot bypass row security, cannot replicate. Connect with
--                     search_path=seshat (set on the role; put it in the URL too).
--   * seshat_readonly for the Device Tracker portal and other readers. It can only SELECT from
--                     the schema `tracker_public` (views of the tracker data). It has no access to
--                     the `seshat` schema at all: no users, sessions, secrets or settings. Sessions
--                     are read-only by default.
\if :{?app_role} \else \set app_role seshat_app \endif
\if :{?ro_role} \else \set ro_role seshat_readonly \endif
\if :{?schema} \else \set schema seshat \endif
\if :{?tracker_schema} \else \set tracker_schema tracker_public \endif
\if :{?app_password} \else \echo 'set -v app_password=...' \quit \endif
\if :{?ro_password} \else \echo 'set -v ro_password=...' \quit \endif

-- Roles. CREATE only when missing, then always (re)apply the attributes and the password.
SELECT format('CREATE ROLE %I LOGIN', :'app_role') WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_role') \gexec
SELECT format('CREATE ROLE %I LOGIN', :'ro_role') WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'ro_role') \gexec

SELECT format('ALTER ROLE %I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS INHERIT CONNECTION LIMIT 60 PASSWORD %L',
              :'app_role', :'app_password') \gexec
SELECT format('ALTER ROLE %I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT CONNECTION LIMIT 20 PASSWORD %L',
              :'ro_role', :'ro_password') \gexec

-- The application's own schema, and the readers' schema (the application creates the views in it).
SELECT format('CREATE SCHEMA IF NOT EXISTS %I AUTHORIZATION %I', :'schema', :'app_role') \gexec
SELECT format('ALTER SCHEMA %I OWNER TO %I', :'schema', :'app_role') \gexec
SELECT format('CREATE SCHEMA IF NOT EXISTS %I AUTHORIZATION %I', :'tracker_schema', :'app_role') \gexec
SELECT format('ALTER SCHEMA %I OWNER TO %I', :'tracker_schema', :'app_role') \gexec
SELECT format('ALTER ROLE %I SET search_path = %I', :'app_role', :'schema') \gexec

-- Database level: only the two roles connect, nobody creates objects in public.
SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', current_database()) \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I, %I', current_database(), :'app_role', :'ro_role') \gexec
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

-- The readers: USAGE on the tracker schema, SELECT on what is in it now and on whatever the
-- application creates in it later. Nothing else. Default read-only transactions, short statements.
SELECT format('REVOKE ALL ON SCHEMA %I FROM %I', :'schema', :'ro_role') \gexec
SELECT format('GRANT USAGE ON SCHEMA %I TO %I', :'tracker_schema', :'ro_role') \gexec
SELECT format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO %I', :'tracker_schema', :'ro_role') \gexec
SELECT format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I GRANT SELECT ON TABLES TO %I', :'app_role', :'tracker_schema', :'ro_role') \gexec
SELECT format('ALTER ROLE %I SET search_path = %I', :'ro_role', :'tracker_schema') \gexec
SELECT format('ALTER ROLE %I SET default_transaction_read_only = on', :'ro_role') \gexec
SELECT format('ALTER ROLE %I SET statement_timeout = ''30s''', :'ro_role') \gexec
SELECT format('ALTER ROLE %I SET idle_in_transaction_session_timeout = ''60s''', :'ro_role') \gexec

\echo 'roles ready. Point SESHAT_DATABASE_URL at the application role (see docs/storage.md).'
