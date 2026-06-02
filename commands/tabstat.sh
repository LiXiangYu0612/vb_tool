#!/bin/bash
# Command: tabstat - display table statistics

tabstat_help() {
    echo "Options for tabstat:"
    echo "  Usage: -d <database> -s <schema> -t <table>"
    echo "  Options:"
    echo "    -d: database name (default: postgres)"
    echo "    -s: schema name (required)"
    echo "    -t: table name (required)"
    echo ""
}

run_tabstat() {
    local db_name=""
    local schema_name=""
    local table_name=""
    

    while getopts ":d:s:t:" opt; do
      case $opt in
        d) db_name="$OPTARG" ;;
        s) schema_name="$OPTARG" ;;
        t) table_name="$OPTARG" ;;
        \?) echo "Invalid option: -$OPTARG" >&2; exit 1 ;;
        :) echo "Option -$OPTARG requires argument" >&2; exit 1 ;;
      esac
    done

    if [ -z "$db_name" ] || [ -z "$schema_name" ] || [ -z "$table_name" ]; then
        echo "Error: -d (database), -s (schema), and -t (table) parameters are required" >&2
        exit 1
    fi
    
psql -d "$db_name" <<EOF
\pset footer off
\set schema '$schema_name'
\set name '$table_name'
\echo '================'
\echo 'table statistics'
\echo '================'
SELECT n.nspname AS "owner"
        ,c.relname AS "tab_name"
        ,CASE c.relpersistence
                WHEN 'p' THEN 'perm'
                WHEN 't' THEN 'temp'
                WHEN 'u' THEN 'unlog'
                END AS "tabtype"
        ,(select CASE p.partstrategy
            WHEN 'r'::"char" THEN 'RANGE'::varchar(9)
            WHEN 'i'::"char" THEN 'INTERVAL'::varchar(9)
            WHEN 'l'::"char" THEN 'LIST'::varchar(9)
            WHEN 'h'::"char" THEN 'HASH'::varchar(9)
            WHEN 'd'::"char" THEN 'HASH'::varchar(9)
            WHEN 'v'::"char" THEN 'VALUE'::varchar(9)
            WHEN 's'::"char" THEN 'SYSTEM'::varchar(9)
            WHEN 'n'::"char" THEN 'NONE'::varchar(9)
         ELSE NULL end from pg_partition p where p.parentid=c.oid limit 1)||(CASE WHEN p2.cols is not null then '('||p2.cols||')' else '' end)||(case when (select CASE p1.partstrategy
            WHEN 'r'::"char" THEN 'RANGE'::varchar(9)
            WHEN 'i'::"char" THEN 'INTERVAL'::varchar(9)
            WHEN 'l'::"char" THEN 'LIST'::varchar(9)
            WHEN 'h'::"char" THEN 'HASH'::varchar(9)
            WHEN 'd'::"char" THEN 'HASH'::varchar(9)
            WHEN 'v'::"char" THEN 'VALUE'::varchar(9)
            WHEN 's'::"char" THEN 'SYSTEM'::varchar(9)
            WHEN 'n'::"char" THEN 'NONE'::varchar(9)
         ELSE NULL end from pg_partition p,pg_partition p1 where p.parentid=c.oid and p1.parentid=p.oid limit 1) is not null then '-'||(select CASE p1.partstrategy
            WHEN 'r'::"char" THEN 'RANGE'::varchar(9)
            WHEN 'i'::"char" THEN 'INTERVAL'::varchar(9)
            WHEN 'l'::"char" THEN 'LIST'::varchar(9)
            WHEN 'h'::"char" THEN 'HASH'::varchar(9)
            WHEN 'd'::"char" THEN 'HASH'::varchar(9)
            WHEN 'v'::"char" THEN 'VALUE'::varchar(9)
            WHEN 's'::"char" THEN 'SYSTEM'::varchar(9)
            WHEN 'n'::"char" THEN 'NONE'::varchar(9)
         ELSE NULL end from pg_partition p,pg_partition p1 where p.parentid=c.oid and p1.parentid=p.oid limit 1)||'('||p1.cols||')' else '' end) parttype
        ,c.relpages
        ,c.reltuples
        ,c.relallvisible allvisible
        ,pg_catalog.pg_size_pretty(pg_catalog.pg_table_size(c.oid)) AS "size"
        ,replace(replace(replace(c.reloptions::text,'orientation','ori'),'compression','comp'),'fillfactor','fill') as options
