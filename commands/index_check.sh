#!/bin/bash
# Command: index_check - display redundant/unused/unusable/novalid index

redundant_index_help() {
    echo "Options for redundant_index:"
    echo "  Usage: [OPTIONS]"
    echo "  Options:"
    echo "    -d: database name"
    echo ""
}

run_redundant_index() {
    if [ $# -eq 0 ]; then
        redundant_index_help
        return 1
    fi

    local db_name=""
    while getopts ":d:" opt; do
      case $opt in
        d) db_name="$OPTARG" ;;
        \?) echo "Invalid option: -$OPTARG" >&2; exit 1 ;;
        :) echo "Option -$OPTARG requires argument" >&2; exit 1 ;;
      esac
    done

    if [ -z "$db_name" ] ; then
        echo "Error: -d (database) parameters are required" >&2
        exit 1
    fi
    
psql -d "$db_name" <<EOF
\pset footer off
\echo '===================='
\echo 'redundant index list'
\echo '===================='
WITH aa AS (
    SELECT 
        n.nspname AS "ind_owner",
        n1.nspname as tab_schema,
        c2.relname AS "tab_name",
        c.relname AS "ind_name",
        decode(i.indisusable,'t','usable','unusable') status,
        case when i.indisprimary='t' then 1 else 0 end AS is_primary,
        REGEXP_REPLACE(
            TRIM(BOTH FROM 
                SUBSTRING(
                    pg_catalog.pg_get_indexdef(i.indexrelid, 0, true) 
                    FROM 'USING\s+\w+\s+\(((?:[^()]+|\([^()]*\))*)\)'
                )
            ),
            '(,|^)\s*([^,]+?)\s+(DESC|ASC)\b', 
            '\1\2', 
            'gi'
        ) AS col_list,
        length(REGEXP_REPLACE(
            TRIM(BOTH FROM 
                SUBSTRING(
                    pg_catalog.pg_get_indexdef(i.indexrelid, 0, true) 
                    FROM 'USING\s+\w+\s+\(((?:[^()]+|\([^()]*\))*)\)'
                )
            ),
            '(,|^)\s*([^,]+?)\s+(DESC|ASC)\b', 
            '\1\2', 
            'gi'
        )) - length(replace(REGEXP_REPLACE(
            TRIM(BOTH FROM 
                SUBSTRING(
                    pg_catalog.pg_get_indexdef(i.indexrelid, 0, true) 
                    FROM 'USING\s+\w+\s+\(((?:[^()]+|\([^()]*\))*)\)'
                )
            ),
            '(,|^)\s*([^,]+?)\s+(DESC|ASC)\b', 
            '\1\2', 
            'gi'
        ), ',', '')) + 1 AS col_count
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
),
bb as (select * from (
select ind_owner,tab_schema,tab_name,ind_name,col_list,col_count,row_number()over(partition by tab_schema,tab_name,col_list order by is_primary desc,ind_name) rn from aa where status='usable') where rn=1)
select tab_schema,tab_name,ind_name,col_list,redundant_ind,redundant_ind_cols from (
SELECT 
    a1.tab_schema,a1.tab_name,
    a2.ind_name AS ind_name,
    a2.col_list AS ind_cols,
    a1.ind_name AS redundant_ind,
    a1.col_list AS redundant_ind_cols,a2.col_list,a1.col_count,row_number()over(partition by a1.tab_schema,a1.tab_name,a1.ind_name order by a2.col_count desc) rn
FROM aa a1,bb a2
where 
    a1.tab_schema = a2.tab_schema
    AND a1.tab_name = a2.tab_name
    AND a1.ind_name <> a2.ind_name
    AND a1.col_count <= a2.col_count
    AND (a2.col_list LIKE a1.col_list || ',%' or a2.col_list=a1.col_list)) where rn=1 order by 1,2,3;
\echo ''	
\echo '==============================='
\echo 'unusable/unvisiable index list '
\echo '==============================='
 SELECT 
        n1.nspname as tab_schema,
        c2.relname AS tab_name,
        c.relname AS ind_name,
        i.indisusable isusable,
			i.indisvalid isvalid,
			i.indisvisible isvisiable,
        i.indisprimary isprimary,
        REGEXP_REPLACE(
            TRIM(BOTH FROM 
                SUBSTRING(
                    pg_catalog.pg_get_indexdef(i.indexrelid, 0, true) 
                    FROM 'USING\s+\w+\s+\(((?:[^()]+|\([^()]*\))*)\)'
                )
            ),
            '(,|^)\s*([^,]+?)\s+(DESC|ASC)\b', 
            '\1\2', 
            'gi'
        ) AS index_col_list
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
			AND (indisvalid<>'t' or indisusable<>'t' or i.indisvisible<>'t');

\echo ''	
\echo '=================='
\echo 'unused index list '
\echo '=================='
 SELECT 
        n1.nspname as tab_schema,
        c2.relname AS tab_name,
        c.relname AS ind_name,
        REGEXP_REPLACE(
            TRIM(BOTH FROM 
                SUBSTRING(
                    pg_catalog.pg_get_indexdef(i.indexrelid, 0, true) 
						FROM 'USING\s+\w+\s+\(((?:[^()]+|\([^()]*\))*)\)'
                )
            ),
            '(,|^)\s*([^,]+?)\s+(DESC|ASC)\b', 
            '\1\2', 
            'gi'
        ) AS index_col_list
    FROM pg_catalog.pg_class c
    LEFT JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_catalog.pg_am am ON am.oid = c.relam
    LEFT JOIN pg_catalog.pg_index i ON i.indexrelid = c.oid
    LEFT JOIN pg_catalog.pg_class c2 ON i.indrelid = c2.oid
    LEFT JOIN pg_catalog.pg_namespace n1 ON n1.oid = c2.relnamespace
		JOIN pg_stat_user_indexes s on s.indexrelid=i.indexrelid
    WHERE c.relkind IN ('i','I','')
        AND n.nspname <> 'pg_catalog'
			AND idx_scan = 0 
        AND n.nspname !~ '^pg_toast'
        AND n.nspname <> 'information_schema'
			AND (i.indisprimary<>'t' or i.indisunique<>'t')
			AND (indisvalid='t' or indisusable='t' or i.indisvisible='t') 
			AND exists(select 1 from pg_stat_user_tables s1 where s1.relid=relid and s1.seq_scan+idx_scan>100);
EOF
}
