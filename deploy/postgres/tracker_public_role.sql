-- Read-only role for the Device Tracker portal in direct-database mode (SESHAT_PORTAL_MODE=db) and,
-- optionally, shared mode (SESHAT_PORTAL_MODE=shared with SESHAT_PORTAL_DB_URL). See
-- docs/device-tracker-portal.md and docs/schema/tracker.md.
--
-- Run as a superuser or the database owner, connected to the database Seshat uses (the one whose
-- migrations created the tracker_public schema). Replace the password placeholder; do not commit a
-- real one. The role can read the views and nothing else: no tables, no other schema, no writes.
--
--   psql "$SESHAT_DATABASE_URL_ADMIN" -v portal_password="'<a long random password>'" -f tracker_public_role.sql

-- 1. Group role that owns the grants; login roles inherit from it.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'tracker_portal_ro') THEN
        CREATE ROLE tracker_portal_ro NOLOGIN;
    END IF;
END
$$;

-- 2. The views, and only the views.
GRANT USAGE ON SCHEMA tracker_public TO tracker_portal_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA tracker_public TO tracker_portal_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA tracker_public GRANT SELECT ON TABLES TO tracker_portal_ro;

-- 3. The login the portal uses, read-only even if a grant is added by mistake later.
CREATE ROLE tracker_portal LOGIN PASSWORD :portal_password IN ROLE tracker_portal_ro;
ALTER ROLE tracker_portal SET default_transaction_read_only = on;
ALTER ROLE tracker_portal SET statement_timeout = '15s';
ALTER ROLE tracker_portal CONNECTION LIMIT 10;

-- 4. Make sure nothing else is reachable: the base tables, audit data and every other schema stay closed.
REVOKE ALL ON SCHEMA public FROM tracker_portal_ro;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

-- The portal then connects with:
--   SESHAT_PORTAL_DB_URL=postgres://tracker_portal:<password>@db.example.com:5432/seshat?sslmode=verify-full
-- Check:
--   SELECT has_table_privilege('tracker_portal', 'tracker_public.devices', 'SELECT');   -- t
--   SELECT has_table_privilege('tracker_portal', 'public.users', 'SELECT');             -- f
