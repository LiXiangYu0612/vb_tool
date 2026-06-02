#!/bin/bash
# Command: as - Display active session info

as_help() {
    echo "Usage: vb_tool as [vb pid]"
    echo "Description: Display active session info for the given vb pid."
    echo ""
}
run_as() {
    local pid="$1"
    if [ -z "$pid" ]; then
        echo "Error: Please specify <vastbase_pid>" >&2
        as_help
        exit 1
    fi
# psa_flag:  Version identifier for the `pg_stat_activity` table.
# The version is determined by the presence of specific columns.
#   0 - Table does not have 'unique_sql_id' column.
#   1 - Table has 'unique_sql_id' column.
    local psa_flag=$(psql -qAtXc "select coalesce(sum(case when attname='unique_sql_id' then 1 else 0 end),0) as psa_flag
                            from pg_attribute a,pg_class b, pg_namespace c
                            where a.attrelid=b.oid 
                            and b.relnamespace=c.oid
                            and b.relname='pg_stat_activity' 
                            and c.nspname='pg_catalog'")

    if [[ "$psa_flag" = 1 ]]; then
    psql -d postgres <<EOF
\pset footer off
\echo '================================'
\echo 'long transaction info(limit 10) '
\echo '================================'
SELECT  case when client_addr is null then a.datname else a.datname||':'||client_addr end client_info,
        a.sessionid||':'||decode(w.block_sessionid,null,'not wait',w.block_sessionid) sid_bsid
        ,a.unique_sql_id
        ,w.wait_event
        ,round(EXTRACT(EPOCH FROM (now() - xact_start))) etime
        ,state
		,waiting
	FROM pg_stat_activity a left join dbe_perf.thread_wait_status w on a.sessionid = w.sessionid
where round(EXTRACT(EPOCH FROM (now() - xact_start)))>1
ORDER BY etime DESC nulls last limit 10;

\echo '================================'
\echo 'active session info(limit 30)   '
\echo '================================'
SELECT case when client_addr is null then a.datname else a.datname||':'||client_addr end client_info,
        a.sessionid||':'||decode(w.block_sessionid,null,'not wait',w.block_sessionid) sid_bsid
        ,a.unique_sql_id
        ,w.wait_event
        ,round(EXTRACT(EPOCH FROM (now() - query_start))) etime
        ,decode(STATE, 'active', 'a', 'idle in transaction', 'it', 'idle in transaction (aborted)', 'ita') || ':' || decode(waiting, 'true', 't', 'f') state
        ,substr( REGEXP_REPLACE(REGEXP_REPLACE(query, '(\r|\n)+', ' '),' {2,}', ' '),1,50) sqltext
FROM pg_stat_activity a left join dbe_perf.thread_wait_status w on a.sessionid = w.sessionid
WHERE   a.STATE NOT IN ('idle')
        AND a.datname NOT IN ('postgres')
        AND round(EXTRACT(EPOCH FROM (now() - query_start)),2)>=0.1
ORDER BY etime DESC nulls last limit 30;

\echo '========================================'
\echo 'client connection info  '
\echo '========================================'

select client_addr,case when upper(application_name) like '%JDBC%' then 'JDBC' else application_name end application_name,state,count(*) cnt from pg_stat_activity where client_addr is not null group by client_addr,state,case when upper(application_name) like '%JDBC%' then 'JDBC' else application_name end order by 3,4 desc;

\echo '========================================'
\echo 'session state info  '
\echo '========================================'

select state,count(*) cnt from pg_stat_activity where client_addr is not null group by state order by 1;

\echo '=============================================='
\echo 'top 10 running slow sql(sqlid duration>=1s)   '
\echo '=============================================='

SELECT datname||':'||usename username,unique_sql_id,round(sum(EXTRACT(EPOCH FROM now() - query_start)),2) total_duration_s,count(*) run_cnt FROM  pg_stat_activity
WHERE EXTRACT(EPOCH FROM now() - query_start)>=1 and state='active' and datname not in ('postgres')
group by datname,usename,unique_sql_id
order by 3 desc,4 desc limit 10;

\echo '=========================================='
\echo 'top 10 running slow sql(text duration>=1s)   '
\echo '=========================================='

SELECT datname||':'||usename username,round(sum(EXTRACT(EPOCH FROM now() - query_start)),2) total_duration_s,count(*) run_cnt,substr(REGEXP_REPLACE(REGEXP_REPLACE(query, '(\r|\n)+', ' '),' {2,}', ' '),1,200) sql_text FROM  pg_stat_activity
WHERE EXTRACT(EPOCH FROM now() - query_start)>=1 and state='active' and datname not in ('postgres')
group by datname,usename,substr(REGEXP_REPLACE(REGEXP_REPLACE(query, '(\r|\n)+', ' '),' {2,}', ' '),1,200)
order by 2 desc,3 desc limit 10;
EOF

echo '=========================================='
echo '         top cpu usage info               '
echo '=========================================='
psql -d postgres -c "with tmp as (SELECT split_part(result, ',', 1) AS lwpid, split_part(result, ',', 2) AS cpu_usage FROM regexp_split_to_table('$(top -b -n1 -H -p $pid | awk '/^ *PID USER.*COMMAND$/ {getline; while (getline) print $1 "," $9}'| paste -sd ";")', ';') AS result) select round(sum(tmp.cpu_usage),2)||'%' cpu_usage,s.thread_name,a.unique_sql_id,min(s.pid) one_pid,count(*) pid_cnt,min(substr(REGEXP_REPLACE(REGEXP_REPLACE(query, '(\r|\n)+', ' '),' {2,}', ' '),1,50)) sqltext from pg_os_threads s right join tmp on s.lwpid=tmp.lwpid  left join pg_stat_activity a on s.pid=a.pid  where (a.state in ('active') or a.state is null) group by s.thread_name,a.unique_sql_id having sum(tmp.cpu_usage)>0 order by round(sum(tmp.cpu_usage),2)::numeric desc limit 10"

echo '=========================================='
echo '         top I/O usage info               '
echo '=========================================='
export S_TIME_FORMAT=ISO
psql -d postgres -c "with tmp as (SELECT split_part(result, ',', 1) AS lwpid, split_part(result, ',', 2) AS kb_rd,split_part(result, ',', 3) AS kb_wr FROM regexp_split_to_table('$(pidstat -hdt -p $pid 1 1 | awk 'NR>4 {print $4 "," $5 "," $6}' | paste -sd ";")', ';') AS result) select sum(tmp.kb_rd) read_kb,sum(tmp.kb_wr) write_kb,s.thread_name,a.unique_sql_id,min(s.pid) one_pid,count(*) pid_cnt,min(substr(REGEXP_REPLACE(REGEXP_REPLACE(query, '(\r|\n)+', ' '),' {2,}', ' '),1,50)) sqltext from pg_os_threads s right join tmp on s.lwpid=tmp.lwpid left join pg_stat_activity a on s.pid=a.pid where (a.state in ('active') or a.state is null) group by s.thread_name,a.unique_sql_id having sum(tmp.kb_rd)::numeric+sum(tmp.kb_wr)::numeric>0 order by sum(tmp.kb_rd)::numeric+sum(tmp.kb_wr)::numeric desc limit 10" 

   else
    psql -d postgres <<EOF
\pset footer off
\echo '================================'
\echo 'long transaction info(limit 10)   '
\echo '================================'
SELECT a.datname || ':' ||':'||client_addr client_info,
        a.sessionid||':'||decode(w.block_sessionid,null,'not wait',w.block_sessionid) sid_bsid
        ,a.query_id as unique_sql_id
        ,w.wait_event
		,round(EXTRACT(EPOCH FROM (now() - xact_start))) etime
        ,state
		,waiting
FROM pg_stat_activity a left join dbe_perf.thread_wait_status w on a.sessionid = w.sessionid
where round(EXTRACT(EPOCH FROM (now() - xact_start)))>1
ORDER BY etime DESC nulls last limit 10;
\echo '================================'
\echo 'active session info(limit 30)   '
\echo '================================'
SELECT a.datname || ':' ||':'||client_addr client_info,
        a.sessionid||':'||decode(w.block_sessionid,null,'not wait',w.block_sessionid) sid_bsid
        --,a.unique_sql_id
		,a.query_id
        ,w.wait_event
        ,round(EXTRACT(EPOCH FROM (now() - query_start))) etime
        ,decode(STATE, 'active', 'a', 'idle in transaction', 'it', 'idle in transaction (aborted)', 'ita') || ':' || decode(waiting, 'true', 't', 'f') state
        ,substr( REGEXP_REPLACE(REGEXP_REPLACE(query, '(\r|\n)+', ' '),' {2,}', ' '),1,50) sqltext
FROM pg_stat_activity a left join dbe_perf.thread_wait_status w on a.sessionid = w.sessionid
WHERE   a.STATE NOT IN ('idle')
        AND a.datname NOT IN ('postgres')
        AND round(EXTRACT(EPOCH FROM (now() - query_start)),2)>=0.1
ORDER BY etime DESC nulls last limit 30;

\echo '========================================'
\echo 'client connection info  '
\echo '========================================'

select client_addr,case when upper(application_name) like '%JDBC%' then 'JDBC' else application_name end application_name,state,count(*) cnt from pg_stat_activity where client_addr is not null group by client_addr,state,case when upper(application_name) like '%JDBC%' then 'JDBC' else application_name end order by 3,4 desc;

\echo '========================================'
\echo 'session state info  '
\echo '========================================'

select state,count(*) cnt from pg_stat_activity where client_addr is not null group by state order by 1;

\echo '=============================================='
\echo 'top 10 running slow sql(sqlid duration>=1s)   '
\echo '=============================================='

SELECT datname||':'||usename username,query_id as unique_sql_id,round(sum(EXTRACT(EPOCH FROM now() - query_start)),2) total_duration_s,count(*) run_cnt FROM  pg_stat_activity
WHERE EXTRACT(EPOCH FROM now() - query_start)>=1 and state='active' and datname not in ('postgres')
group by datname,usename,query_id
order by 3 desc,4 desc limit 10;

\echo '=========================================='
\echo 'top 10 running slow sql(text duration>=1s)   '
\echo '=========================================='

SELECT datname||':'||usename username,round(sum(EXTRACT(EPOCH FROM now() - query_start)),2) total_duration_s,count(*) run_cnt,substr(REGEXP_REPLACE(REGEXP_REPLACE(query, '(\r|\n)+', ' '),' {2,}', ' '),1,200) sql_text FROM  pg_stat_activity
WHERE EXTRACT(EPOCH FROM now() - query_start)>=1 and state='active' and datname not in ('postgres')
group by datname,usename,substr(REGEXP_REPLACE(REGEXP_REPLACE(query, '(\r|\n)+', ' '),' {2,}', ' '),1,200)
order by 2 desc,3 desc limit 10;
EOF

echo '=========================================='
echo '         top cpu usage info               '
echo '=========================================='
psql -d postgres -c "with tmp as (SELECT split_part(result, ',', 1) AS lwpid, split_part(result, ',', 2) AS cpu_usage FROM regexp_split_to_table('$(top -b -n1 -H -p $pid | awk '/^ *PID USER.*COMMAND$/ {getline; while (getline) print $1 "," $9}'| paste -sd ";")', ';') AS result) select sum(tmp.cpu_usage)||'%' cpu_usage,s.thread_name,a.query_id,min(s.pid) one_pid,count(*) pid_cnt,min(substr(REGEXP_REPLACE(REGEXP_REPLACE(query, '(\r|\n)+', ' '),' {2,}', ' '),1,50)) sqltext from pg_os_threads s join tmp on s.lwpid=tmp.lwpid  left join pg_stat_activity a on s.pid=a.pid  where (a.state in ('active') or a.state is null) group by s.thread_name,a.query_id having sum(tmp.cpu_usage)>50 order by round(sum(tmp.cpu_usage),2)::numeric desc limit 10"

echo '=========================================='
echo '         top I/O usage info               '
echo '=========================================='
export S_TIME_FORMAT=ISO
psql -d postgres -c "with tmp as (SELECT split_part(result, ',', 1) AS lwpid, split_part(result, ',', 2) AS kb_rd,split_part(result, ',', 3) AS kb_wr FROM regexp_split_to_table('$(pidstat -hdt -p $pid  | awk 'NR>4 {print $4 "," $5 "," $6}' | paste -sd ";")', ';') AS result) select sum(tmp.kb_rd) read_kb,sum(tmp.kb_wr) write_kb,s.thread_name,a.query_id,min(s.pid) one_pid,count(*) pid_cnt,min(substr(REGEXP_REPLACE(REGEXP_REPLACE(query, '(\r|\n)+', ' '),' {2,}', ' '),1,50)) sqltext from pg_os_threads s join tmp on s.lwpid=tmp.lwpid left join pg_stat_activity a on s.pid=a.pid where (a.state in ('active') or a.state is null) group by s.thread_name,a.query_id having sum(tmp.kb_rd)::numeric+sum(tmp.kb_wr)::numeric>128 order by sum(tmp.kb_rd)::numeric+sum(tmp.kb_wr)::numeric desc limit 10" 
fi
}
