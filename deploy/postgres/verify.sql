-- Checks the grants of roles.sql. Run it as the READ-ONLY role; every check must print PASS.
--
--   psql "postgres://seshat_readonly:<password>@<host>/<db>?sslmode=verify-full" -v ON_ERROR_STOP=1 -f deploy/postgres/verify.sql
--
-- Pass -v schema=... when you changed the application schema name.
\if :{?schema} \else \set schema seshat \endif

SELECT set_config('seshat.verify_schema', :'schema', false) AS _ \gset

DO $$
DECLARE
  s text := current_setting('seshat.verify_schema');
  tbl text;
  denied boolean;
BEGIN
  -- 1. No access to any application table, whatever it is called.
  FOREACH tbl IN ARRAY ARRAY['users', 'sessions', 'settings', 'destinations', 'audit_log', 'snmp_v3_users', 'devices', 'leader'] LOOP
    denied := false;
    BEGIN
      EXECUTE format('SELECT 1 FROM %I.%I LIMIT 1', s, tbl);
    EXCEPTION WHEN insufficient_privilege THEN denied := true;
              WHEN undefined_table THEN denied := true;
    END;
    IF NOT denied THEN RAISE EXCEPTION 'FAIL: the read-only role can read %.%', s, tbl; END IF;
  END LOOP;
  RAISE NOTICE 'PASS: no access to the application schema';

  -- 2. No writes anywhere (read-only transactions by default, and no privileges).
  denied := false;
  BEGIN
    EXECUTE 'CREATE TABLE tracker_public.verify_probe (x int)';
  EXCEPTION WHEN insufficient_privilege OR read_only_sql_transaction THEN denied := true;
  END;
  IF NOT denied THEN RAISE EXCEPTION 'FAIL: the read-only role can create objects'; END IF;
  RAISE NOTICE 'PASS: cannot create objects';

  -- 3. Not a superuser, no role or database creation.
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = current_user AND (rolsuper OR rolcreaterole OR rolcreatedb OR rolreplication OR rolbypassrls)) THEN
    RAISE EXCEPTION 'FAIL: the read-only role has elevated attributes';
  END IF;
  RAISE NOTICE 'PASS: no elevated attributes';

  -- 4. It can use the tracker schema.
  IF NOT has_schema_privilege(current_user, 'tracker_public', 'USAGE') THEN
    RAISE EXCEPTION 'FAIL: no USAGE on tracker_public';
  END IF;
  RAISE NOTICE 'PASS: USAGE on tracker_public';
END $$;
