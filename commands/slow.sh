#!/bin/bash
# Command: slow - display top slow sql Information

slow_help() {
    echo "Options for slow:"
    echo "  Usage: vb_tool slow"
    echo "  Description: display top slow sql Information"
    echo ""
}

run_slow() {
    psql -d postgres <<EOF
\pset footer off
\echo 'Default begin date: trunc(now()-5/24/60,'MI')'
\echo 'Default end date: trunc(now()+1/24/60,'MI')'
\echo 'Default top_n: 10'
\prompt 'Enter begin date: ' begin_date
\prompt 'Enter end date: ' end_date
\prompt 'Enter top_n: ' top_n
\echo '===================='
\echo '   top slow sql     '
\echo '===================='
select start_time,user_name||' '||schema_name user_name,unique_query_id,execs,db_ms,et_ms,cpu_ms,io_ms,parse_ms,avg_cr,avg_pr,n_rows from(
select substr(trunc(start_time,'MI'),1,19) start_time,user_name,schema_name,unique_query_id,ora_hash(
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
sum(db_time) total_db_ms,
round(avg(db_time)/1e3,1) db_ms,
round(avg(execution_time)/1e3,1) et_ms,
round(avg(cpu_time)/1e3,1) cpu_ms,
round(avg(data_io_time)/1e3,1) io_ms,
round(avg(parse_time+plan_time+rewrite_time)/1e3,1) parse_ms,
round(avg(n_blocks_fetched),1) avg_cr,
round(avg(n_blocks_fetched-n_blocks_hit),1) avg_pr,
round(avg(n_returned_rows),1) n_rows ,
row_number()over(partition by substr(trunc(start_time,'MI'),1,19) order by sum(db_time) desc) rn
from pg_catalog.statement_history
where start_time between (case when :'begin_date'='' or :'begin_date' is null then  to_char(trunc(now()-5/24/60,'MI'),'yyyy-mm-dd hh24:mi:ss') else :'begin_date' end) and (case when :'end_date'='' or :'end_date' is null then to_char(trunc(now()+1/24/60,'MI'),'yyyy-mm-dd hh24:mi:ss') else :'end_date' end) and is_slow_sql='t'
group by substr(trunc(start_time,'MI'),1,19),user_name,schema_name,unique_query_id,ora_hash(
  regexp_replace(
    regexp_replace(
      regexp_replace(query_plan,
        '"[0-9]+__unnamed_subquery__"', '"unnamed_subquery"', 'g'
      ),
      '\(cost=.*?\)', '', 'g'
    ),
    '^(\s+Filter:).*$', '\1', 'gm'
  )
))
where rn<=(case when :'top_n'='' or :'top_n' is null then '10' else :'top_n' end)
order by 1,execs*db_ms desc;
EOF
}
