#!/bin/bash
# Command: lockchain - display lock wait chain

lockchain_help() {
    echo "Options for lockchain:"
    echo "  Usage: None"
    echo "  Description: display lock wait chain"
    echo ""
}

run_lockchain() {
    psql -d postgres <<EOF
\pset footer off
\echo '=========================='
\echo 'lock chain analysis'
\echo '=========================='
WITH RECURSIVE l AS (
  SELECT sessionid, locktype, granted, virtualtransaction,
    ROW(locktype,database,relation,page,tuple,virtualxid,transactionid,classid,objid,objsubid) obj
  FROM pg_locks
), pairs AS (
  SELECT DISTINCT w.sessionid waiter, l.sessionid locker, l.obj::text
  FROM l w
  JOIN l ON l.obj IS NOT DISTINCT FROM w.obj AND l.locktype=w.locktype 
        AND NOT l.sessionid=w.sessionid AND l.granted
  WHERE NOT w.granted
), tree AS (
  SELECT l.locker sessionid, l.locker root, NULL::text obj, 0 lvl, 
         locker::text w_chain, array_agg(l.locker) OVER () all_pids
  FROM ( SELECT DISTINCT locker FROM pairs l WHERE NOT EXISTS (SELECT 1 FROM pairs WHERE waiter=l.locker) ) l
  UNION ALL
  SELECT w.waiter, tree.root, w.obj, tree.lvl+1, 
         tree.w_chain||'.'||w.waiter, all_pids || array_agg(w.waiter) OVER ()
  FROM tree JOIN pairs w ON tree.sessionid=w.locker AND NOT w.waiter = ANY (all_pids)
)
SELECT
  (clock_timestamp() - COALESCE(a.xact_start, px.prepared))::interval(3) AS ts_age,
  COALESCE(replace(a.state, 'idle in transaction', 'idletx'), '2pc') AS state,
  (clock_timestamp() - COALESCE(a.state_change, px.prepared))::interval(3) AS change_age,
  COALESCE(a.datname, px.database) AS datname,
  tree.sessionid,
  COALESCE(a.usename, px.owner) AS usename,
  a.client_addr,
  lvl,
  (SELECT virtualtransaction FROM pg_locks WHERE sessionid=tree.sessionid AND granted LIMIT 1) AS virtualtransaction,
  (SELECT count(*) FROM tree p WHERE p.w_chain ~ ('^'||tree.w_chain) AND NOT p.w_chain=tree.w_chain) blocked,
  COALESCE(
    substr(REGEXP_REPLACE(REGEXP_REPLACE(a.query, '(\r|\n)+', ' '),' {2,}', ' '), 1, 50),
    '[prepared xact] ' || px.gid
  ) AS query
FROM tree
LEFT JOIN pg_stat_activity a ON a.sessionid = tree.sessionid
LEFT JOIN pg_prepared_xacts px
  ON a.sessionid IS NULL
  AND split_part(
        (SELECT virtualtransaction FROM pg_locks WHERE sessionid=tree.sessionid AND granted LIMIT 1),
        '/', 2
      ) = px.transaction::text
ORDER BY w_chain;
EOF
}
