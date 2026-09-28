-- LICENSEURI https://yuruna.link/license
-- Copyright (c) 2019-2026 by Alisson Sol et al.
-- Run with psql -v ON_ERROR_STOP=1 as the schema owner in a disposable database
-- after loading schema.sql. Assertions run as the actual application role.
BEGIN;
SET LOCAL ROLE yuruna_agent_ro;
DO $$
DECLARE
    statement text;
    found_count bigint;
BEGIN
    IF has_table_privilege(current_user, 'customer', 'SELECT') OR
       has_column_privilege(current_user, 'customer', 'email', 'SELECT') THEN
        RAISE EXCEPTION 'Agent role retains broad or PII read privileges';
    END IF;
    SELECT count(*) INTO found_count FROM customer;
    IF found_count = 0 THEN RAISE EXCEPTION 'Missing fixture customers'; END IF;
    PERFORM c.company_name, SUM(i.amount_usd)
      FROM customer c JOIN subscription s ON s.customer_id = c.customer_id
      JOIN invoice i ON i.subscription_id = s.subscription_id
      GROUP BY c.company_name ORDER BY SUM(i.amount_usd) DESC LIMIT 10;
    PERFORM region, count(*) FROM v_active_subscription GROUP BY region;

    FOREACH statement IN ARRAY ARRAY[
        'SELECT email FROM customer',
        'SELECT * FROM customer',
        'SELECT c.* FROM customer c',
        'SELECT c FROM customer c',
        'SELECT row_to_json(c) FROM customer c',
        'SELECT to_jsonb(c) FROM customer c',
        'SELECT (ROW(c)).f1 FROM customer c',
        'UPDATE customer SET company_name = ''forbidden'''
    ] LOOP
        BEGIN
            EXECUTE statement;
            RAISE EXCEPTION 'Forbidden SQL unexpectedly succeeded: %', statement;
        EXCEPTION WHEN insufficient_privilege THEN
            NULL;
        END;
    END LOOP;

    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'public' AND table_name = 'customer' AND column_name = 'email') THEN
        RAISE EXCEPTION 'PII column remains visible in readable schema';
    END IF;
    SELECT count(*) INTO found_count FROM pg_constraint fk
      CROSS JOIN LATERAL unnest(fk.conkey, fk.confkey) AS cols(srcnum, dstnum)
      WHERE fk.contype = 'f' AND fk.conrelid = 'customer'::regclass
        AND has_column_privilege(fk.conrelid, cols.srcnum, 'SELECT')
        AND has_column_privilege(fk.confrelid, cols.dstnum, 'SELECT');
    IF found_count <> 2 THEN RAISE EXCEPTION 'Readable customer foreign keys were lost'; END IF;
END$$;
ROLLBACK;
