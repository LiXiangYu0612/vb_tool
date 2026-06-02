#!/bin/bash
# Command: kill - Terminate sessions by conditions

kill_help() {
    echo "Options for kill:"
    echo "  Usage: [OPTIONS] [SQL_OPTIONS]"
    echo "  Options:"
    echo "    -a              ALL Exclude background sessions"
    echo "    -d appname      Filter by application name"
    echo "    -i ip           Filter by client IP"
    echo "    -p pid          Filter by session ID"
    echo "    -q sqlid        Filter by unique SQL ID"
    echo "    -s state        Filter by session state"
    echo "    -t interval(s)  Filter transactions running longer than interval(seconds)"
    echo "    -u name         Filter by username"
    echo ""
}
run_kill_sessions() {
    CONDITIONS=()
    PSQL_OPTS=()

    while getopts ":i:s:p:q:d:au:u:t:" opt; do
      case $opt in
        i) CONDITIONS+=("client_addr = ''$OPTARG''") ;;
        s) CONDITIONS+=("state = ''$OPTARG'' and datname not in (''postgres'',''vastbase'',''panweidb'')") ;;
        p) CONDITIONS+=("pid = ''$OPTARG''") ;;
        q) CONDITIONS+=("unique_sql_id = ''$OPTARG''") ;;
        d) CONDITIONS+=("application_name = ''$OPTARG''") ;;
        a) CONDITIONS+=("datname not in (''postgres'',''vastbase'',''panweidb'')") ;;
        u) CONDITIONS+=("usename = ''$OPTARG'' ") ;;
        t) CONDITIONS+=("EXTRACT(EPOCH FROM (now() - xact_start))>$OPTARG and datname not in (''postgres'',''vastbase'',''panweidb'')") ;;
        \?) echo "Invalid option: -$OPTARG" >&2; exit 1 ;;
        :) echo "Option -$OPTARG requires argument" >&2; exit 1 ;;
      esac
    done
    shift $((OPTIND-1))
    PSQL_OPTS=("$@")

    if [ ${#CONDITIONS[@]} -eq 0 ]; then
      echo "Error: At least one filter condition required"
      kill_help
      exit 1
    fi

    WHERE_CLAUSE=''
    
    for condition in "${CONDITIONS[@]}"; do
      if [ -z "$WHERE_CLAUSE" ]; then
        WHERE_CLAUSE="$condition"
      else
        WHERE_CLAUSE="$WHERE_CLAUSE AND $condition"
      fi
    done

    psql -d postgres "${PSQL_OPTS[@]}" <<EOF
DO \$\$
DECLARE
  r record;
  result boolean;
  total int := 0;
  killed int := 0;
BEGIN
  FOR r IN EXECUTE 'SELECT pid FROM pg_stat_activity WHERE $WHERE_CLAUSE AND PID<>pg_backend_pid()'
  LOOP
    BEGIN
      EXECUTE 'SELECT pg_terminate_backend(' || r.pid || ')' INTO result;
      IF result THEN 
        killed := killed + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'Error terminating PID %: %', r.pid, SQLERRM;
    END;
  END LOOP;
  
  RAISE NOTICE 'Terminated % sessions', killed;
END;
\$\$;
EOF
}