FROM pg_catalog.pg_class c
LEFT JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN  (select lower(schema_name) schema_name,lower(name) as name,lower(string_agg(column_name,',' order by column_position)) cols  from dba_subpart_key_columns 
 where object_type='TABLE' and lower(schema_name)= :'schema' and lower(name) in (:'name')
  group by schema_name,name)  p1 ON c.relname=p1.name and p1.schema_name=n.nspname 
LEFT JOIN  (select lower(schema_name) schema_name,lower(name) as name,lower(string_agg(column_name,',' order by column_position)) cols  from dba_part_key_columns 
 where object_type='TABLE' and lower(schema_name)= :'schema' and lower(name) in (:'name')
  group by schema_name,name) p2 ON c.relname=p2.name and p2.schema_name=n.nspname 
WHERE c.relkind IN ('r','p','v','m','S','f','')
        AND n.nspname <> 'pg_catalog'
        AND n.nspname !~ '^pg_toast'
        AND n.nspname <> 'information_schema'
        AND c.relname in (:'name')
        AND n.nspname = :'schema';

\echo '                           '
select relname,n_tup_ins,n_tup_upd,n_tup_del,n_tup_hot_upd,n_live_tup,n_dead_tup,to_char(last_vacuum,'yyyy-mm-dd hh24:mi:ss') last_vacuum,to_char(last_analyze,'yyyy-mm-dd hh24:mi:ss') last_analyze from pg_stat_all_tables where relname in (:'name') and schemaname = :'schema';

\echo '================'
\echo 'index statistics'
\echo '================'
SELECT n.nspname AS "ind_owner"
        ,c2.relname AS "tab_name"
        ,c.relname AS "ind_name"
        ,replace(am.amname||' '||decode(i.indisunique,'t','unique')||' '||CASE WHEN c.relkind = 'i' and pg_catalog.pg_get_indexdef(i.indexrelid, 0, true) ~ '\)\s*LOCAL' then 'local'
              WHEN c.relkind = 'I' then 'global'
         ELSE NULL END,'  ',' ')  ind_type
        ,decode(i.indisusable,'t','usable','unusable') status
        ,lower(REGEXP_REPLACE(TRIM(BOTH FROM SUBSTRING(pg_catalog.pg_get_indexdef(i.indexrelid, 0, true) FROM 'USING\s+\w+\s+\(((?:[^()]+|\([^()]*\))*)\)')),
    '(,|^)\s*([^,]+?)(?<!DESC)(?<!ASC)\b\s*(DESC|ASC)\b', 
    '\1\2', 
    'gi'
)) col_list
        ,c.relpages
        ,c.reltuples
        ,pg_catalog.pg_size_pretty(pg_catalog.pg_table_size(c.oid)) AS "Size"
FROM pg_catalog.pg_class c
LEFT JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_catalog.pg_am am ON am.oid = c.relam
LEFT JOIN pg_catalog.pg_index i ON i.indexrelid = c.oid
LEFT JOIN pg_catalog.pg_class c2 ON i.indrelid = c2.oid
LEFT JOIN pg_catalog.pg_namespace n1 ON n1.oid = c2.relnamespace
WHERE c.relkind IN ('i','I','')
        AND n.nspname <> 'pg_catalog'
        AND n.nspname !~ '^pg_toast'
        AND n.nspname <> 'information_schema'
        AND c2.relname in (:'name')
        AND n1.nspname = :'schema'
       -- AND pg_catalog.pg_table_is_visible(c.oid) 
		order by 1,2;

\echo '                                  '
select schemaname,relname tab_name,indexrelname index_name,idx_scan,idx_tup_read,idx_tup_fetch from pg_stat_all_indexes where schemaname =:'schema' and relname in (:'name') order by 1,2;

