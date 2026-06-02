#!/bin/bash
# Command: analyze_log - Analyze database logs

analyze_log_help() {
    echo "Options for analyze_log:"
    echo "  Usage: -f <file> [-b <begin>] [-e <end>] [-t <type>] [-o <output>]"
    echo "  Options:"
    echo "    -f: log file name (required)"
    echo "    -b: start time (optional)"
    echo "    -e: end time (optional)"
    echo "    -t: analysis type (plan or slow, default: slow)"
    echo "    -o: output format (html, csv, txt, default: html)"
    echo ""
}
run_analyze() {
    # Check if python3 is available
    if ! command -v python3 &> /dev/null; then
        echo "Error: python3 is required for log analysis but not found" >&2
        exit 1
    fi

    # Create a temporary python script
    TEMP_SCRIPT=$(mktemp)
    cat << 'EOF' > "$TEMP_SCRIPT"
#!/usr/bin/env

## author: feilunshuai
## show log_directory;  show log_filename;   show log_line_prefix;
## ALTER SYSTEM SET log_line_prefix = '%m %u %d %r %p %S';   gs_guc set -I all -N all -c "log_line_prefix='%m %u %d %r %p %S'" or  log_line_prefix = '%m %r %d %u [%p]'
### 参数说明
### -f：日志文件名称。
### -b 和 -e：过滤日志的起始和结束时间（可选）。
### -t：分析类型（plan 或 slow），默认是 slow。
### -o：输出格式（csv、txt 或 html），默认是html。   增加 1，3，5 行是<tr bgcolor="lightyellow">  lime ，2，4，6 行是<tr bgcolor="lightblue">  背景颜色    ##  Duration 换行
### python3 analyze_log.py -f postgresql-2024-12-25_000000.log -o html

import re
import sys
import argparse
from itertools import groupby
from statistics import mean
from datetime import datetime
import os
import glob

# Argument parsing
parser = argparse.ArgumentParser(description='Process to get log auto plan')
parser.add_argument('-f', '--file', type=str, help="The input file")
parser.add_argument('-b', '--begin', type=str, help="The input start time")
parser.add_argument('-e', '--end', type=str, help="The input end time")
parser.add_argument('-t', '--type', type=str, help="Analyze type (plan or slow, default: slow)")
parser.add_argument('--encode', type=str,default='utf8', help="file charset,such as gbk,utf8 and so on, default: utf8)")
parser.add_argument('-o', '--output', type=str, choices=['html', 'csv', 'txt'], default='html', help="Output format (default: html)")
parser.add_argument('-v', '--version', action='store_true', help="show version")
args = parser.parse_args()
file_name = args.file


if args.version:
    print("The version is 1.7")
    sys.exit(0)
if not args.version and not args.file:
    print("Error: -f (file) parameter is required when -v is not provided.")
    sys.exit(1)


# Helper function to parse date strings
def parse_datetime(date_str):
    formats = [
        '%Y-%m-%d %H:%M:%S.%f', 
        '%Y-%m-%d %H:%M:%S', 
        '%Y-%m-%d %H:%M', 
        '%Y-%m-%d %H'
    ]
    for fmt in formats:
        try:
            return datetime.strptime(date_str, fmt)
        except ValueError:
            continue
    return None

# Read the log file content
file_list = glob.glob(file_name)
content = ''
for file_path in file_list:
    with open(file_path, "r",encoding=args.encode) as file:
        content += file.read() + '\n'

# Regular expression to split logs by timestamps
pattern = r'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}) '
blocks = re.split(pattern, content)[1:]

# Parse start and end times
start_n = 0
if args.begin:
    v_begin = parse_datetime(args.begin)
    if v_begin < parse_datetime(blocks[0]):
        start_n = 0
    else:
        for i in range(0, len(blocks)-2, 2):
            timestamp1 = parse_datetime(blocks[i])
            timestamp2 = parse_datetime(blocks[i+2])
            if v_begin <= timestamp2 and v_begin >= timestamp1:
                start_n = i
                break

if args.end:
    v_end = parse_datetime(args.end)
    matching_index = -2
    for i in range(len(blocks)-2, -2, -2):
        time_value = parse_datetime(blocks[i])
        if time_value <= v_end:
            matching_index = i
            break
    if matching_index != -2:
        blocks = blocks[:matching_index+2]

# Set the analysis type
e_type = args.type if args.type else 'slow'

# Initialize the list for collecting query details
total_list = []

# Parse logs for nested query plans
def parse_nested(start_n, blocks):
    pattern = r'(\d{1,3}\.){3}\d{1,3}\(\d+\)|[local]'
    for i in range(start_n, len(blocks), 2):
        timestamp = blocks[i]  # 当前时间戳
        timestamp = datetime.strptime(timestamp, '%Y-%m-%d %H:%M:%S.%f')
        log_block = blocks[i + 1]  # 当前时间戳对应的日志块
        

        if "-----NestLevel:" in log_block and "Query Text:" in log_block:
            query_plan_content = re.split(r'Query Text:', log_block, flags=re.IGNORECASE)[1]
            query_plan_before = re.split(r'Query Text:', log_block, flags=re.IGNORECASE)[0]
            v_log_list=re.split(r'\s+',query_plan_before,flags=re.IGNORECASE)
            #user=v_log_list[0]
            IP, database, user =  query_plan_before.split()[:3]  # Capture the user here
            match = re.search(pattern, IP)
            if not match:
                user, database, IP = query_plan_before.split()[:3]
            query_id=v_log_list[4]
            #print(query_id)
            v_plan_list=re.split(r'Name:.*',query_plan_content)
            query_text=v_plan_list[0]
            query_plan=v_plan_list[1]
            #print(f"Timestamp: {timestamp}")
            #print(f"query text: {query_text}")
            #print(f"query plan: {query_plan}")
            #print(f"user: {user}")
            #print(f"database: {database}")
            #print(f"{v_log_list[-2]}")
            duration=None
            for j in range(i+2,len(blocks),2):
                timestamp = blocks[j]
                timestamp = datetime.strptime(timestamp, '%Y-%m-%d %H:%M:%S.%f')
                log_block = blocks[j + 1]
                if v_log_list[-2] in log_block and "duration:" in log_block and query_id in log_block:
                    duration=re.split(r'duration:', log_block, flags=re.IGNORECASE)[1].strip().strip('s')
                    duration=float(duration.strip())
                    #print(f"duration: {duration}")
                    break
            if duration == None:
                #print(len(blocks),i)
                print('***********************************************************************')
                if i+1 <= len(blocks):
                    print('Warning: not found end for:',blocks[i],blocks[i+1])
                else:
                    print('Error: not found end for:',blocks[i])
                continue
            total_list.append({
                'time': timestamp, 
                'qry_text': query_text, 
                'qry_plan': query_plan, 
                'IP': IP, 
                'database': database, 
                'user': user,  # Add user to the log entry
                'duration': duration, 
                'unique_id': ''
            })

# Parse logs for slow queries
def parse_slow_sql(start_n, blocks):
    pattern = r'(\d{1,3}\.){3}\d{1,3}\(\d+\)'
    for i in range(start_n, len(blocks), 2):
        timestamp = parse_datetime(blocks[i])
        log_block = blocks[i + 1]
        if "duration:" in log_block and ("execute " in log_block or "bind " in log_block):
            query_content = re.split(r'execute |duration:|unique id|statement:|bind ', log_block, flags=re.IGNORECASE)
            content0 = query_content[0].split()
            IP, database, user = content0[0], content0[1], content0[2]  # Capture the user here
            match = re.search(pattern, IP)
            if not match:
                user, database, IP = content0[0], content0[1], content0[2]
            duration = float(re.split(r'\s+', query_content[1])[1].strip()) / 1000
            query_text, unique_id = query_content[3], query_content[2]
            if i+3 <= len(blocks):
                v_params = re.split(r'parameters:\s+', blocks[i + 3])[1] if "parameters:" in blocks[i + 3] else ''
            else:
                v_params = ''
            total_list.append({
                'time': timestamp, 
                'qry_text': query_text, 
                'qry_params': v_params, 
                'IP': IP, 
                'database': database, 
                'user': user,  # Add user to the log entry
                'duration': duration, 
                'unique_id': unique_id
            })

# Process logs based on the analysis type
if e_type == 'plan':
    parse_nested(start_n, blocks)
    total_list.sort(key=lambda x: x['qry_text'])
    grouped = {key: list(group) for key, group in groupby(total_list, key=lambda x: x['qry_text'])}
    stats = {}
    for qry_text, group in grouped.items():
        durations = [item['duration'] for item in group]
        times = [item['time'] for item in group]
        stats[qry_text] = {
            'max_duration': max(durations), 
            'min_duration': min(durations), 
            'avg_duration': round(mean(durations),3),
            'sum_duration': round(sum(durations),3),
            'count': len(group),
            'max_times': max(times),
            'min_times': min(times),
            'qry_plan': group[0]['qry_plan'],
            'IP': group[0]['IP'],
            'database': group[0]['database'],
            'user': group[0]['user']  # Include user in the statistics
        }
    sorted_data = sorted(stats.items(), key=lambda x: x[1]['sum_duration'], reverse=True)

    # Generate report based on the output format
    base_filename = os.path.splitext(file_name)[0]
    report_name = f"{base_filename}_query_plan_report"

    if args.output == 'html':
        with open(f"{report_name}.html", "w") as f:
            f.write("<html><body><h1>Query Plan Analysis Report</h1><table border='1' cellpadding='5'><tr><th>Query Text</th><th>Time Range</th><th>IP</th><th>Database</th><th>User</th><th>Query Plan</th><th>Duration (sum/max/min/avg)</th><th>Calls</th></tr>")
            for idx, (qry_text, stat) in enumerate(sorted_data):
                row_color = "lightyellow" if idx % 2 == 0 else "lightblue"
                duration_class = "normal" if stat['avg_duration'] < 2 else "warning" if stat['avg_duration'] < 5 else "critical"
                f.write(f"<tr bgcolor='{row_color}' class='{duration_class}'><td>{qry_text}</td><td>{stat['min_times']} - {stat['max_times']}</td><td>{stat['IP']}</td><td>{stat['database']}</td><td>{stat['user']}</td><td>{stat['qry_plan']}</td><td>{stat['sum_duration']},{stat['max_duration']},{stat['min_duration']},{stat['avg_duration']}</td><td>{stat['count']}</td></tr>")
            f.write("</table></body></html>")
        print('Susscessful export data to {}.html'.format(report_name))
    
    elif args.output == 'csv':
        with open(f"{report_name}.csv", "w") as f:
            f.write("Query Text,Time Range,IP,Database,User,Query Plan,Duration (sum/max/min/avg),Calls\n")
            for qry_text, stat in sorted_data:
                qry_text = qry_text.replace('"','""')
                f.write(f"{qry_text},{stat['min_times']} - {stat['max_times']},{stat['IP']},{stat['database']},{stat['user']},{stat['qry_plan']},{stat['sum_duration']}/{stat['max_duration']}/{stat['min_duration']}/{stat['avg_duration']},{stat['count']}\n")
        print('Susscessful export data to {}.csv'.format(report_name))
    
    elif args.output == 'txt':
        with open(f"{report_name}.txt", "w") as f:
            for qry_text, stat in sorted_data:
                f.write(f"Query Text: {qry_text}\n")
                f.write(f"Time Range: {stat['min_times']} - {stat['max_times']}\n")
                f.write(f"IP: {stat['IP']}\n")
                f.write(f"Database: {stat['database']}\n")
                f.write(f"User: {stat['user']}\n")
                f.write(f"Query Plan: {stat['qry_plan']}\n")
                f.write(f"Duration (sum/max/min/avg): {stat['sum_duration']}/{stat['max_duration']}/{stat['min_duration']}/{stat['avg_duration']}\n")
                f.write(f"Calls: {stat['count']}\n")
                f.write("-" * 50 + "\n")
        print('Susscessful export data to {}.txt'.format(report_name))

elif e_type == 'slow':
    parse_slow_sql(start_n, blocks)
    total_list.sort(key=lambda x: x['unique_id'])
    grouped = {key: list(group) for key, group in groupby(total_list, key=lambda x: x['unique_id'])}
    stats = {}
    for unique_id, group in grouped.items():
        durations = [item['duration'] for item in group]
        times = [item['time'] for item in group]
        stats[unique_id] = {
            'max_duration': max(durations), 
            'min_duration': min(durations), 
            'avg_duration': round(mean(durations),3),
            'sum_duration': round(sum(durations),3),
            'count': len(group),
            'max_times': max(times),
            'min_times': min(times),
            'qry_params': group[0]['qry_params'],
            'IP': group[0]['IP'],
            'database': group[0]['database'],
            'user': group[0]['user'],  # Include user in the statistics
            'qry_text': group[0]['qry_text']
        }
    sorted_data = sorted(stats.items(), key=lambda x: x[1]['sum_duration'], reverse=True)

    # Generate report based on the output format
    base_filename = os.path.splitext(file_name)[0]
    report_name = f"{base_filename}_slow_query_report"

    if args.output == 'html':
        with open(f"{report_name}.html", "w") as f:
            f.write("<html><body><h1>Slow Query Analysis Report</h1><table border='1' cellpadding='5'><tr><th>Unique ID</th><th>Time Range</th><th>IP</th><th>Database</th><th>User</th><th>Query Text</th><th>Params</th><th>Duration (sum/max/min/avg)</th><th>Calls</th></tr>")
            for idx, (unique_id, stat) in enumerate(sorted_data):
                row_color = "lightyellow" if idx % 2 == 0 else "lightblue"
                duration_class = "normal" if stat['avg_duration'] < 2 else "warning" if stat['avg_duration'] < 5 else "critical"
                f.write(f"<tr bgcolor='{row_color}' class='{duration_class}'><td>{unique_id}</td><td>{stat['min_times']} - {stat['max_times']}</td><td>{stat['IP']}</td><td>{stat['database']}</td><td>{stat['user']}</td><td>{stat['qry_text']}</td><td>{stat['qry_params']}</td><td><p>sum:{stat['sum_duration']}<br />max:{stat['max_duration']}<br />min:{stat['min_duration']}<br />avg:{stat['avg_duration']}</p></td><td>{stat['count']}</td></tr>")
            f.write("</table></body></html>")
        print('Susscessful export data to {}.html'.format(report_name))

    elif args.output == 'csv':
        with open(f"{report_name}.csv", "w") as f:
            f.write("Unique ID,Time Range,IP,Database,User,Query Text,Params,Duration (sum/max/min/avg),Calls\n")
            #print(sorted_data)
            for unique_id, stat in sorted_data:
                qry_text = stat['qry_text'].replace('"','""')
                qry_params = stat['qry_params']
                f.write(f"{unique_id},{stat['min_times']} - {stat['max_times']},{stat['IP']},{stat['database']},{stat['user']},\"{qry_text}\",\"{qry_params}\",{stat['sum_duration']}/{stat['max_duration']}/{stat['min_duration']}/{stat['avg_duration']},{stat['count']}\n")
        print('Susscessful export data to {}.csv'.format(report_name))
    
    elif args.output == 'txt':
        with open(f"{report_name}.txt", "w") as f:
            for unique_id, stat in sorted_data:
                f.write(f"Unique ID: {unique_id}\n")
                f.write(f"Time Range: {stat['min_times']} - {stat['max_times']}\n")
                f.write(f"IP: {stat['IP']}\n")
                f.write(f"Database: {stat['database']}\n")
                f.write(f"User: {stat['user']}\n")
                f.write(f"Query Text: {stat['qry_text']}\n")
                f.write(f"Params: {stat['qry_params']}\n")
                f.write(f"Duration (sum/max/min/avg)  sum:{stat['sum_duration']}/  max:{stat['max_duration']}/  min:{stat['min_duration']}/  avg:{stat['avg_duration']}\n")
                f.write(f"Calls: {stat['count']}\n")
                f.write("-" * 50 + "\n")
        print('Susscessful export data to {}.txt'.format(report_name))

else:
    print(f'Error: not support type {e_type}')
    sys.exit(2)

EOF

    # Execute the python script with the provided arguments
    python3 "$TEMP_SCRIPT" "${@:2}"
    
    # Clean up
    rm -f "$TEMP_SCRIPT"
}

