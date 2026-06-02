#!/bin/bash
# Command: sp - display guc parameter

sp_help() {
    echo "Options for sp:"
    echo "  Usage: vb_tool sp [guc]"
    echo "  Description: display guc parameter"
    echo ""
}

run_sp() {
    local param="$1"
    if [ -z "$param" ]; then
        echo "Error: sp param" >&2
        sp_help
        exit 1
    fi
    
    psql -d postgres <<EOF
\pset footer off
\set name '$param'
\echo '=========================='
\echo 'show parameter from sp'
\echo '=========================='
SELECT name,decode(unit,'8kB',setting*8||'kB',setting||COALESCE(unit,' ')) setting,context,short_desc FROM pg_settings WHERE name LIKE '%' || :'name' || '%';
EOF
}