\echo '================='
\echo 'column statistics'
\echo '================='
SELECT   
    relname tab_name,
    t.attname col_name,
    CASE 
        WHEN t.type LIKE '%without time zone%' THEN replace(t.type, ' without time zone', '')
        WHEN t.type LIKE '%with time zone%' THEN replace(replace(t.type, ' with time zone', ''), 'timestamp', 'timestamptz')
        ELSE t.type 
    END AS type,
    decode(attstorage, 'p', 'plain', 'e', 'external', 'm', 'main', 'x', 'extended') attstorage,
    decode(attnotnull, 'true', 'not null', round(null_frac, 5)) nullfreq,
    avg_width,
    round(n_distinct, 5) n_dist,
    round(correlation, 5) corr,
    top3_freqs
FROM (
    SELECT  
        c.relname,
        a.attname,
        a.attnum,
        pg_catalog.format_type(a.atttypid, a.atttypmod) as type,
        a.attnotnull,
        b.null_frac,
        b.avg_width,
        b.n_distinct,
        b.correlation,
        a.attstorage
    FROM pg_catalog.pg_attribute a
    JOIN pg_class c ON a.attrelid = c.oid 
    JOIN pg_catalog.pg_namespace d ON c.relnamespace = d.oid
    LEFT JOIN pg_catalog.pg_stats b ON a.attname = b.attname 
        AND c.relname = b.tablename 
        AND b.schemaname = d.nspname
    WHERE a.attrelid = c.oid
        AND a.attnum > 0
        AND NOT a.attisdropped
        AND d.nspname = :'schema'
        AND c.relname in (:'name')
    ORDER BY a.attnum
) t
LEFT JOIN (
    SELECT 
        tablename,
        attname,
        CONCAT(
            CASE WHEN split_part(val_string, '|', 1)  is not null  and split_part(val_string, '|', 1) is distinct from ''
                 THEN split_part(val_string, '|', 1) || '(' || 
                      COALESCE(split_part(freq_string, '|', 1)::NUMERIC::TEXT, '0') || ')'
                 ELSE '' 
            END,
            CASE WHEN split_part(val_string, '|', 2)  is not null  and split_part(val_string, '|', 2) is distinct from ''
                 THEN CHR(10) || split_part(val_string, '|', 2) || '(' || 
                      COALESCE(split_part(freq_string, '|', 2)::NUMERIC::TEXT, '0') || ')'
                 ELSE '' 
            END,
            CASE WHEN split_part(val_string, '|', 3)  is not null  and split_part(val_string, '|', 3) is distinct from ''
                 THEN CHR(10) || split_part(val_string, '|', 3) || '(' || 
                      COALESCE(split_part(freq_string, '|', 3)::NUMERIC::TEXT, '0') || ')'
                 ELSE '' 
            END
        ) AS top3_freqs
    FROM (
        SELECT 
            tablename,
            attname,
            array_to_string(most_common_vals, '|') AS val_string,
            array_to_string(most_common_freqs, '|') AS freq_string
        FROM pg_stats
        WHERE tablename in (:'name')
            AND schemaname = :'schema' 
            AND most_common_freqs IS NOT NULL
    ) t2
) t1 ON t.attname = t1.attname AND t.relname = t1.tablename 
ORDER BY 1, attnum;





\echo '===================='
\echo 'partition statistics'
\echo '===================='
select n.nspname schema_name,c.relname tab_name,partitionno partno,p.relname part_name,CASE p.partstrategy
            WHEN 'r'::"char" THEN 'RANGE'::varchar(9)
            WHEN 'i'::"char" THEN 'INTERVAL'::varchar(9)
            WHEN 'l'::"char" THEN 'LIST'::varchar(9)
            WHEN 'h'::"char" THEN 'HASH'::varchar(9)
            WHEN 'd'::"char" THEN 'HASH'::varchar(9)
            WHEN 'v'::"char" THEN 'VALUE'::varchar(9)
            WHEN 's'::"char" THEN 'SYSTEM'::varchar(9)
            WHEN 'n'::"char" THEN 'NONE'::varchar(9)
         ELSE NULL end parttype,cols partkey,p.relpages,p.reltuples,pg_size_pretty(pg_partition_size(p.parentid,p.oid)) as size,boundaries from pg_partition p,pg_class c,(select lower(schema_name) schema_name,lower(name) as name,lower(string_agg(column_name,',' order by column_position)) cols  from dba_part_key_columns 
 where object_type='TABLE' 
  group by schema_name,name) p1,pg_namespace n
