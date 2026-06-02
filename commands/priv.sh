#!/bin/bash
# Command: priv - display privileges for users/tables/databases/schemas

priv_help() {
    echo "Options for priv:"
    echo "  Usage: [-u <user>] [-d <database>] [-s <schema>] [-t <table>]"
    echo "  Options:"
    echo "    -u: user name"
    echo "    -d: database name"
    echo "    -s: schema name"
    echo "    -t: table name"
    echo ""
}

run_show_privilege() {
    local user_param=""
    local table_param=""
    local db_param=""
    local schema_param=""

    while getopts ":u:d:s:t:" opt; do
      case $opt in
        u) user_param="$OPTARG" ;;
        d) db_param="$OPTARG" ;;
        s) schema_param="$OPTARG" ;;
        t) table_param="$OPTARG" ;;
        \?) echo "Invalid option: -$OPTARG" >&2; exit 1 ;;
        :) echo "Option -$OPTARG requires argument" >&2; exit 1 ;;
      esac
    done

    if [ -z "$db_param" ]; then
        echo "Error: -d parameters required" >&2
        priv_help
        exit 1
    fi

    psql -d "$db_param" <<EOF
\pset footer off
\pset tuples_only on
$(
    [ -n "$user_param" ] && echo "\\set _user '$user_param'"
    [ -n "$table_param" ] && echo "\\set _table '$table_param'"
    [ -n "$db_param" ] && echo "\\set _db '$db_param'"
    [ -n "$schema_param" ] && echo "\\set _schema '$schema_param'"
)

$([ -n "$user_param" ] && cat <<'USER_PRIVS'
SELECT  'ALTER ROLE ' || quote_ident(rolname) || ' ' ||    
    CASE WHEN rolsuper THEN 'SUPERUSER ' ELSE 'NOSUPERUSER ' END ||
    CASE WHEN rolinherit THEN 'INHERIT ' ELSE 'NOINHERIT ' END ||
    CASE WHEN rolcreaterole THEN 'CREATEROLE ' ELSE 'NOCREATEROLE ' END ||
    CASE WHEN rolcreatedb THEN 'CREATEDB ' ELSE 'NOCREATEDB ' END ||
    CASE WHEN rolcanlogin THEN 'LOGIN ' ELSE 'NOLOGIN ' END ||
    CASE WHEN rolreplication THEN 'REPLICATION ' ELSE 'NOREPLICATION ' END ||
    CASE WHEN rolconnlimit >= 0 THEN 'CONNECTION LIMIT ' || rolconnlimit || ' ' ELSE '' END ||
    CASE WHEN rolvaliduntil IS NOT NULL THEN 'VALID UNTIL ' || quote_literal(rolvaliduntil::text) ELSE '' END || ';'     
    AS show_privilege 
FROM pg_roles 
WHERE rolname = :'_user' 
UNION ALL 
SELECT     
    'GRANT "' || pg_get_userbyid(roleid) || '" TO "' || pg_get_userbyid(member) || '"' ||
    (case when admin_option='t' then ' WITH ADMIN OPTION' else '' end)||
    ' GRANTED BY '||pg_get_userbyid(grantor)||';'  
    as show_privilege  
FROM pg_auth_members   
WHERE pg_get_userbyid(member)= :'_user'  
UNION ALL   
(WITH def AS (
    SELECT nsp.nspname,pda.*,(aclexplode(defaclacl)).*    
    FROM pg_default_acl pda  
    LEFT JOIN pg_namespace nsp ON pda.defaclnamespace = nsp.oid  
)  
SELECT       
    'ALTER DEFAULT PRIVILEGES ' ||
    (CASE WHEN nspname IS NOT NULL 
          THEN 'IN SCHEMA "' || nspname|| '" ' 
         ELSE '' 
    END) ||
    'FOR ROLE ' || pg_get_userbyid(def.defaclrole) || ' ' ||
    'GRANT ' || string_agg(def.privilege_type, ', ') || ' ' ||
    'ON ' || 
    CASE def.defaclobjtype 
        WHEN 'r' THEN 'TABLES' 
        WHEN 'S' THEN 'SEQUENCES' 
        WHEN 'f' THEN 'FUNCTIONS' 
        WHEN 'T' THEN 'TYPES' 
    END || ' TO ' || pg_get_userbyid(def.grantee) || ';'  
    as show_privilege  
FROM def  
WHERE pg_get_userbyid(def.grantee)= :'_user'  
GROUP BY nspname,defaclrole,defaclnamespace,defaclobjtype,defaclacl,grantor,grantee,is_grantable);
USER_PRIVS
)

