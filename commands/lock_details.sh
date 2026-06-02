#!/bin/bash
# Command: lock_details - display detailed lock information (holders & waiters)

lock_details_help() {
    echo "Options for lock_details:"
    echo "  Usage: None"
    echo "  Description: display detailed lock information (holders & waiters)"
    echo ""
}

run_lock_details() {
    psql -d postgres <<EOF
\pset footer off
\pset format unaligned
\pset tuples_only on
\echo '=========================='
\echo 'detailed lock information'
\echo '=========================='
WITH t_wait AS (
  SELECT a.mode,a.locktype,a.database,a.relation,a.page,a.tuple,a.classid,a.granted,
         a.objid,a.objsubid,a.pid,a.virtualtransaction,a.virtualxid,a.transactionid,a.fastpath,
         b.state,b.query,b.xact_start,b.query_start,b.usename,b.datname,b.client_addr,b.client_port,b.application_name
  FROM pg_locks a,pg_stat_activity b WHERE a.pid=b.pid AND NOT a.granted
),
t_run AS (
  SELECT a.mode,a.locktype,a.database,a.relation,a.page,a.tuple,a.classid,a.granted,
         a.objid,a.objsubid,a.pid,a.virtualtransaction,a.virtualxid,a.transactionid,a.fastpath,
         b.state,b.query,b.xact_start,b.query_start,b.usename,b.datname,b.client_addr,b.client_port,b.application_name
  FROM pg_locks a,pg_stat_activity b WHERE a.pid=b.pid AND a.granted
),
t_overlap AS (
  SELECT r.* FROM t_wait w JOIN t_run r ON
  (
    r.locktype IS NOT DISTINCT FROM w.locktype AND
    r.database IS NOT DISTINCT FROM w.database AND
    r.relation IS NOT DISTINCT FROM w.relation AND
    r.page IS NOT DISTINCT FROM w.page AND
    r.tuple IS NOT DISTINCT FROM w.tuple AND
    r.virtualxid IS NOT DISTINCT FROM w.virtualxid AND
    r.transactionid IS NOT DISTINCT FROM w.transactionid AND
    r.classid IS NOT DISTINCT FROM w.classid AND
    r.objid IS NOT DISTINCT FROM w.objid AND
    r.objsubid IS NOT DISTINCT FROM w.objsubid AND
    r.pid <> w.pid
  )
),
t_unionall AS (
  SELECT r.* FROM t_overlap r
  UNION ALL
  SELECT w.* FROM t_wait w
)
SELECT 
  'Lock Type: ' || COALESCE(locktype::text, 'NULL') || E'\n' ||
  'Database: ' || COALESCE(datname::text, 'NULL') || E'\n' ||
  'Relation: ' || COALESCE(relation::regclass::text, 'NULL') || E'\n' ||
  'Page: ' || COALESCE(page::text, 'NULL') || E'\n' ||
  'Tuple: ' || COALESCE(tuple::text, 'NULL') || E'\n' ||
  'VirtualXID: ' || COALESCE(virtualxid::text, 'NULL') || E'\n' ||
  'TransactionID: ' || COALESCE(transactionid::text, 'NULL') || E'\n' ||
  'ClassID: ' || COALESCE(classid::regclass::text, 'NULL') || E'\n' ||
  'ObjID: ' || COALESCE(objid::text, 'NULL') || E'\n' ||
  'ObjSubID: ' || COALESCE(objsubid::text, 'NULL') || E'\n' ||
  E'\nLock Holders/Waiters:\n' || 
  string_agg(
    'PID: ' || COALESCE(pid::text, 'NULL') || E'\n' ||
    'Lock Granted: ' || COALESCE(granted::text, 'NULL') || ' , Mode: ' || COALESCE(mode::text, 'NULL') || ' , FastPath: ' || COALESCE(fastpath::text, 'NULL') || E'\n' ||
    'VirtualTransaction: ' || COALESCE(virtualtransaction::text, 'NULL') || ' , State: ' || COALESCE(state::text, 'NULL') || E'\n' ||
    'User: ' || COALESCE(usename::text, 'NULL') || ' , Client: ' || COALESCE(client_addr::text, 'NULL') || ':' || COALESCE(client_port::text, 'NULL') || E'\n' ||
    'Application: ' || COALESCE(application_name::text, 'NULL') || E'\n' ||
    'Xact Start: ' || COALESCE(xact_start::text, 'NULL') || ' , Query Start: ' || COALESCE(query_start::text, 'NULL') || E'\n' ||
    'Xact Duration: ' || COALESCE((now()-xact_start)::text, 'NULL') || ' , Query Duration: ' || COALESCE((now()-query_start)::text, 'NULL') || E'\n' ||
    'Query: ' || E'\n' || COALESCE(substr(regexp_replace(regexp_replace(query, E'[\\n\\r]+', ' ', 'g'), ' ',''), 1, 100), 'NULL') || E'\n' ||
    E'\n----------------------------------------\n',
    E'\n' ORDER BY 
    (CASE mode
      WHEN 'INVALID' THEN 0
      WHEN 'AccessShareLock' THEN 1
      WHEN 'RowShareLock' THEN 2
      WHEN 'RowExclusiveLock' THEN 3
      WHEN 'ShareUpdateExclusiveLock' THEN 4
      WHEN 'ShareLock' THEN 5
      WHEN 'ShareRowExclusiveLock' THEN 6
      WHEN 'ExclusiveLock' THEN 7
      WHEN 'AccessExclusiveLock' THEN 8
      ELSE 0
    END) DESC,
    (CASE WHEN granted THEN 0 ELSE 1 END)
  ) AS lock_conflict
FROM t_unionall
GROUP BY locktype,datname,relation,page,tuple,virtualxid,transactionid::text,classid,objid,objsubid;
EOF
}