where p.parttype in ('p') and c.oid=p.parentid and p.subpartitionno is null and p1.name=c.relname and n.oid = c.relnamespace and p1.schema_name=n.nspname 
  and   c.relname in (:'name')
  and n.nspname = :'schema' order by 1,2,3; 

\echo '======================='
\echo 'subpartition statistics'
\echo '======================='
select c.relname tab_name,p.relname part_name,ps.relname subpart_name,CASE p.partstrategy
            WHEN 'r'::"char" THEN 'RANGE'::varchar(9)
            WHEN 'i'::"char" THEN 'INTERVAL'::varchar(9)
            WHEN 'l'::"char" THEN 'LIST'::varchar(9)
            WHEN 'h'::"char" THEN 'HASH'::varchar(9)
            WHEN 'd'::"char" THEN 'HASH'::varchar(9)
            WHEN 'v'::"char" THEN 'VALUE'::varchar(9)
            WHEN 's'::"char" THEN 'SYSTEM'::varchar(9)
            WHEN 'n'::"char" THEN 'NONE'::varchar(9)
         ELSE NULL end||'('||p1.cols||')-'||CASE ps.partstrategy
            WHEN 'r'::"char" THEN 'RANGE'::varchar(9)
            WHEN 'i'::"char" THEN 'INTERVAL'::varchar(9)
            WHEN 'l'::"char" THEN 'LIST'::varchar(9)
            WHEN 'h'::"char" THEN 'HASH'::varchar(9)
            WHEN 'd'::"char" THEN 'HASH'::varchar(9)
            WHEN 'v'::"char" THEN 'VALUE'::varchar(9)
            WHEN 's'::"char" THEN 'SYSTEM'::varchar(9)
            WHEN 'n'::"char" THEN 'NONE'::varchar(9)
         ELSE NULL end ||'('||p2.cols||')' part_type
         ,ps.relpages,ps.reltuples,pg_size_pretty(pg_partition_size(ps.parentid,ps.oid)) as size,p.boundaries partbound,ps.boundaries subpartbound
 from pg_partition p,pg_partition ps,pg_class c,pg_namespace n,(select lower(schema_name) schema_name,lower(name) as name,lower(string_agg(column_name,',' order by column_position)) cols  from dba_part_key_columns
 where object_type='TABLE' group by schema_name,name) p1,
  (select lower(schema_name) schema_name,lower(name) as name,lower(string_agg(column_name,',' order by column_position)) cols  from dba_subpart_key_columns
 where object_type='TABLE' group by schema_name,name) p2
where (p.parttype='s' or (p.parttype='p' and p.subpartitionno is not null)) and c.oid=p.parentid and  c.relname =p1.name and n.oid = c.relnamespace and p1.schema_name=n.nspname
  and ps.parentid=p.oid 
  and   c.relname in (:'name')
  and n.nspname = :'schema' order by 1,2,3; 

\echo '==================='
\echo 'extended statistics'
\echo '==================='
SELECT a.schemaname as owner
        ,a.tablename tab_name
        ,a.attname
        ,null_frac
        ,a.attname
        ,avg_width
        ,n_distinct
        ,n_dndistinct
        ,top3_freqs
FROM (
        SELECT schemaname
                ,tablename
                ,attname
                ,null_frac
                ,avg_width
                ,n_distinct
                ,n_dndistinct
        FROM pg_catalog.pg_ext_stats
        WHERE tablename in (:'name')
                AND schemaname = :'schema'
        ) a
LEFT JOIN (
        SELECT tablename,attname
                ,string_agg(top3_freq::TEXT, ',' ORDER BY top3_freq DESC) top3_freqs
        FROM (
                SELECT tablename,attname
                        ,round(UNNEST(most_common_freqs)::DECIMAL, 4) top3_freq
                        ,row_number() OVER (PARTITION BY tablename,attname ORDER BY round(UNNEST(most_common_freqs)::DECIMAL, 4) DESC) rn
                FROM pg_catalog.pg_ext_stats
                WHERE tablename in (:'name')
                        AND schemaname = :'schema'
                ) d
        WHERE rn <= 3
        GROUP BY attname,tablename
        ) b ON a.attname = b.attname and b.tablename=a.tablename;
EOF
}
