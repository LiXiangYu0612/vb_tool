#!/bin/bash
# Command: relxlog - analyze WAL records for relations

relxlog_help() {
    echo "Options for relxlog:"
    echo "  Usage: [START_WAL] [END_WAL]"
    echo "  Description: analyze WAL records for relations"
    echo ""
}

run_relxlog() {
    
    start_wal="$1"
    end_wal="$2"
    local wal_dir="${3:-${PGDATA}/pg_xlog}"
	
    if [ -z "$start_wal" ] || [ -z "$end_wal" ]; then
        echo "Error: Missing required parameters" >&2
        echo "Usage: vb_tool relxlog <start_wal> <end_wal>" >&2
        echo "Example: vb_tool relxlog 000000010000000800000042 00000001000000080000004C" >&2
        exit 1
    fi
    
    pg_xlogdump -p $wal_dir "$start_wal" "$end_wal" |
    awk '/REDO/{
        type=$19" - "$21;
        size=$15;
        gsub($15,";","");
        type_cnt[type]++;
        type_size[type]+=size;
        total_size+=size;
        total_entries++;
        if($0 ~ " rel ") {
            if($30=="rel"){
                rel=$31;
            }
            if($27=="rel"){
                rel=$28;
            }
            rel_cnt[rel]++;
            rel_size[rel]+=size;
            rel_total_size+=size;
        }
    }
    END{
            PROCINFO["sorted_in"]="@val_num_desc"
            printf("%12s %12s %8s %-50s \n","RedoSize(k)","RedoEntries","%Size","Type")
            cnt=0;
            for (type in type_size) {
                if (++cnt > 30) break;
                printf("%12.1f %12d %7.1f%% %-50s\n", 
                       type_size[type]/1024,
                       type_cnt[type],
                       (type_size[type]/total_size)*100,
                       type);
            }
            
            FS="/"
            printf("\n\n%12s %12s %8s %-10s %-10s\n","RedoSize(k)","RedoEntries","%Size","DBID","RelID")
            cnt=0;
            for (rel in rel_size) {
                if (++cnt > 30) break;
                $0=rel;
                printf("%12.1f %12d %7.1f%% %-10s %-10s\n",
                       rel_size[rel]/1024,
                       rel_cnt[rel],
                       (rel_size[rel]/rel_total_size)*100,
                       $2,$3);
            };
    }'
}
