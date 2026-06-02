#!/bin/bash
# Command: sqlstat - display sqlstat information

sqlstat_help() {
    echo "Options for sqlstat:"
    echo "  Usage: vb_tool sqlstat [unique_query_id]"
    echo "  Description: display sqlstat information"
    echo ""
}

run_sqlstat() {
    local unique_query_id="$1"
    psql -d postgres <<EOF
\pset footer off
\set unique_sql_id '$unique_query_id'
\echo '======='
\echo 'sqltext'
\echo '======='
\echo '                          '
SELECT query FROM dbe_perf.statement WHERE unique_sql_id=:'unique_sql_id';
\echo '======='
\echo 'sqlplan'
\echo '======='
\echo '                          '
SELECT to_char(max(start_time),'yyyy-mm-dd hh24:mi:ss') last_exec_time,ora_hash(regexp_replace(query_plan,'\(cost=.*?\)','','g')) plan_hash_value,max(query_plan) query_plan FROM dbe_perf.statement_history WHERE unique_query_id=:'unique_sql_id' group by ora_hash(regexp_replace(query_plan,'\(cost=.*?\)','','g')) order by 1;
\echo '======================'
\echo 'sqlstat from statement'
\echo '======================'
\echo '                          '
SELECT user_name,n_calls,
round(db_time/1e3/n_calls,1) avg_db_ms,
round(execution_time/1e3/n_calls,1) avg_et_ms,
round(cpu_time/1e3/n_calls,1) avg_cpu_ms,
round(data_io_time/1e3/n_calls,1) avg_io_ms,
round((parse_time+plan_time+rewrite_time)/1e3/n_calls,1) avg_plan_ms,
round(pl_execution_time/1e3/n_calls,1) avg_plsql_ms,
round(sort_time/1e3/n_calls,1) a_sort_ms,
round(hash_time/1e3/n_calls,1) a_hash_ms,
round(n_blocks_fetched/n_calls,1) avg_cr,
round((n_blocks_fetched-n_blocks_hit)/n_calls,1) avg_pr,
round((n_returned_rows+n_tuples_inserted+n_tuples_updated+n_tuples_deleted)/n_calls,1) avg_rows
FROM dbe_perf.statement WHERE unique_sql_id=:'unique_sql_id';
\echo '====================================='
\echo 'slow statement_history from sysdate-3'
\echo '====================================='
\echo '                                   '
select user_name,ora_hash(
  regexp_replace(
    regexp_replace(
      regexp_replace(query_plan,
        '"[0-9]+__unnamed_subquery__"', '"unnamed_subquery"', 'g'
      ),
      '\(cost=.*?\)', '', 'g'
    ),
    '^(\s+Filter:).*$', '\1', 'gm'
  )
) plan_hash_value,count(*) execs,
round(avg(db_time)/1e3,1) avg_db_ms,
round(avg(execution_time)/1e3,1) avg_et_ms,
round(avg(cpu_time)/1e3,1) avg_cpu_ms,
round(avg(data_io_time)/1e3,1) avg_io_ms,
round(avg(lock_wait_time)/1e3,1) lock_wait_ms,
round(avg(lwlock_wait_time)/1e3,1) lwlock_wait_ms,
round(avg(n_blocks_fetched),1) avg_cr,
round(avg(n_blocks_fetched-n_blocks_hit),1) avg_pr,
round(avg(n_returned_rows+n_tuples_inserted+n_tuples_updated+n_tuples_deleted),1) avg_rows from dbe_perf.statement_history
where unique_query_id=:'unique_sql_id' and is_slow_sql='t' and start_time>now()-3
group by ora_hash(
  regexp_replace(
    regexp_replace(
      regexp_replace(query_plan,
        '"[0-9]+__unnamed_subquery__"', '"unnamed_subquery"', 'g'
      ),
      '\(cost=.*?\)', '', 'g'
    ),
    '^(\s+Filter:).*$', '\1', 'gm'
  )
),user_name;
\echo '=============================='
\echo 'sqlstat history from sysdate-3'
\echo '=============================='
\echo '                              '
select snap_user_name uname,snap_time,n_calls,avg_db_ms,avg_et_ms,avg_cpu_ms,avg_io_ms,avg_cr,avg_pr,avg_rows from 
(select snap_user_name,snap_time,n_calls,
round(db_time/1e3/n_calls,1) avg_db_ms,
round(execution_time/1e3/n_calls,1) avg_et_ms,
round(cpu_time/1e3/n_calls,1) avg_cpu_ms,
round(data_io_time/1e3/n_calls,1) avg_io_ms,
round(n_blocks_fetched/n_calls,1) avg_cr,
round((n_blocks_fetched-n_blocks_hit)/n_calls,1) avg_pr,
round((n_returned_rows+n_insert_rows+n_update_rows+n_delete_rows)/n_calls,1) avg_rows
from 
(SELECT snap_user_name,to_char(start_ts,'yyyy-mm-dd hh24:mi:ss') snap_time,
    snap_n_calls-coalesce(lag(snap_n_calls)over(partition by snap_user_name,snap_unique_sql_id order by a.snapshot_id),0) n_calls,
    snap_db_time-coalesce(lag(snap_db_time)over(partition by snap_user_name,snap_unique_sql_id order by a.snapshot_id),0) db_time,
    snap_execution_time-coalesce(lag(snap_execution_time)over(partition by snap_user_name,snap_unique_sql_id order by a.snapshot_id),0) execution_time,
    snap_cpu_time-coalesce(lag(snap_cpu_time)over(partition by snap_user_name,snap_unique_sql_id order by a.snapshot_id),0) cpu_time,
    snap_data_io_time-coalesce(lag(snap_data_io_time)over(partition by snap_user_name,snap_unique_sql_id order by a.snapshot_id),0) data_io_time,
    snap_n_blocks_fetched-coalesce(lag(snap_n_blocks_fetched)over(partition by snap_user_name,snap_unique_sql_id order by a.snapshot_id),0) n_blocks_fetched,
    snap_n_blocks_hit-coalesce(lag(snap_n_blocks_hit)over(partition by snap_user_name,snap_unique_sql_id order by a.snapshot_id),0) n_blocks_hit,
    snap_n_returned_rows-coalesce(lag(snap_n_returned_rows)over(partition by snap_user_name,snap_unique_sql_id order by a.snapshot_id),0) n_returned_rows,
	snap_n_tuples_inserted-coalesce(lag(snap_n_tuples_inserted)over(partition by snap_user_name,snap_unique_sql_id order by a.snapshot_id),0) n_insert_rows,
    snap_n_tuples_updated-coalesce(lag(snap_n_tuples_updated)over(partition by snap_user_name,snap_unique_sql_id order by a.snapshot_id),0) n_update_rows,
    snap_n_tuples_deleted-coalesce(lag(snap_n_tuples_deleted)over(partition by snap_user_name,snap_unique_sql_id order by a.snapshot_id),0) n_delete_rows
    FROM snapshot.snap_summary_statement a,snapshot.snapshot  b
    WHERE snap_unique_sql_id=:'unique_sql_id'
      and a.snapshot_id=b.snapshot_id
      and start_ts>now()-3) where n_calls>0 order by 2) where snap_time<(select max(start_ts) from snapshot.snapshot);
EOF
}
