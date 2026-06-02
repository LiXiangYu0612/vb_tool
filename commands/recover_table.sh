#!/bin/bash
# Command: recover_table - Recover table data by CTID scan

recover_table_help() {
    echo "Options for recover_table:"
    echo "  Usage: -d <database> -s <schema> -t <table> [-n <rows_per_page>]"
    echo "  Options:"
    echo "    -d: database name (required)"
    echo "    -s: schema name (required)"
    echo "    -t: table name (required)"
    echo "    -n: rows per page (optional, default: 100)"
    echo ""
}
run_recover_table() {
    local db_name=""
    local schema_name=""
    local table_name=""
    local rows_per_page="100"  
    
    while getopts ":d:s:t:n:" opt; do
      case $opt in
        d) db_name="$OPTARG" ;;
        s) schema_name="$OPTARG" ;;
        t) table_name="$OPTARG" ;;
        n) rows_per_page="$OPTARG" ;;
        \?) echo "Invalid option: -$OPTARG" >&2; exit 1 ;;
        :) echo "Option -$OPTARG requires argument" >&2; exit 1 ;;
      esac
    done

    if [ -z "$db_name" ] || [ -z "$schema_name" ] || [ -z "$table_name" ]; then
        echo "Error: -d (database), -s (schema), and -t (table) parameters are required" >&2
        recover_table_help
        exit 1
    fi
    
    echo "Starting table recovery: database=$db_name, schema=$schema_name, table=$table_name, rows_per_page=$rows_per_page"
    
    psql -d "$db_name" <<EOF
DO \$\$
DECLARE
   v_s_bno INTEGER;
   v_e_bno INTEGER;
   v_ctid TID;
   v_owner VARCHAR(100) := '$schema_name';
   v_table VARCHAR(100) := '$table_name';
   v_o_table VARCHAR(100);
   v_sql TEXT;
   nrows INTEGER := $rows_per_page;
BEGIN
   v_s_bno := 0;
   v_o_table := v_table || '_recover_' || to_char(now(), 'hh24miss');
   
   EXECUTE 'SET search_path TO ' || v_owner;

   v_s_bno := 0;
   v_o_table := v_table || '_recover_'||to_char(sysdate,'hh24miss');
   
   EXECUTE 'SET search_path TO ' || v_owner;

   EXECUTE 'CREATE TABLE IF NOT EXISTS ' || v_owner || '.' || v_o_table || 
           ' (LIKE ' || v_owner || '.' || v_table || ')';
      
   SELECT (pg_relation_size((v_owner || '.' || v_table)::regclass) / 8192)::INTEGER INTO v_e_bno;
   
   
   FOR j IN v_s_bno .. v_e_bno LOOP
      BEGIN
         FOR x IN 0 .. nrows LOOP
            v_ctid := '(' || j || ',' || x || ')';
            v_sql := 'INSERT INTO ' || v_o_table || 
                     ' SELECT * FROM ' || v_table || 
                     ' WHERE ctid = ''' || v_ctid || '''';
            EXECUTE v_sql;
         END LOOP;
      EXCEPTION 
         WHEN OTHERS THEN 
            NULL;
      END;
   END LOOP;
   
  RAISE NOTICE 'Data recovery completed successfully: %', v_o_table;
   
END \$\$;
EOF
}

