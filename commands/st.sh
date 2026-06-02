#!/bin/bash
# Command: st - display dict table or view

st_help() {
    echo "Options for st:"
    echo "  Usage: vb_tool st [relname]"
    echo "  Description: display dict table or view"
    echo ""
}

run_st() {
    local param="$1"
    if [ -z "$param" ]; then
        echo "Error: st relname" >&2
        st_help
        exit 1
    fi
    
    psql -d postgres <<EOF
\pset footer off
\set name '$param'
\echo '=========================='
\echo 'show table/view from st   '
\echo '=========================='
SELECT n.nspname AS "Schema",c.relname,decode(c.relkind,'r','table','v','view') as type FROM pg_class c join pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE c.relname LIKE '%' || :'name' || '%' and c.relkind in ('r','v');
EOF
}

run_tabsize(){
while getopts "a:d:s:t:n:" opt; do
  case $opt in
    a) all="$OPTARG" ;;
    d) dbname="$OPTARG" ;;
    s) schemaname="$OPTARG" ;;
    t) tablename="$OPTARG" ;;
    n) number="$OPTARG" ;;
    *) echo "Usage: $0 -a all -d dbname -s schemaname -t tablename -n number" && exit 1 ;;
  esac
done

dbcondition="AND 1=1"
schemacondition="AND 1=1"
tablecondition="AND 1=1"

if [ -z "$number" ]; then
   echo "错误: 必需的选项 -n 未提供。"
   echo "-n number, e.g:-n 5"
   exit 1 # 非零退出码表示错误
fi

# 检查是否传入参数
if [ -n "$dbname" ]; then
    dbcondition="AND D.datname='${dbname}'"
fi

if [ -n "$all" ]; then
    dbname="postgres"
    dbcondition="AND 1=1"
    schemacondition="AND 1=1"
    tablecondition="AND 1=1"
fi

echo "dbname is ${dbname}"

if [ -n "$schemaname" ]; then
    schemacondition="AND N.nspname='${schemaname}'"
fi

if [ -n "$tablename" ]; then
    tablecondition="AND C.relname='${tablename}'"
fi

if [ -n "$number" ]; then
    number=${number}
fi

cat <<EOF > /tmp/query.sql

select dbname, schemaname, tablename,
pg_size_pretty(table_size) as "table_size",
pg_size_pretty(indexes_size) as "indexes_size", 
pg_size_pretty(toast_size) as "toast_size", 
pg_size_pretty(toast_indexes_size) as "toast_indexes_size",
pg_size_pretty(total_size) AS "total_size"
from 
(
SELECT
    D.datname as "dbname",
    N.nspname as "schemaname",
    C.relname AS "tablename",
    case when exists(select inhparent from pg_inherits where C.oid=inhparent)
    then
    (
    select pg_table_size(C.oid)+sum(pg_table_size(t.partition_name::regclass)) 
    from 
      (
        SELECT
           c.relname AS partition_name
        FROM
             pg_inherits i
        JOIN
             pg_class c ON c.oid = i.inhrelid
        JOIN
             pg_class pc ON pc.oid = i.inhparent    
      ) t
    )
    else
    (pg_table_size(C.oid))
    end AS "table_size"    ,
    pg_indexes_size(C.oid) as "indexes_size",   
    pg_table_size(C.reltoastrelid) as "toast_size",
    pg_indexes_size(C.reltoastrelid) as "toast_indexes_size",
    case when exists(select inhparent from pg_inherits where C.oid=inhparent)
    then
    (
    select pg_total_relation_size(C.oid)+sum(pg_total_relation_size(t.partition_name::regclass)) 
    from 
      (
        SELECT
           c.relname AS partition_name
        FROM
             pg_inherits i
        JOIN
             pg_class c ON c.oid = i.inhrelid
        JOIN
             pg_class pc ON pc.oid = i.inhparent    
      ) t
    )
    else
    (pg_total_relation_size(C.oid))
    end AS "total_size"    
FROM
    pg_class C 
LEFT JOIN
    pg_namespace N ON (N.oid = C.relnamespace)
left join 
    pg_database D on D.datname not in ('template0','template1') 
WHERE
    Not exists(select inhrelid from pg_inherits where C.oid=inhrelid)
    AND nspname NOT IN ('pg_catalog', 'information_schema','snapshot')
    AND C.relkind in ('r','l')
    AND nspname !~ '^pg_toast'    
    ${dbcondition}
    ${schemacondition}
    ${tablecondition}
ORDER BY
    total_size DESC
limit ${number} 
)tt;

EOF

psql -d ${dbname} -f /tmp/query.sql 

}
