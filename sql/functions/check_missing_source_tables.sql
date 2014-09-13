/*
 * Check data sources to see what tables exist there that are not set up for mimeo replication
 * Provides monitoring capability for situations where all tables on source should be replicated.
 * Returns a record value so that a WHERE condition can be used to ignore tables that aren't desired.
 * Note this does NOT check for source views.
 * If p_data_source_id value is not given, all configured sources are checked.
 */
CREATE FUNCTION check_missing_source_tables(p_data_source_id int DEFAULT NULL, OUT schemaname text, OUT tablename text, OUT data_source int) RETURNS SETOF record
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE

v_dblink_schema     text;
v_exists            int;
v_row_dblink        record;
v_row_missing       record;

BEGIN

IF p_data_source_id IS NOT NULL THEN
    SELECT count(*) INTO v_exists FROM @extschema@.dblink_mapping_mimeo WHERE data_source_id = p_data_source_id;
    IF v_exists < 1 THEN
        RAISE EXCEPTION 'Given data_source_id (%) does not exist in @extschema@.dblink_mapping_mimeo config table', p_data_source_id;
    END IF;
END IF;

SELECT nspname INTO v_dblink_schema FROM pg_namespace n, pg_extension e WHERE e.extname = 'dblink' AND e.extnamespace = n.oid;

FOR v_row_dblink IN SELECT data_source_id FROM @extschema@.dblink_mapping_mimeo
LOOP
    -- Allow a parameter to choose which data sources are checked. If parameter is NULL, check them all.
    IF p_data_source_id IS NOT NULL THEN
        IF p_data_source_id <> v_row_dblink.data_source_id THEN
            CONTINUE;
        END IF;
    END IF;
    EXECUTE 'SELECT '||v_dblink_schema||'.dblink_connect(''mimeo_missing'', @extschema@.auth('||v_row_dblink.data_source_id||'))';

    CREATE TEMP TABLE current_source_tables_tmp (schemaname text, tablename text);
    EXECUTE 'INSERT INTO current_source_tables_tmp SELECT schemaname, tablename FROM '||v_dblink_schema||'.dblink(''mimeo_missing'', 
            ''SELECT schemaname, tablename AS tablename FROM pg_catalog.pg_tables WHERE schemaname NOT IN (''''pg_catalog'''', ''''information_schema'''', ''''@extschema@'''')'') t (schemaname text, tablename text)';

    CREATE TEMP TABLE current_dest_tables_tmp AS
    SELECT source_table FROM @extschema@.refresh_config_snap WHERE dblink = v_row_dblink.data_source_id
    UNION
    SELECT source_table FROM @extschema@.refresh_config_inserter WHERE dblink = v_row_dblink.data_source_id
    UNION
    SELECT source_table FROM @extschema@.refresh_config_updater WHERE dblink = v_row_dblink.data_source_id
    UNION
    SELECT source_table FROM @extschema@.refresh_config_dml WHERE dblink = v_row_dblink.data_source_id
    UNION
    SELECT source_table FROM @extschema@.refresh_config_logdel WHERE dblink = v_row_dblink.data_source_id
    UNION
    SELECT source_table FROM @extschema@.refresh_config_table WHERE dblink = v_row_dblink.data_source_id;

    FOR v_row_missing IN 
        SELECT s.schemaname, s.tablename 
        FROM current_source_tables_tmp s
        LEFT OUTER JOIN current_dest_tables_tmp d ON s.schemaname||'.'||s.tablename = d.source_table
        WHERE d.source_table IS NULL
        ORDER BY s.schemaname, s.tablename
    LOOP
        schemaname := v_row_missing.schemaname;
        tablename := v_row_missing.tablename;
        data_source = v_row_dblink.data_source_id;
        RETURN NEXT;
    END LOOP;

    EXECUTE 'SELECT '||v_dblink_schema||'.dblink_disconnect(''mimeo_missing'')';

    DROP TABLE IF EXISTS current_source_tables_tmp;
    DROP TABLE IF EXISTS current_dest_tables_tmp;

END LOOP;

END
$$;