$([ -n "$table_param" ] && cat <<'TABLE_PRIVS'
SELECT 'GRANT ' || privilege_type || ' ON TABLE "' || table_schema || '"."' || table_name || '" TO "' || grantee || 
    (case when is_grantable ='YES' then '" WITH GRANT OPTION' else '"' end)  || ';'  
    as show_privilege  
FROM information_schema.table_privileges   
WHERE table_name= :'_table';
TABLE_PRIVS
)

$([ -n "$db_param" ] && cat <<'DB_PRIVS'
SELECT 'GRANT ' || string_agg(privilege_type,',') || ' ON DATABASE "' || datname || '" TO "' || 
    (case when grantee=0 then 'PUBLIC' else pg_get_userbyid(grantee) end)|| '"' ||
    (CASE WHEN is_grantable = 'YES' THEN ' WITH GRANT OPTION;' ELSE ';' END)  
    as show_privilege  
FROM (
    SELECT datname, (aclexplode(datacl)).*  
    FROM pg_database  
) AS db_acl  
WHERE datname = :'_db'  
GROUP BY datname,grantor,grantee,is_grantable;
DB_PRIVS
)

$([ -n "$schema_param" ] && cat <<'SCHEMA_PRIVS'
SELECT 'GRANT ' || string_agg(privilege_type,',') || ' ON SCHEMA "' || nspname || '" TO "' || 
    (case when grantee=0 then 'PUBLIC' else pg_get_userbyid(grantee) end)|| '"' ||
    (CASE WHEN is_grantable = 'YES' THEN ' WITH GRANT OPTION;' ELSE ';' END)  
    as show_privilege  
FROM (
    SELECT nspname,(aclexplode(nspacl)).* 
    FROM pg_namespace   
) AS nsp_acl  
WHERE nspname= :'_schema' 
GROUP BY nspname,grantor,grantee,is_grantable  
UNION ALL   
(WITH def AS (
    SELECT nsp.nspname,pda.*,(aclexplode(defaclacl)).*    
    FROM pg_default_acl pda  
    LEFT JOIN pg_namespace nsp ON pda.defaclnamespace = nsp.oid  
    WHERE nsp.nspname= :'_schema'  
)  
SELECT       
    'ALTER DEFAULT PRIVILEGES IN SCHEMA "' || nspname||'" '||
    'FOR ROLE ' || pg_get_userbyid(def.defaclrole) || ' ' ||
    'GRANT ' || string_agg(def.privilege_type, ', ') || ' ' ||
    'ON ' || 
    (CASE def.defaclobjtype 
        WHEN 'r' THEN 'TABLES' 
        WHEN 'S' THEN 'SEQUENCES' 
        WHEN 'f' THEN 'FUNCTIONS' 
        WHEN 'T' THEN 'TYPES' 
    END) || ' TO ' || (case when grantee=0 then 'PUBLIC' else pg_get_userbyid(def.grantee) end) || ';'  
    as show_privilege  
FROM def  
GROUP BY nspname,defaclrole,defaclnamespace,defaclobjtype,defaclacl,grantor,grantee,is_grantable);
SCHEMA_PRIVS
)
EOF
}
