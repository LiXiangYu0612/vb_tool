#!/bin/bash
# Command: dead_tups - display dead tuples information

dead_tups_help() {
    echo "Options for dead_tups:"
    echo "  Usage: [-d <database>] [-s <schema>] [-t <table>]"
    echo "  Options:"
    echo "    -d: database name"
    echo "    -s: schema name"
    echo "    -t: table name"
    echo ""
}

run_dead_tups() {
    local OPTIND=1
    CONDITIONS=()
    PSQL_OPTS=()
    local db_param=""
    
    while getopts ":d:s:t:" opt; do
      case $opt in
        d) db_param="$OPTARG" ;;
        s) CONDITIONS+=("and n.nspname = '$OPTARG'") ;;
        t) CONDITIONS+=("and c.relname = '$OPTARG'") ;;
        \?) echo "Invalid option: -$OPTARG" >&2; exit 1 ;;
        :) echo "Option -$OPTARG requires argument" >&2; exit 1 ;;
      esac
    done
    shift $((OPTIND-1))
    PSQL_OPTS=("$@")

    if [ -z "$db_param" ]; then
        echo "Error: -d parameters required" >&2
        dead_tups_help
        exit 1
    fi

    WHERE_CLAUSE=''
    
    for condition in "${CONDITIONS[@]}"; do
      if [ -z "$WHERE_CLAUSE" ]; then
        WHERE_CLAUSE="$condition"
      else
        WHERE_CLAUSE="$WHERE_CLAUSE $condition"
      fi
    done

    psql -d "$db_param"  <<EOF
\echo '=========================='
\echo ' Instance xid information '
\echo '=========================='
select gs_txid_oldestxmin() as oldestxmin, case pg_is_in_recovery() when true then null else txid_current() end as current_xid, c.two_pc_cnt,c.two_pc_minxid,d.slot_xmin,d.slot_catalog_xmin 
,(select gs_get_shared_memctx_detail('ProcSubXidCacheContext') limit 1) as subxid_size
from  (select count(*) as two_pc_cnt,min(transaction::text) as two_pc_minxid from pg_prepared_xacts) c,
(select min(xmin::text) as slot_xmin,min(catalog_xmin::text) as slot_catalog_xmin  from pg_replication_slots) d 
where 1=1;
\echo '=========================='
\echo ' Oldestxmin information   '
\echo '=========================='
select a.gxid,a.xmin,a.pid,b.application_name,b.state,b.xact_start::timestamp(0),b.query_start::timestamp(0),substr(b.query,1,30) as query from pg_running_xacts a left join  pg_stat_activity b on a.pid=b.pid where a.gxid=gs_txid_oldestxmin() union 
select a.gxid,a.xmin,a.pid,b.application_name,b.state,b.xact_start::timestamp(0),b.query_start::timestamp(0),substr(b.query,1,30) as query from pg_running_xacts a left join  pg_stat_activity b on a.pid=b.pid where a.xmin=gs_txid_oldestxmin() ;
\echo '=========================='
\echo ' Dead tuples information  '
\echo '=========================='
SELECT c.oid AS relid, n.nspname||'.'||c.relname as tablename,age(relfrozenxid64) as table_age, c.relpages, c.reltuples, 
    pg_stat_get_tuples_changed(c.oid) as n_dml_tup,
    pg_stat_get_live_tuples(c.oid) AS n_live_tup, 
    pg_stat_get_dead_tuples(c.oid) AS n_dead_tup, 
    case when coalesce(pg_stat_get_last_vacuum_time(c.oid),'2000-01-01 00:00:00') 
               < coalesce(pg_stat_get_last_autovacuum_time(c.oid),'2001-01-01 00:00:00') 
         then pg_stat_get_last_autovacuum_time(c.oid)::timestamp(0) 
         else pg_stat_get_last_vacuum_time(c.oid)::timestamp(0)
         end as latest_vacuum,
    case when coalesce(pg_stat_get_last_analyze_time(c.oid),'2000-01-01 00:00:00') 
               < coalesce(pg_stat_get_last_autoanalyze_time(c.oid),'2001-01-01 00:00:00') 
         then pg_stat_get_last_autoanalyze_time(c.oid)::timestamp(0) 
         else pg_stat_get_last_analyze_time(c.oid)::timestamp(0)
         end as latest_analyze
   FROM pg_class AS c
   LEFT JOIN pg_namespace AS n ON n.oid = c.relnamespace
  WHERE c.relkind in ('r', 't', 'm')
  $WHERE_CLAUSE
 order by n_dead_tup desc ,reltuples desc 
 limit 30;
\echo '=========================='
\echo 'Show parameter from vacuum'
\echo '=========================='
SELECT name,decode(unit,'8kB',setting*8||'kB',setting||COALESCE(unit,' ')) setting,context FROM pg_settings WHERE name LIKE '%vacuum%';
EOF
}
