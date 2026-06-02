#!/bin/bash
# Command: analyze_log_v2 - Enhanced log analysis

analyze_log_v2_help() {
    echo "Options for analyze_log_v2:"
    echo "  Usage: -f <file> [-b <begin>] [-e <end>] [--diff <interval>] [-p <prefix>]"
    echo "  Options:"
    echo "    -f: log file name (required, supports multiple files and wildcards)"
    echo "    -b: start time (optional, format: 'YYYY-MM-DD HH:MM:SS')"
    echo "    -e: end time (optional, format: 'YYYY-MM-DD HH:MM:SS')"
    echo "    --diff: compare interval (30m, 1h, 1d, default: 1d)"
    echo "    -p: log line prefix format (optional, auto-detect from database)"
    echo "    -v: show version"
    echo ""
    echo "  Examples:"
    echo "    vb_tool analyze_log_v2 -f /path/to/postgresql-2025-01-01.log"
    echo "    vb_tool analyze_log_v2 -f /path/to/log1.log /path/to/log2.log"
    echo "    vb_tool analyze_log_v2 -f /path/to/log.log -b \"2025-01-01 00:00:00\" -e \"2025-01-02 23:59:59\""
    echo "    vb_tool analyze_log_v2 -f /path/to/log.log --diff 30m"
    echo ""
}
run_analyze_log_v2() {
    # Check if python3 is available
    if ! command -v python3 &> /dev/null; then
        echo "Error: python3 is required for log analysis but not found" >&2
        exit 1
    fi

    # Create a temporary python script
    TEMP_SCRIPT=$(mktemp)
    
    # Write the enhanced Python script content
    cat << 'PYTHON_EOF' > "$TEMP_SCRIPT"
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import re
import sys
import argparse
import subprocess
import gc
from itertools import groupby
from statistics import mean
from datetime import datetime, timedelta
import os
import glob
import gzip
import resource
import html
import json
from collections import defaultdict

# 预编译正则表达式以提高性能
TIMESTAMP_PATTERN = re.compile(r'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}) ')
IP_PATTERN = re.compile(r'(\d{1,3}\.){3}\d{1,3}\(\d+\)')
QUERY_TEXT_PATTERN = re.compile(r'Query Text:', re.IGNORECASE)
EXECUTE_PATTERN = re.compile(r'execute |duration:|unique id|statement:', re.IGNORECASE)
DURATION_PATTERN = re.compile(r'duration:', re.IGNORECASE)
PARAM_PATTERN = re.compile(r'\$(\d+)\s*=\s*([^,\s]+(?:\s*[^,\s]+)*)')
NAME_PATTERN = re.compile(r'Name:.*')
SPLIT_PATTERN = re.compile(r'\s+')
PARAMETERS_PATTERN = re.compile(r'parameters:\s+')
EXEC_PATTERN = re.compile(r'execute |duration:|unique id|statement:', re.IGNORECASE)
DURATION_EXTRACT_PATTERN = re.compile(r'duration:\s*(\d+(?:\.\d+)?)\s*s', re.IGNORECASE)

_file_mod_time_cache = {}

def check_memory_usage(threshold_mb=2048, raise_exception=True):
    memory_mb = 0
    try:
        memory_kb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        memory_mb = memory_kb / 1024
        if memory_mb > 0:
            if memory_mb > threshold_mb:
                error_msg = f"内存使用超过限制: {memory_mb:.2f}MB > MAX_LIMIT: {threshold_mb}MB "
                if raise_exception:
                    raise MemoryError(error_msg)
            else:
                print(f"内存使用正常: {memory_mb:.2f}MB    MAX_LIMIT: {threshold_mb}MB ")
        else:
            print("警告: 内存检查失败，请注意内存使用")
    except Exception as e:
        print("警告: 内存检查失败，请注意内存使用")

def get_log_line_prefix():
    try:
        process = subprocess.Popen(
            ['vsql', '-q', '-A', '-t', '-c', 'show log_line_prefix'],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True
        )
        stdout, stderr = process.communicate()
        if process.returncode != 0:
            print(f"ERROR: vsql命令执行失败: {stderr.strip()}")
            return None
        log_prefix = stdout.strip()
        return log_prefix
    except FileNotFoundError:
        print("ERROR: 未找到vsql命令，请确保已正确安装并配置数据库客户端")
        return None
    except Exception as e:
        print(f"ERROR: 获取日志行前缀格式时发生错误: {str(e)}")
        return None

def get_db_log_directory():
    try:
        process = subprocess.Popen(
            ['vsql', '-q', '-A', '-t', '-c', 'show log_directory'],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True
        )
        stdout, stderr = process.communicate()
        if process.returncode != 0:
            print(f"ERROR: vsql命令执行失败: {stderr.strip()}")
            return None
        log_directory = stdout.strip()
        if not os.path.isabs(log_directory):
            process_data = subprocess.Popen(
                ['vsql', '-q', '-A', '-t', '-c', 'show data_directory'],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                universal_newlines=True
            )
            stdout_data, stderr_data = process_data.communicate()
            if process_data.returncode != 0:
                print(f"ERROR: 获取data_directory失败: {stderr_data.strip()}")
                return None
            data_directory = stdout_data.strip()
            log_directory = os.path.join(data_directory, log_directory)
        return log_directory
    except FileNotFoundError:
        print("ERROR: 未找到vsql命令，请确保已正确安装并配置数据库客户端")
        return None
    except Exception as e:
        print(f"ERROR: 获取日志目录时发生错误: {str(e)}")
        return None

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

def parse_log_prefix_format(log_prefix):
    if not log_prefix:
        log_prefix = '%m %u %d %r %p %S [%x]'
    format_mapping = {
        '%m': 'timestamp', '%u': 'user', '%d': 'database', '%r': 'remote_host',
        '%p': 'thread_id', '%S': 'session_id', '%x': 'transaction_id', '%t': 'timestamp',
        '%i': 'application_name', '%l': 'log_line_number', '%v': 'virtual_transaction_id',
        '%q': 'backend_type', '%s': 'timestamp', '%n': 'timestamp', '%c': 'session_id',
        '%%': 'literal_percent'
    }
    extracted_fields = []
    i = 0
    while i < len(log_prefix):
        if log_prefix[i:i+2] in format_mapping:
            field_code = log_prefix[i:i+2]
            field_name = format_mapping[field_code]
            if field_name not in ['literal_percent']:
                extracted_fields.append(field_name)
            i += 2
        else:
            i += 1
    unique_fields = []
    seen = set()
    for field in extracted_fields:
        if field not in seen:
            unique_fields.append(field)
            seen.add(field)
    if unique_fields and unique_fields[0] == 'timestamp':
        unique_fields = unique_fields[1:]
    print(f"解析日志前缀 '{log_prefix}'....")
    return {
        'parse_func': lambda log_line: _parse_log_line_by_format(log_line, unique_fields),
        'fields': unique_fields,
        'format_name': 'dynamic',
        'format_template': log_prefix
    }

def _parse_log_line_by_format(log_line, unique_fields):
    tokens = log_line.strip().split()
    result = {}
    token_idx = 0
    for field_name in unique_fields:
        if token_idx >= len(tokens):
            break
        current_token = tokens[token_idx]
        if field_name == 'remote_host':
            if IP_PATTERN.match(current_token):
                result[field_name] = current_token
                token_idx += 1
            else:
                found_ip = False
                search_start = token_idx
                for j in range(search_start, len(tokens)):
                    if IP_PATTERN.match(tokens[j]):
                        result[field_name] = tokens[j]
                        if j == token_idx:
                            token_idx += 1
                        else:
                            token_idx = j + 1
                        found_ip = True
                        break
                if not found_ip:
                    result[field_name] = current_token
                    token_idx += 1
        elif field_name in ['transaction_id', 'thread_id']:
            if current_token.startswith('[') and current_token.endswith(']'):
                value = current_token[1:-1]
                result[field_name] = value
                token_idx += 1
            else:
                result[field_name] = current_token
                token_idx += 1
        else:
            result[field_name] = current_token
            token_idx += 1
    if not result:
        return None
    return result

def _parse_log_fallback(content0, log_format_info):
    if len(content0) < 3:
        return '', '', ''
    fields_order = log_format_info.get('fields', ['user', 'database', 'remote_host', 'thread_id', 'session_id'])
    IP = database = user = ''
    remote_host_idx = database_idx = user_idx = -1
    for i, field_name in enumerate(fields_order):
        if i < len(content0):
            if field_name == 'remote_host':
                remote_host_idx = i
            elif field_name == 'database':
                database_idx = i
            elif field_name == 'user':
                user_idx = i
    if remote_host_idx >= 0 and remote_host_idx < len(content0):
        IP = content0[remote_host_idx]
    if database_idx >= 0 and database_idx < len(content0):
        database = content0[database_idx]
    if user_idx >= 0 and user_idx < len(content0):
        user = content0[user_idx]
    if not IP:
        for j, part in enumerate(content0):
            if IP_PATTERN.search(part):
                IP = part
                if j + 1 < len(content0):
                    database = content0[j + 1]
                if j + 2 < len(content0):
                    user = content0[j + 2]
                break
        else:
            if len(content0) >= 3:
                found_ip_idx = -1
                for j, part in enumerate(content0):
                    if IP_PATTERN.search(part):
                        found_ip_idx = j
                        break
                if found_ip_idx != -1:
                    IP = content0[found_ip_idx]
                    remaining_parts = [part for idx, part in enumerate(content0) if idx != found_ip_idx]
                    if len(remaining_parts) >= 2:
                        database = remaining_parts[0]
                        user = remaining_parts[1]
                else:
                    IP = content0[0]
                    database = content0[1]
                    user = content0[2]
    return IP, database, user

def extract_time_from_filename(filename):
    pattern = r'postgresql-(\d{4}-\d{2}-\d{2})_(\d{6})'
    match = re.search(pattern, os.path.basename(filename))
    if match:
        date_part = match.group(1)
        time_part = match.group(2)
        timestamp_str = f"{date_part} {time_part[:2]}:{time_part[2:4]}:{time_part[4:6]}"
        try:
            return datetime.strptime(timestamp_str, '%Y-%m-%d %H:%M:%S')
        except ValueError:
            pass
    pattern2 = r'(\d{4}-\d{2}-\d{2})_(\d{6})'
    match2 = re.search(pattern2, os.path.basename(filename))
    if match2:
        date_part = match2.group(1)
        time_part = match2.group(2)
        timestamp_str = f"{date_part} {time_part[:2]}:{time_part[2:4]}:{time_part[4:6]}"
        try:
            return datetime.strptime(timestamp_str, '%Y-%m-%d %H:%M:%S')
        except ValueError:
            pass
    return None

def read_log_file_stream(file_name):
    try:
        file_size = os.path.getsize(file_name)
        file_size_gb = file_size / (1024**3)
        if file_size_gb > 2.0:
            print(f"警告: 文件 {file_name} 大小为 {file_size_gb:.2f}GB，超过2GB限制，程序退出")
            raise MemoryError(f"处理文件数过大，占用超过2GB内存。当前文件大小: {file_size_gb:.2f}GB")
        if file_name.endswith('.gz'):
            with gzip.open(file_name, 'rt', encoding='utf-8', errors='ignore') as file:
                content = file.read()
            print(f"检测到.gz文件，已自动解压: {file_name}")
        else:
            with open(file_name, "r", encoding='utf-8', errors='ignore') as file:
                content = file.read()
        return content
    except MemoryError:
        raise
    except Exception as e:
        print(f"错误: 无法读取文件 {file_name}: {str(e)}")
        return None

def find_recent_log_files(log_directory, days=7, begin_time=None, end_time=None):
    if not os.path.exists(log_directory):
        print(f"日志目录不存在: {log_directory}")
        return []
    log_patterns = [
        os.path.join(log_directory, "postgresql-*.log"),
        os.path.join(log_directory, "postgresql-*.log.gz"),
        os.path.join(log_directory, "pg_log", "*.log"),
        os.path.join(log_directory, "pg_log", "*.log.gz"),
        os.path.join(log_directory, "*.log"),
        os.path.join(log_directory, "*.log.gz")
    ]
    all_files = []
    checked_files = set()
    for pattern in log_patterns:
        try:
            files = glob.glob(pattern)
            for file_path in files:
                if file_path in checked_files:
                    continue
                checked_files.add(file_path)
                try:
                    cache_key_mod = f"{file_path}_mod"
                    cache_key_create = f"{file_path}_create"
                    if cache_key_mod not in _file_mod_time_cache:
                        _file_mod_time_cache[cache_key_mod] = datetime.fromtimestamp(os.path.getmtime(file_path))
                    mod_time = _file_mod_time_cache[cache_key_mod]
                    if cache_key_create not in _file_mod_time_cache:
                        _file_mod_time_cache[cache_key_create] = datetime.fromtimestamp(os.path.getctime(file_path))
                    create_time = _file_mod_time_cache[cache_key_create]
                    filename_time = extract_time_from_filename(file_path)
                    all_files.append((file_path, create_time, mod_time, filename_time))
                except OSError:
                    continue
        except Exception as e:
            continue
    all_files.sort(key=lambda x: x[3] if x[3] else x[1])
    if begin_time or end_time:
        filtered_files = []
        for file_path, create_time, mod_time, filename_time in all_files:
            if filename_time:
                if begin_time and end_time:
                    time_in_range = filename_time >= begin_time and filename_time <= end_time
                elif begin_time:
                    time_in_range = filename_time >= begin_time
                elif end_time:
                    time_in_range = filename_time <= end_time
                else:
                    time_in_range = True
                if time_in_range or (begin_time and mod_time >= begin_time):
                    filtered_files.append(file_path)
            else:
                includes_begin = not begin_time or mod_time >= begin_time
                includes_end = not end_time or create_time <= end_time
                if includes_begin and includes_end:
                    filtered_files.append(file_path)
        if not filtered_files and all_files:
            earliest_file, earliest_create, earliest_mod, earliest_filename_time = all_files[0]
            latest_file, latest_create, latest_mod, latest_filename_time = all_files[-1]
            def should_include_file(create_time, mod_time, filename_time):
                if filename_time:
                    if begin_time and end_time:
                        time_in_range = filename_time >= begin_time and filename_time <= end_time
                    elif begin_time:
                        time_in_range = filename_time >= begin_time
                    elif end_time:
                        time_in_range = filename_time <= end_time
                    else:
                        time_in_range = True
                    return time_in_range or (begin_time and mod_time >= begin_time)
                else:
                    includes_begin = not begin_time or mod_time >= begin_time
                    includes_end = not end_time or create_time <= end_time
                    return includes_begin and includes_end
            if should_include_file(earliest_create, earliest_mod, earliest_filename_time):
                if earliest_file not in filtered_files:
                    filtered_files.append(earliest_file)
            if should_include_file(latest_create, latest_mod, latest_filename_time):
                if latest_file not in filtered_files:
                    filtered_files.append(latest_file)
        if not filtered_files:
            if begin_time and end_time:
                raise FileNotFoundError(f"在指定时间范围 {begin_time} 到 {end_time} 内没有找到合适的日志文件")
            elif begin_time:
                raise FileNotFoundError(f"在指定开始时间 {begin_time} 之后没有找到合适的日志文件")
            elif end_time:
                raise FileNotFoundError(f"在指定结束时间 {end_time} 之前没有找到合适的日志文件")
            else:
                cutoff_date = datetime.now() - timedelta(days=days)
                for file_path, create_time, mod_time, filename_time in all_files:
                    if (filename_time if filename_time else create_time) >= cutoff_date:
                        filtered_files.append(file_path)
        filtered_files.sort(key=lambda x: _file_mod_time_cache.get(f"{x}_mod", os.path.getmtime(x)), reverse=False)
        return filtered_files
    else:
        cutoff_date = datetime.now() - timedelta(days=days)
        recent_files = []
        for file_path, create_time, mod_time, filename_time in all_files:
            if (filename_time if filename_time else create_time) >= cutoff_date:
                recent_files.append(file_path)
        recent_files.sort(key=lambda x: _file_mod_time_cache.get(f"{x}_mod", os.path.getmtime(x)), reverse=False)
        return recent_files

def expand_file_patterns(file_patterns):
    expanded_files = []
    for pattern in file_patterns:
        matched_files = glob.glob(pattern)
        if matched_files:
            expanded_files.extend(matched_files)
        else:
            if os.path.isfile(pattern):
                expanded_files.append(pattern)
            else:
                print(f"警告: 未找到匹配的文件: {pattern}")
    expanded_files = sorted(list(set(expanded_files)))
    return expanded_files

def show_progress(current, total, prefix="处理进度", start_time=None, total_elapsed_time=0):
    bar_length = 50
    if total <= 0:
        percent = 100.0 if current > 0 else 0.0
        filled_length = bar_length if current > 0 else 0
    else:
        percent = (current / total) * 100
        filled_length = int(bar_length * current // total)
    bar = '=' * filled_length + '-' * (bar_length - filled_length)
    elapsed_time = ""
    if start_time:
        elapsed = datetime.now() - start_time
        elapsed_seconds = int(elapsed.total_seconds())
        total_seconds = total_elapsed_time + elapsed_seconds
        elapsed_time = f" 总耗时: {total_seconds}秒"
    print(f'\r{prefix}: |{bar}| {percent:.1f}% ({current}/{total}){elapsed_time}', end='', flush=True)
    if current == total:
        print()

def parse_diff_interval(diff_str):
    match = re.match(r'^(\d+)([mhd])$', diff_str)
    if not match:
        print(f"错误: 无效的对比间隔格式 '{diff_str}'，应为 数字+m/h/d，例如 30m, 1h, 1d")
        sys.exit(1)
    value = int(match.group(1))
    unit = match.group(2)
    if unit == 'm':
        return timedelta(minutes=value)
    elif unit == 'h':
        return timedelta(hours=value)
    elif unit == 'd':
        return timedelta(days=value)
    else:
        print(f"错误: 无效的对比间隔单位 '{unit}'，应为 m/h/d")
        sys.exit(1)

def fill_sql_params(query_text, params):
    if not params or params.strip() == '':
        return query_text, []
    param_dict = {}
    param_list = []
    matches = PARAM_PATTERN.findall(params)
    for param_num, param_value in matches:
        preserved_value = param_value.strip()
        param_dict[f'${param_num}'] = preserved_value
        param_index = int(param_num) - 1
        while len(param_list) <= param_index:
            param_list.append(None)
        param_list[param_index] = preserved_value
    filled_query = query_text
    for placeholder in sorted(param_dict.keys(), key=lambda k: int(k[1:]), reverse=True):
        value = param_dict[placeholder]
        pattern = re.compile(rf"\{placeholder}(?!\d)")
        filled_query = pattern.sub(lambda m, v=value: v, filled_query)
    filtered_param_list = [param for param in param_list if param is not None]
    return filled_query, filtered_param_list

def normalize_sql_for_display(sql_text):
    if not sql_text:
        return sql_text
    text = sql_text.replace('\r\n', '\n').replace('\r', '\n')
    text = re.sub(r'(?:\n[ \t]*){2,}', '\n\n', text)
    return text.strip()

def process_single_file(file_name, args, total_elapsed_time=0, log_format_info=None):
    print(f"\n正在处理文件: {file_name}")
    content = read_log_file_stream(file_name)
    if content is None:
        return [], 0
    file_size = len(content)
    file_size_mb = file_size / (1024 * 1024)
    print(f"文件大小: {file_size_mb:.2f} MB")
    blocks = TIMESTAMP_PATTERN.split(content)[1:]
    if not blocks:
        print("警告: 未在文件中找到符合格式的日志记录")
        return [], file_size_mb
    start_n = 0
    earliest_ts = parse_datetime(blocks[0])
    latest_ts = parse_datetime(blocks[-2])
    if args.begin:
        v_begin = parse_datetime(args.begin)
        if v_begin is not None:
            if v_begin > latest_ts:
                return [], file_size_mb
            elif v_begin <= earliest_ts:
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
        if v_end is not None:
            if v_end < earliest_ts:
                return [], file_size_mb
            elif v_end < latest_ts:
                matching_index = -2
                for i in range(len(blocks)-2, -2, -2):
                    time_value = parse_datetime(blocks[i])
                    if time_value <= v_end:
                        matching_index = i
                        break
                if matching_index != -2:
                    blocks = blocks[:matching_index+2]
    total_list = []
    parse_slow_sql(start_n, blocks, total_list, total_elapsed_time, log_format_info)
    print(f"文件 {file_name} 处理完成，找到 {len(total_list)} 条记录")
    del blocks
    del content
    check_memory_usage(2048)
    gc.collect()
    return total_list, file_size_mb

def process_multiple_files(file_names, args, log_format_info):
    all_total_list = []
    total_size = 0
    total_elapsed_time = 0
    print(f"开始处理 {len(file_names)} 个日志文件...")
    for i, file_name in enumerate(file_names, 1):
        print(f"\n{'='*60}")
        print(f"处理进度: {i}/{len(file_names)}")
        try:
            file_start_time = datetime.now()
            total_list, file_size_mb = process_single_file(file_name, args, total_elapsed_time, log_format_info)
            file_end_time = datetime.now()
            file_elapsed_time = int((file_end_time - file_start_time).total_seconds())
            total_elapsed_time += file_elapsed_time
            all_total_list.extend(total_list)
            total_size += file_size_mb
            del total_list
            gc.collect()
        except Exception as e:
            print(f"处理文件 {file_name} 时出错: {str(e)}")
            continue
    print(f"\n{'='*60}")
    print(f"所有文件处理完成!")
    print(f"总文件大小: {total_size:.2f} MB")
    print(f"总记录数: {len(all_total_list)} 条")
    print(f"总耗时: {total_elapsed_time}秒")
    return all_total_list, total_size, total_elapsed_time

def get_base_filename_from_files(file_names):
    if not file_names:
        return "analyze_log_report"
    import socket
    hostname = socket.gethostname()
    dates = []
    for file_path in [file_names[0], file_names[-1]]:
        filename = os.path.basename(file_path)
        date_patterns = [
            r'(\d{4}-\d{2}-\d{2})',
            r'(\d{4}\d{2}\d{2})',
            r'(\d{2}-\d{2}-\d{4})',
        ]
        found_date = None
        for pattern in date_patterns:
            match = re.search(pattern, filename)
            if match:
                date_str = match.group(1)
                if len(date_str) == 8 and date_str.isdigit():
                    found_date = f"{date_str[:4]}-{date_str[4:6]}-{date_str[6:8]}"
                elif len(date_str) == 10 and '-' in date_str:
                    parts = date_str.split('-')
                    if len(parts[0]) == 2 and len(parts[2]) == 4:
                        found_date = f"{parts[2]}-{parts[1]}-{parts[0]}"
                    else:
                        found_date = date_str
                else:
                    found_date = date_str
                break
        if found_date:
            dates.append(found_date)
        else:
            try:
                mod_time = datetime.fromtimestamp(os.path.getmtime(file_path))
                dates.append(mod_time.strftime('%Y-%m-%d'))
            except:
                dates.append("unknown_date")
    if len(dates) == 2:
        if dates[0] == dates[1]:
            base_filename = f"{hostname}_{dates[0]}"
        else:
            base_filename = f"{hostname}_{dates[0]}_{dates[1]}"
    else:
        base_filename = f"{hostname}_{dates[0]}" if dates else hostname
    return base_filename

class ReportGenerator:
    TIME_RANGES = [
        (60, float('inf'), '#8B0000', '60s以上'),
        (30, 60, '#FF6B6B', '30-60s'),
        (10, 30, '#FFD93D', '10-30s'),
        (3, 10, '#6BC5D2', '3-10s'),
        (1, 3, '#CCCCCC', '1-3s'),
        (0, 1, '#4CAF50', '1s以下'),
    ]
    
    @staticmethod
    def generate_sql_summary(stats_dict, all_total_list):
        summary_html_parts = []
        chart_data = {}
        range_counts = {rname: 0 for _, _, _, rname in ReportGenerator.TIME_RANGES}
        for stat in stats_dict.values():
            avg_duration = stat['avg_duration']
            for min_t, max_t, _, rname in ReportGenerator.TIME_RANGES:
                if min_t <= avg_duration < max_t:
                    range_counts[rname] += 1
                    break
        total_slow = len(stats_dict)
        summary_html_parts.append(f"""
        <h2>SQL汇总统计</h2>
        <div class="summary-stats">
            <p><strong>总慢SQL数量：</strong>{total_slow} 条</p>
            <div class="stats-grid">
        """)
        for _, _, color, rname in ReportGenerator.TIME_RANGES:
            count = range_counts[rname]
            percent = (count / total_slow * 100) if total_slow > 0 else 0
            summary_html_parts.append(f"""
                <div class="stat-item" style="border-left-color: {color};">
                    <span class="range-name">{rname}</span>
                    <span class="range-count">{count} 条</span>
                    <span class="range-percent">({percent:.1f}%)</span>
                </div>
            """)
        summary_html_parts.append("""
            </div>
        </div>
        """)
        pie_data = []
        for _, _, color, rname in ReportGenerator.TIME_RANGES:
            if range_counts[rname] > 0:
                pie_data.append({
                    'name': rname,
                    'count': range_counts[rname],
                    'color': color,
                    'percent': (range_counts[rname] / total_slow * 100) if total_slow > 0 else 0
                })
        chart_data['pie'] = pie_data
        stats_list = [(uid, data) for uid, data in stats_dict.items()]
        sorted_by_sum = sorted(stats_list, key=lambda x: x[1]['sum_duration'], reverse=True)[:10]
        sorted_by_avg = sorted(stats_list, key=lambda x: x[1]['avg_duration'], reverse=True)[:10]
        sorted_by_count = sorted(stats_list, key=lambda x: x[1]['count'], reverse=True)[:10]
        sorted_by_max = sorted(stats_list, key=lambda x: x[1]['max_duration'], reverse=True)[:10]
        summary_html_parts.append("""
        <h3 id="top10-ranking">Top 10 慢SQL排名</h3>
        <div class="top10-container">
        """)
        summary_html_parts.append("""
            <div class="top10-section">
                <h4>按总耗时排序 (sum_duration)</h4>
                <table class="top10-table">
                    <tr><th>排名</th><th>Unique ID</th><th>SQL Text</th><th>总耗时(s)</th><th>执行次数</th></tr>
        """)
        for idx, (uid, stat) in enumerate(sorted_by_sum, 1):
            uid_escaped = html.escape(str(uid).strip(), quote=True)
            sql_text_full = stat.get('qry_text', '')
            sql_text_short = html.escape(sql_text_full[:50], quote=True) if sql_text_full else ''
            sql_text_display = f"{sql_text_short}..." if len(sql_text_full) > 50 else sql_text_short
            summary_html_parts.append(f"""
                    <tr>
                        <td>{idx}</td>
                        <td><a href="#detail-{uid_escaped}" class="uid-link">{uid_escaped}</a></td>
                        <td class="sql-text-col" title="{html.escape(sql_text_full, quote=True)}">{sql_text_display}</td>
                        <td>{stat['sum_duration']:.3f}</td>
                        <td>{stat['count']}</td>
                    </tr>
            """)
        summary_html_parts.append("""
                </table>
            </div>
        """)
        summary_html_parts.append("""
            <div class="top10-section">
                <h4>按平均耗时排序 (avg_duration)</h4>
                <table class="top10-table">
                    <tr><th>排名</th><th>Unique ID</th><th>SQL Text</th><th>平均耗时(s)</th><th>执行次数</th></tr>
        """)
        for idx, (uid, stat) in enumerate(sorted_by_avg, 1):
            uid_escaped = html.escape(str(uid).strip(), quote=True)
            sql_text_full = stat.get('qry_text', '')
            sql_text_short = html.escape(sql_text_full[:50], quote=True) if sql_text_full else ''
            sql_text_display = f"{sql_text_short}..." if len(sql_text_full) > 100 else sql_text_short
            summary_html_parts.append(f"""
                    <tr>
                        <td>{idx}</td>
                        <td><a href="#detail-{uid_escaped}" class="uid-link">{uid_escaped}</a></td>
                        <td class="sql-text-col" title="{html.escape(sql_text_full, quote=True)}">{sql_text_display}</td>
                        <td>{stat['avg_duration']:.3f}</td>
                        <td>{stat['count']}</td>
                    </tr>
            """)
        summary_html_parts.append("""
                </table>
            </div>
        """)
        summary_html_parts.append("""
            <div class="top10-section">
                <h4>按执行次数排序 (calls)</h4>
                <table class="top10-table">
                    <tr><th>排名</th><th>Unique ID</th><th>SQL Text</th><th>执行次数</th><th>平均耗时(s)</th></tr>
        """)
        for idx, (uid, stat) in enumerate(sorted_by_count, 1):
            uid_escaped = html.escape(str(uid).strip(), quote=True)
            sql_text_full = stat.get('qry_text', '')
            sql_text_short = html.escape(sql_text_full[:50], quote=True) if sql_text_full else ''
            sql_text_display = f"{sql_text_short}..." if len(sql_text_full) > 100 else sql_text_short
            summary_html_parts.append(f"""
                    <tr>
                        <td>{idx}</td>
                        <td><a href="#detail-{uid_escaped}" class="uid-link">{uid_escaped}</a></td>
                        <td class="sql-text-col" title="{html.escape(sql_text_full, quote=True)}">{sql_text_display}</td>
                        <td>{stat['count']}</td>
                        <td>{stat['avg_duration']:.3f}</td>
                    </tr>
            """)
        summary_html_parts.append("""
                </table>
            </div>
        """)
        summary_html_parts.append("""
            <div class="top10-section">
                <h4>按最大耗时排序 (max_duration)</h4>
                <table class="top10-table">
                    <tr><th>排名</th><th>Unique ID</th><th>SQL Text</th><th>最大耗时(s)</th><th>执行次数</th></tr>
        """)
        for idx, (uid, stat) in enumerate(sorted_by_max, 1):
            uid_escaped = html.escape(str(uid).strip(), quote=True)
            sql_text_full = stat.get('qry_text', '')
            sql_text_short = html.escape(sql_text_full[:50], quote=True) if sql_text_full else ''
            sql_text_display = f"{sql_text_short}..." if len(sql_text_full) > 100 else sql_text_short
            summary_html_parts.append(f"""
                    <tr>
                        <td>{idx}</td>
                        <td><a href="#detail-{uid_escaped}" class="uid-link">{uid_escaped}</a></td>
                        <td class="sql-text-col" title="{html.escape(sql_text_full, quote=True)}">{sql_text_display}</td>
                        <td>{stat['max_duration']:.3f}</td>
                        <td>{stat['count']}</td>
                    </tr>
            """)
        summary_html_parts.append("""
                </table>
            </div>
        """)
        summary_html_parts.append("</div>")
        return {
            'html': ''.join(summary_html_parts),
            'chart_data': chart_data,
            'top10_data': {
                'by_sum': sorted_by_sum,
                'by_avg': sorted_by_avg,
                'by_count': sorted_by_count,
                'by_max': sorted_by_max,
            }
        }
    
    TIME_DIMENSIONS = [
        {'id': 'minute', 'name': '每分钟', 'interval_minutes': 1, 'always_show': True, 'diff_threshold_minutes': 1},
        {'id': '10minute', 'name': '每10分钟', 'interval_minutes': 10, 'always_show': True, 'diff_threshold_minutes': 10},
        {'id': 'hour', 'name': '每小时', 'interval_minutes': 60, 'always_show': True, 'diff_threshold_minutes': 60},
        {'id': 'day', 'name': '每天', 'interval_minutes': 1440, 'always_show': True, 'diff_threshold_minutes': 1440}
    ]
    
    @staticmethod
    def _get_interval_minutes(dim_id):
        if dim_id == 'minute':
            return 1
        elif dim_id == '10minute':
            return 10
        elif dim_id == 'hour':
            return 60
        elif dim_id == 'day':
            return 1440
        elif dim_id.endswith('minute'):
            return int(dim_id.replace('minute', ''))
        else:
            return 9999
    
    @staticmethod
    def _get_time_key(dt, dim_id):
        interval = ReportGenerator._get_interval_minutes(dim_id)
        if dim_id == 'minute':
            return dt.strftime('%Y-%m-%d %H:%M')
        elif dim_id == 'hour':
            return dt.strftime('%Y-%m-%d %H:00')
        elif dim_id == 'day':
            return dt.strftime('%Y-%m-%d')
        else:
            start_min = (dt.minute // interval) * interval
            start_dt = datetime(dt.year, dt.month, dt.day, dt.hour, start_min)
            end_dt = start_dt + timedelta(minutes=interval - 1)
            if end_dt.date() != start_dt.date():
                return f"{start_dt.strftime('%Y-%m-%d %H:%M')}-{end_dt.strftime('%Y-%m-%d %H:%M')}"
            else:
                return f"{start_dt.strftime('%Y-%m-%d %H:%M')}-{end_dt.strftime('%H:%M')}"
    
    @staticmethod
    def _parse_time_label(time_label, dim_id):
        if dim_id == 'minute':
            return datetime.strptime(time_label, '%Y-%m-%d %H:%M')
        elif dim_id == 'hour':
            return datetime.strptime(time_label, '%Y-%m-%d %H:00')
        elif dim_id == 'day':
            return datetime.strptime(time_label, '%Y-%m-%d')
        else:
            start_part = time_label[:16]
            return datetime.strptime(start_part, '%Y-%m-%d %H:%M')
    
    @staticmethod
    def generate_time_analysis(all_total_list, overall_min_time, overall_max_time, diff_interval=None, diff_interval_str=None):
        if isinstance(overall_min_time, str):
            overall_min_time = parse_datetime(overall_min_time)
        if isinstance(overall_max_time, str):
            overall_max_time = parse_datetime(overall_max_time)
        dimensions = [dim.copy() for dim in ReportGenerator.TIME_DIMENSIONS]
        if diff_interval and diff_interval_str:
            diff_minutes = int(diff_interval.total_seconds() / 60)
            existing_intervals = [dim['interval_minutes'] for dim in dimensions]
            if diff_minutes not in existing_intervals and diff_minutes > 1:
                dynamic_dim = {
                    'id': f"{diff_minutes}minute",
                    'name': f"每{diff_minutes}分钟",
                    'interval_minutes': diff_minutes,
                    'always_show': True,
                    'diff_threshold_minutes': diff_minutes
                }
                dimensions.append(dynamic_dim)
        analysis_result = {}
        for dim in dimensions:
            analysis_result[f"by_{dim['id']}"] = {'show': False, 'html': '', 'chart_data': {}}
        all_dim_data = {}
        for dim in dimensions:
            all_dim_data[dim['id']] = defaultdict(lambda: defaultdict(int))
        for record in all_total_list:
            dt = record['time']
            uid = record['unique_id']
            for dim in dimensions:
                time_key = ReportGenerator._get_time_key(dt, dim['id'])
                all_dim_data[dim['id']][time_key][uid] += 1
        diff_minutes_val = diff_interval.total_seconds() / 60 if diff_interval else None
        if diff_minutes_val is not None:
            for dim in dimensions:
                if dim['interval_minutes'] > diff_minutes_val:
                    dim['always_show'] = False
        for dim in dimensions:
            if dim['always_show']:
                analysis_result[f"by_{dim['id']}"]['show'] = True
        diff_data = None
        if diff_interval:
            diff_minutes = diff_interval.total_seconds() / 60
            diff_start = overall_min_time - diff_interval
            diff_end = overall_max_time - diff_interval
            has_diff_data = False
            for record in all_total_list:
                if diff_start <= record['time'] <= diff_end:
                    has_diff_data = True
                    break
            if has_diff_data:
                diff_data = {'start': diff_start, 'end': diff_end}
                for dim in dimensions:
                    if diff_minutes >= dim['diff_threshold_minutes']:
                        diff_dim_data = defaultdict(lambda: defaultdict(int))
                        for record in all_total_list:
                            dt = record['time']
                            if diff_start <= dt <= diff_end:
                                uid = record['unique_id']
                                time_key = ReportGenerator._get_time_key(dt, dim['id'])
                                diff_dim_data[time_key][uid] += 1
                        diff_data[dim['id']] = diff_dim_data
                print(f"找到对比数据，时间范围: {diff_start.strftime('%Y-%m-%d %H:%M:%S')} 至 {diff_end.strftime('%Y-%m-%d %H:%M:%S')}，对比间隔: {diff_interval_str}")
            else:
                print(f"未找到对比时间范围 {diff_start.strftime('%Y-%m-%d %H:%M:%S')} 至 {diff_end.strftime('%Y-%m-%d %H:%M:%S')} 内的数据，不生成对比数据，对比间隔: {diff_interval_str}")
        for dim in dimensions:
            if analysis_result[f"by_{dim['id']}"]['show']:
                html_parts, chart_data = ReportGenerator._generate_time_dimension_html(
                    all_dim_data[dim['id']], dim['id'], dim['name'], overall_min_time, overall_max_time,
                    diff_data.get(dim['id']) if diff_data else None,
                    diff_interval, diff_interval_str
                )
                analysis_result[f"by_{dim['id']}"]['html'] = html_parts
                analysis_result[f"by_{dim['id']}"]['chart_data'] = chart_data
        return analysis_result
    
    @staticmethod
    def _generate_time_dimension_html(time_data, dim_id, dim_name, start_dt, end_dt, diff_data=None, diff_interval=None, diff_interval_str=None):
        html_parts = []
        chart_data = {'time_labels': [], 'series': []}
        interval_minutes = ReportGenerator._get_interval_minutes(dim_id)
        if dim_id == 'minute':
            delta = timedelta(minutes=1)
            current = datetime(start_dt.year, start_dt.month, start_dt.day, start_dt.hour, start_dt.minute)
            end = datetime(end_dt.year, end_dt.month, end_dt.day, end_dt.hour, end_dt.minute)
        elif dim_id == 'hour':
            delta = timedelta(hours=1)
            current = datetime(start_dt.year, start_dt.month, start_dt.day, start_dt.hour)
            end = datetime(end_dt.year, end_dt.month, end_dt.day, end_dt.hour)
        elif dim_id == 'day':
            delta = timedelta(days=1)
            current = datetime(start_dt.year, start_dt.month, start_dt.day)
            end = datetime(end_dt.year, end_dt.month, end_dt.day)
        else:
            delta = timedelta(minutes=interval_minutes)
            start_minute = (start_dt.minute // interval_minutes) * interval_minutes
            current = datetime(start_dt.year, start_dt.month, start_dt.day, start_dt.hour, start_minute)
            end_minute = (end_dt.minute // interval_minutes) * interval_minutes
            end = datetime(end_dt.year, end_dt.month, end_dt.day, end_dt.hour, end_minute)
        while current <= end:
            time_label = ReportGenerator._get_time_key(current, dim_id)
            chart_data['time_labels'].append(time_label)
            current += delta
        total_counts_per_uid = defaultdict(int)
        for time_label, uid_counts in time_data.items():
            for uid, count in uid_counts.items():
                total_counts_per_uid[uid] += count
        top10_uids = [uid for uid, _ in sorted(total_counts_per_uid.items(), key=lambda x: x[1], reverse=True)[:10]]
        color_palette = ['#FF6B6B', '#4ECDC4', '#FFD166', '#06D6A0', '#118AB2', '#EF476F', '#7BDFF2', '#B388EB', '#8093F1', '#FF9A76']
        uid_colors = {}
        for i, uid in enumerate(top10_uids):
            uid_colors[uid] = color_palette[i % len(color_palette)]
        for uid in top10_uids:
            uid_escaped = html.escape(str(uid).strip(), quote=True)
            series = {'uid': uid_escaped, 'color': uid_colors[uid], 'data': []}
            for time_label in chart_data['time_labels']:
                series['data'].append(time_data.get(time_label, {}).get(uid, 0))
            chart_data['series'].append(series)
        show_diff_column = diff_data is not None
        html_parts.append(f"""
        <div class="time-dimension" id="dim-{dim_id}">
            <div style="display: flex; justify-content: space-between; align-items: center;">
                <h3>{dim_name}维度统计 (Top 10)</h3>
                <a href="#top10-ranking" class="back-to-top" title="返回Top 10排名">↑ Top 10</a>
            </div>
            <div class="time-range-note">统计时间范围: {start_dt.strftime('%Y-%m-%d %H:%M:%S')} 至 {end_dt.strftime('%Y-%m-%d %H:%M:%S')}</div>
            <div class="period-table-wrapper">
        """)
        if show_diff_column and diff_interval:
            paired_rows = []
            sorted_times = sorted(time_data.items(), key=lambda x: x[0], reverse=True)
            period_index = 0
            for time_label, uid_counts in sorted_times:
                top10_in_period = sorted(uid_counts.items(), key=lambda x: x[1], reverse=True)[:10]
                if not top10_in_period:
                    continue
                try:
                    current_dt = ReportGenerator._parse_time_label(time_label, dim_id)
                    diff_dt = current_dt - diff_interval
                    diff_time_label = ReportGenerator._get_time_key(diff_dt, dim_id)
                except (ValueError, IndexError):
                    diff_time_label = None
                diff_uid_counts = diff_data.get(diff_time_label, {}) if diff_time_label else {}
                bg_color = 'rgba(220, 220, 220, 0.7)' if period_index % 2 == 0 else 'rgba(245, 245, 245, 0.9)'
                for uid, count in top10_in_period:
                    uid_escaped = html.escape(str(uid).strip(), quote=True)
                    diff_count = diff_uid_counts.get(uid, 0)
                    if uid in diff_uid_counts:
                        diff_value = count - diff_count
                        if diff_value > 0:
                            diff_display = f"+{diff_value}"
                        elif diff_value < 0:
                            diff_display = f"{diff_value}"
                        else:
                            diff_display = "0"
                    else:
                        diff_display = "+"
                        diff_count = 0
                    paired_rows.append({
                        'current_time': time_label,
                        'diff_time': diff_time_label if diff_time_label else '-',
                        'uid': uid_escaped,
                        'current_count': count,
                        'diff_count': diff_count,
                        'diff_display': diff_display,
                        'bg_color': bg_color
                    })
                period_index += 1
            num_tables = min(2, len(paired_rows))
            rows_per_table = (len(paired_rows) + num_tables - 1) // num_tables
            for table_idx in range(num_tables):
                start_row = table_idx * rows_per_table
                end_row = min(start_row + rows_per_table, len(paired_rows))
                table_rows = paired_rows[start_row:end_row]
                html_parts.append(f"""
                <table class="period-table">
                    <tr><th>当前时间</th><th>对比时间</th><th>Unique ID</th><th>当前次数</th><th>对比次数</th><th>差异</th></tr>
                """)
                for row in table_rows:
                    diff_style = ''
                    if row['diff_display']:
                        if row['diff_display'].startswith('+') and row['diff_display'] != '+':
                            diff_style = 'color: #e74c3c; font-weight: bold;'
                        elif row['diff_display'].startswith('-'):
                            diff_style = 'color: #27ae60; font-weight: bold;'
                        elif row['diff_display'] == '+':
                            diff_style = 'color: #e74c3c; font-weight: bold;'
                    html_parts.append(f"""
                        <tr style="background-color: {row['bg_color']};">
                            <td>{row['current_time']} </td>
                            <td>{row['diff_time']} </td>
                            <td><a href="#detail-{row['uid']}" class="uid-link">{row['uid']}</a></td>
                            <td>{row['current_count']} </td>
                            <td>{row['diff_count']} </td>
                            <td style="{diff_style}">{row['diff_display']}</td>
                        </tr>
                    """)
                html_parts.append("""
                </table>
                """)
        else:
            all_rows = []
            sorted_times = sorted(time_data.items(), key=lambda x: x[0], reverse=True)
            period_index = 0
            for time_label, uid_counts in sorted_times:
                top10_in_period = sorted(uid_counts.items(), key=lambda x: x[1], reverse=True)[:10]
                if not top10_in_period:
                    continue
                bg_color = 'rgba(220, 220, 220, 0.7)' if period_index % 2 == 0 else 'rgba(245, 245, 245, 0.9)'
                for uid, count in top10_in_period:
                    uid_escaped = html.escape(str(uid).strip(), quote=True)
                    all_rows.append((time_label, uid_escaped, count, bg_color))
                period_index += 1
            num_tables = min(2, len(all_rows))
            rows_per_table = (len(all_rows) + num_tables - 1) // num_tables
            for table_idx in range(num_tables):
                start_row = table_idx * rows_per_table
                end_row = min(start_row + rows_per_table, len(all_rows))
                table_rows = all_rows[start_row:end_row]
                html_parts.append(f"""
                <table class="period-table">
                    <tr><th>时间段</th><th>Unique ID</th><th>执行次数</th></tr>
                """)
                for time_label, uid_escaped, count, bg_color in table_rows:
                    html_parts.append(f"""
                        <tr style="background-color: {bg_color};">
                            <td>{time_label}</td>
                            <td><a href="#detail-{uid_escaped}" class="uid-link">{uid_escaped}</a></td>
                            <td>{count}</td>
                        </tr>
                    """)
                html_parts.append("""
                </table>
                """)
        html_parts.append("""
            </div>
        </div>
        """)
        html_parts.append("</div>")
        return ''.join(html_parts), chart_data
    
    @staticmethod
    def generate_full_html_report(sorted_data, summary_info, time_analysis_info, overall_min_time, overall_max_time, total_size_mb_all, total_elapsed_seconds_all, all_total_list):
        nav_html = f"""
        <div id="report-nav">
            <h2>慢查询分析报告导航</h2>
            <div class="nav-links">
                <a href="#summary-section">📊 SQL汇总统计</a>
                <a href="#time-analysis-section">⏰ SQL分时段分析</a>
                <a href="#detail-section">📋 SQL详情列表</a>
            </div>
            <div class="report-meta">
                <strong>分析时间范围：</strong>{overall_min_time.strftime('%Y-%m-%d %H:%M:%S') if hasattr(overall_min_time, 'strftime') else str(overall_min_time)} 至 {overall_max_time.strftime('%Y-%m-%d %H:%M:%S') if hasattr(overall_max_time, 'strftime') else str(overall_max_time)} ｜ 
                <strong>总文件大小：</strong>{total_size_mb_all:.2f} MB ｜ 
                <strong>总记录数：</strong>{len(all_total_list)} 条 ｜ 
                <strong>总耗时：</strong>{total_elapsed_seconds_all} 秒
            </div>
        </div>
        """
        summary_section = f"""
        <section id="summary-section">
            {summary_info['html']}
        </section>
        """
        time_analysis_html_parts = ['''<section id="time-analysis-section">
            <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px;">
                <h2 style="margin: 0;">SQL分时段分析</h2>
                <div class="search-box">
                    <input type="text" id="unique-id-search" placeholder="输入 Unique ID 过滤..." onkeydown="if(event.key==='Enter')applySearch()" />
                    <button onclick="applySearch()" class="btn-confirm" title="确认搜索">✓</button>
                    <button onclick="clearSearch()" class="btn-reset" title="清除搜索">×</button>
                </div>
            </div>
        ''']
        sorted_dims = []
        for key in time_analysis_info:
            if key.startswith('by_') and time_analysis_info[key]['show']:
                dim_id = key.replace('by_', '')
                interval = ReportGenerator._get_interval_minutes(dim_id)
                sorted_dims.append((interval, key))
        sorted_dims.sort(key=lambda x: x[0])
        for _, key in sorted_dims:
            time_analysis_html_parts.append(time_analysis_info[key]['html'])
        time_analysis_html_parts.append('</section>')
        time_analysis_section = ''.join(time_analysis_html_parts)
        detail_html_parts = ['<section id="detail-section"><div style="display: flex; justify-content: space-between; align-items: center;"><h2>SQL详情列表</h2><a href="#top10-ranking" class="back-to-top" title="返回Top 10排名">↑ Top 10</a></div><table class="detail-table">']
        detail_html_parts.append("""
        <tr>
            <th>Unique ID</th>
            <th>IP</th>
            <th>Database</th>
            <th>User</th>
            <th>Query Text</th>
            <th>Duration (sum/max/min/avg)</th>
            <th>Calls</th>
            <th>详细执行语句</th>
        </tr>
        """)
        for idx, (unique_id, stat) in enumerate(sorted_data):
            row_class = ""
            avg_duration = stat['avg_duration']
            for min_t, max_t, color, rname in ReportGenerator.TIME_RANGES:
                if min_t <= avg_duration < max_t:
                    row_class = f"range-{rname.replace('以上', 'above').replace('-', 'to').replace('s', '').replace('以下', 'below')}"
                    break
            max_q_disp = normalize_sql_for_display(stat['max_duration_query'])
            min_q_disp = normalize_sql_for_display(stat['min_duration_query'])
            max_execute_stmt = f"execute bind_sql({', '.join(stat['max_param_values'])});" if stat['max_param_values'] else "execute bind_sql;"
            min_execute_stmt = f"execute bind_sql({', '.join(stat['min_param_values'])});" if stat['min_param_values'] else "execute bind_sql;"
            qry_text_html = html.escape(stat['qry_text'], quote=True)
            max_execute_html = html.escape(max_execute_stmt, quote=True)
            min_execute_html = html.escape(min_execute_stmt, quote=True)
            max_times_str = stat['max_times'].strftime('%Y-%m-%d %H:%M:%S.%f')[:-3] if hasattr(stat['max_times'], 'strftime') else str(stat['max_times'])
            min_times_str = stat['min_times'].strftime('%Y-%m-%d %H:%M:%S.%f')[:-3] if hasattr(stat['min_times'], 'strftime') else str(stat['min_times'])
            if stat['count'] == 1 or stat['max_duration'] == stat['min_duration']:
                detail_html = f"""
                <details>
                    <summary>点击详情</summary>
                    <div class='duration-info'>
                        <p><strong>执行语句 ({stat['max_duration']:.3f}s):</strong> 
                           <button class='copy-btn' onclick="copyToClipboard(`{stat['max_duration_query']}`)">复制</button> 
                           <button class='copy-btn' data-query-template="{qry_text_html}" data-execute-stmt="{max_execute_html}" onclick="generatePreparedStatement(this)">生成 Prepared</button>
                        </p>
                        <p><strong>执行时间点:</strong> {max_times_str}</p>
                        <pre>{max_q_disp}</pre>
                    </div>
                </details>
                """
            else:
                detail_html = f"""
                <details>
                    <summary>点击详情</summary>
                    <div class='duration-info'>
                        <p><strong>最大执行时间语句 ({stat['max_duration']:.3f}s):</strong> 
                           <button class='copy-btn' onclick="copyToClipboard(`{stat['max_duration_query']}`)">复制</button> 
                           <button class='copy-btn' data-query-template="{qry_text_html}" data-execute-stmt="{max_execute_html}" onclick="generatePreparedStatement(this)">生成 Prepared</button>
                        </p>
                        <p><strong>执行时间点:</strong> {max_times_str}</p>
                        <pre>{max_q_disp}</pre>
                        <p><strong>最小执行时间语句 ({stat['min_duration']:.3f}s):</strong> 
                           <button class='copy-btn' onclick="copyToClipboard(`{stat['min_duration_query']}`)">复制</button> 
                           <button class='copy-btn' data-query-template="{qry_text_html}" data-execute-stmt="{min_execute_html}" onclick="generatePreparedStatement(this)">生成 Prepared</button>
                        </p>
                        <p><strong>执行时间点:</strong> {min_times_str}</p>
                        <pre>{min_q_disp}</pre>
                    </div>
                </details>
                """
            unique_id_escaped = html.escape(str(unique_id).strip(), quote=True)
            detail_html_parts.append(f"""
            <tr id="detail-{unique_id_escaped}" class="{row_class}">
                <td><a name="detail-{unique_id_escaped}"></a>{unique_id_escaped}</td>
                <td>{stat['IP']}</td>
                <td>{stat['database']}</td>
                <td>{stat['user']}</td>
                <td>{stat['qry_text']}</td>
                <td>
                    <p>sum:{stat['sum_duration']:.3f}<br />
                       max:{stat['max_duration']:.3f}<br />
                       min:{stat['min_duration']:.3f}<br />
                       avg:{stat['avg_duration']:.3f}</p>
                </td>
                <td>{stat['count']}</td>
                <td>{detail_html}</td>
            </tr>
            """)
        detail_html_parts.append('</table></section>')
        detail_section = ''.join(detail_html_parts)
        def ensure_chart_data_structure(data):
            if not data:
                return {'time_labels': [], 'series': []}
            return data
        chart_js_data = {'summary_pie': summary_info['chart_data'].get('pie', []), 'time_analysis': {}}
        for key in time_analysis_info:
            if key.startswith('by_'):
                chart_js_data['time_analysis'][key] = ensure_chart_data_structure(time_analysis_info[key]['chart_data'] if time_analysis_info[key]['show'] else {})
        chart_js_data_json = json.dumps(chart_js_data, ensure_ascii=False, separators=(',', ':'))
        full_html = f"""
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <title>慢查询分析报告</title>
            <style>
                body {{ font-family: 'Segoe UI', Arial, sans-serif; margin: 0; padding: 20px; background-color: #f5f7fa; color: #333; }}
                section {{ background: white; border-radius: 8px; padding: 25px; margin-bottom: 30px; box-shadow: 0 2px 12px rgba(0,0,0,0.08); border-left: 4px solid #2c80ff; }}
                h1, h2, h3, h4 {{ color: #2c3e50; margin-top: 0; }}
                h1 {{ border-bottom: 3px solid #3498db; padding-bottom: 10px; }}
                h2 {{ border-bottom: 2px solid #ecf0f1; padding-bottom: 8px; }}
                h3 {{ color: #34495e; }}
                #report-nav {{ background: linear-gradient(135deg, #2c3e50 0%, #4a6491 100%); color: white; padding: 25px; border-radius: 10px; margin-bottom: 30px; box-shadow: 0 4px 15px rgba(0,0,0,0.1); }}
                #report-nav h2 {{ color: white; border: none; margin-top: 0; }}
                .nav-links {{ display: flex; gap: 20px; margin: 20px 0; flex-wrap: wrap; }}
                .nav-links a {{ background: rgba(255,255,255,0.15); color: white; padding: 12px 24px; border-radius: 6px; text-decoration: none; font-weight: bold; transition: all 0.3s ease; border: 1px solid rgba(255,255,255,0.2); }}
                .nav-links a:hover {{ background: rgba(255,255,255,0.25); transform: translateY(-2px); box-shadow: 0 4px 8px rgba(0,0,0,0.2); }}
                .report-meta {{ background: rgba(0,0,0,0.2); padding: 15px; border-radius: 6px; margin-top: 20px; font-size: 0.95em; }}
                .summary-stats {{ margin: 20px 0; }}
                .stats-grid {{ display: flex; flex-wrap: wrap; gap: 10px; margin-top: 15px; }}
                .stat-item {{ background: #f8f9fa; padding: 8px 12px; border-radius: 6px; border-left: 4px solid #007bff; box-shadow: 0 1px 3px rgba(0,0,0,0.05); display: flex; align-items: center; gap: 8px; }}
                .range-name {{ font-weight: bold; }}
                .range-count {{ color: #2c3e50; }}
                .range-percent {{ color: #7f8c8d; font-size: 0.85em; }}
                .chart-container {{ background: white; border: 1px solid #ddd; border-radius: 8px; padding: 20px; margin: 25px auto; box-shadow: 0 2px 8px rgba(0,0,0,0.05); max-width: 800px; }}
                .chart-title {{ margin-top: 0; color: #34495e; text-align: center; }}
                .chart-box {{ width: 100%; height: 400px; position: relative; overflow: visible; display: flex; justify-content: center; align-items: center; }}
                .line-charts-row {{ display: flex; flex-wrap: wrap; gap: 20px; margin: 20px 0; }}
                .line-charts-row .chart-container {{ flex: 1; min-width: 600px; margin: 0; }}
                .top10-container {{ display: grid; grid-template-columns: repeat(2, 1fr); gap: 25px; margin-top: 20px; }}
                .top10-section {{ background: #f8f9fa; padding: 20px; border-radius: 8px; border-top: 4px solid #3498db; }}
                .top10-table {{ width: 100%; border-collapse: collapse; margin-top: 10px; font-size: 0.9em; }}
                .top10-table th {{ background: #2c80ff; color: white; padding: 10px; text-align: left; }}
                .top10-table td {{ padding: 8px 10px; border-bottom: 1px solid #eee; }}
                .top10-table tr:hover {{ background: #e3f2fd; }}
                .time-dimension {{ margin-bottom: 40px; }}
                .time-range-note {{ background: #e8f4fc; padding: 10px 15px; border-radius: 6px; margin: 15px 0; border-left: 4px solid #3498db; }}
                .period-table-wrapper {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(350px, 1fr)); gap: 15px; align-items: start; }}
                .period-table {{ width: 100%; border-collapse: collapse; margin-top: 10px; table-layout: auto; }}
                .period-table th {{ background: #34495e; color: white; padding: 5px 8px; text-align: left; font-size: 0.95em; white-space: nowrap; }}
                .period-table td {{ padding: 4px 8px; border-bottom: 1px solid #ddd; font-size: 0.95em; word-break: break-all; text-align: left; }}
                .period-table td:first-child {{ white-space: nowrap; }}
                .period-table tr:hover {{ background: #ecf0f1; }}
                .detail-table {{ width: 100%; border-collapse: collapse; margin-top: 15px; }}
                .detail-table th {{ background: #2c3e50; color: white; padding: 12px 15px; text-align: left; position: sticky; top: 0; z-index: 10; }}
                .detail-table td {{ padding: 10px 15px; border: 1px solid #000; vertical-align: top; background-color: transparent; }}
                .detail-table tr:hover {{ background-color: rgba(227, 242, 253, 0.3) !important; }}
                .detail-table tr.highlighted {{ background-color: rgba(255, 235, 59, 0.4) !important; box-shadow: 0 0 10px rgba(255, 235, 59, 0.5); transition: all 0.3s ease; }}
                details {{ margin: 10px 0; }}
                summary {{ cursor: pointer; font-weight: bold; color: white; background: #007bff; padding: 8px 15px; border-radius: 5px; display: inline-block; transition: all 0.3s; border: none; outline: none; }}
                summary:hover {{ background: #0056b3; transform: translateY(-1px); box-shadow: 0 3px 6px rgba(0,0,0,0.15); }}
                .duration-info {{ background: #f8f9fa; padding: 15px; border-radius: 5px; margin-top: 10px; border-left: 4px solid #007bff; }}
                pre {{ background: #f5f5f5; padding: 15px; border-radius: 5px; border: 1px solid #ddd; overflow-x: auto; max-height: 500px; font-family: 'Consolas', 'Monaco', monospace; font-size: 0.9em; line-height: 1.4; }}
                .copy-btn {{ background: #4CAF50; color: white; border: none; padding: 6px 12px; border-radius: 4px; cursor: pointer; font-size: 0.85em; margin: 0 5px; transition: all 0.2s; }}
                .copy-btn:hover {{ background: #45a049; transform: translateY(-1px); }}
                .uid-link {{ color: #007bff; text-decoration: none; font-weight: bold; }}
                .uid-link:hover {{ text-decoration: underline; color: #0056b3; }}
                .back-to-top {{ display: inline-block; padding: 6px 12px; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; text-decoration: none; border-radius: 20px; font-size: 13px; font-weight: bold; transition: all 0.3s ease; box-shadow: 0 2px 5px rgba(0,0,0,0.2); }}
                .back-to-top:hover {{ transform: translateY(-2px); box-shadow: 0 4px 8px rgba(0,0,0,0.3); background: linear-gradient(135deg, #764ba2 0%, #667eea 100%); }}
                .search-box {{ display: flex; align-items: center; gap: 8px; }}
                .search-box input {{ padding: 8px 12px; border: 2px solid #e0e0e0; border-radius: 6px; font-size: 14px; width: 250px; transition: all 0.3s ease; }}
                .search-box input:focus {{ outline: none; border-color: #667eea; box-shadow: 0 0 0 3px rgba(102, 126, 234, 0.2); }}
                .search-box button {{ padding: 8px 12px; border: none; color: white; border-radius: 6px; cursor: pointer; font-size: 18px; font-weight: bold; transition: all 0.3s ease; min-width: 36px; text-align: center; }}
                .search-box .btn-confirm {{ background: #27ae60; line-height: 1; }}
                .search-box .btn-confirm:hover {{ background: #219a52; }}
                .search-box .btn-reset {{ background: #e74c3c; line-height: 1; }}
                .search-box .btn-reset:hover {{ background: #c0392b; }}
                .row-hidden {{ display: none !important; }}
                .series-hidden {{ display: none !important; }}
                .chart-legend {{ display: flex; flex-wrap: wrap; gap: 10px; margin: 15px 0; padding: 10px; background: #f8f9fa; border-radius: 5px; }}
                .legend-item {{ display: flex; align-items: center; margin-right: 15px; }}
                .legend-color {{ width: 15px; height: 15px; margin-right: 5px; border-radius: 3px; }}
                @media (max-width: 768px) {{ .stats-grid {{ grid-template-columns: 1fr; }} .top10-container {{ grid-template-columns: 1fr; }} .nav-links {{ flex-direction: column; }} .nav-links a {{ width: 100%; text-align: center; }} .period-table-wrapper {{ column-count: 1; }} }}
                @media (min-width: 769px) {{ .period-table-wrapper {{ column-count: 2; }} }}
            </style>
        </head>
        <body>
            {nav_html}
            {summary_section}
            {time_analysis_section}
            {detail_section}
            <script>
                const chartData = {chart_js_data_json};
                function copyToClipboard(text) {{
                    if (navigator.clipboard && window.isSecureContext) {{
                        navigator.clipboard.writeText(text).then(() => {{ alert('SQL已复制到剪贴板!'); }}, (err) => {{ console.error('无法复制文本: ', err); }});
                    }} else {{
                        const textArea = document.createElement("textarea");
                        textArea.value = text;
                        textArea.style.position = "fixed";
                        textArea.style.left = "-999999px";
                        textArea.style.top = "-999999px";
                        document.body.appendChild(textArea);
                        textArea.focus();
                        textArea.select();
                        try {{ document.execCommand('copy'); alert('SQL已复制到剪贴板!'); }} catch (err) {{ console.error('无法复制文本: ', err); }}
                        document.body.removeChild(textArea);
                    }}
                }}
                function generatePreparedStatement(button) {{
                    const queryTemplate = button.getAttribute('data-query-template');
                    const executeStmt = button.getAttribute('data-execute-stmt');
                    const paramPattern = /\\$(\\d+)/g;
                    const matches = [];
                    let match;
                    while ((match = paramPattern.exec(queryTemplate)) !== null) {{ matches.push(parseInt(match[1])); }}
                    const paramTypes = Array(matches.length).fill('text');
                    const paramTypesStr = paramTypes.join(', ');
                    const preparedName = 'bind_sql';
                    const prepareStmt = `prepare ${{preparedName}}(${{paramTypesStr}}) as ${{queryTemplate.trim()}};`;
                    const fullStmt = prepareStmt + '\\n' + executeStmt;
                    if (navigator.clipboard && window.isSecureContext) {{
                        navigator.clipboard.writeText(fullStmt).then(() => {{ alert('Prepared语句已复制到剪贴板!\\n 默认全部使用的text类型，注意语句中的实际数据类型'); }}, (err) => {{ console.error('无法复制文本: ', err); }});
                    }} else {{
                        const textArea = document.createElement("textarea");
                        textArea.value = fullStmt;
                        textArea.style.position = "fixed";
                        textArea.style.left = "-999999px";
                        textArea.style.top = "-999999px";
                        document.body.appendChild(textArea);
                        textArea.focus();
                        textArea.select();
                        try {{ document.execCommand('copy'); alert('Prepared语句已复制到剪贴板!\\n 默认全部使用的text类型，注意语句中的实际数据类型'); }} catch (err) {{ console.error('无法复制文本: ', err); }}
                        document.body.removeChild(textArea);
                    }}
                }}
                function renderPieChart(containerId, data) {{
                    const container = document.getElementById(containerId);
                    if (!container || data.length === 0) return;
                    const width = 400, height = 400;
                    const radius = Math.min(width, height) / 2 - 20;
                    const centerX = width / 2, centerY = height / 2;
                    let svg = `<svg width="${{width}}" height="${{height}}" viewBox="0 0 ${{width}} ${{height}}">`;
                    const total = data.reduce((sum, item) => sum + item.count, 0);
                    let startAngle = 0;
                    data.forEach(item => {{
                        const percent = item.count / total;
                        const endAngle = startAngle + percent * 2 * Math.PI;
                        const x1 = centerX + radius * Math.cos(startAngle);
                        const y1 = centerY + radius * Math.sin(startAngle);
                        const x2 = centerX + radius * Math.cos(endAngle);
                        const y2 = centerY + radius * Math.sin(endAngle);
                        const largeArcFlag = percent > 0.5 ? 1 : 0;
                        const pathData = [`M ${{centerX}} ${{centerY}}`,`L ${{x1}} ${{y1}}`,`A ${{radius}} ${{radius}} 0 ${{largeArcFlag}} 1 ${{x2}} ${{y2}}`,'Z'].join(' ');
                        svg += `<path d="${{pathData}}" fill="${{item.color}}" stroke="white" stroke-width="2" data-name="${{item.name}}" data-count="${{item.count}}" data-percent="${{(percent*100).toFixed(1)}}%" onmouseover="showTooltip(event, '${{item.name}}: ${{item.count}}条 (${{(percent*100).toFixed(1)}}%)')" onmouseout="hideTooltip()">`;
                        svg += `<title>${{item.name}}: ${{item.count}}条 (${{(percent*100).toFixed(1)}}%)</title></path>`;
                        startAngle = endAngle;
                    }});
                    svg += `<circle cx="${{centerX}}" cy="${{centerY}}" r="${{radius*0.3}}" fill="white" stroke="#ddd" stroke-width="1"/><text x="${{centerX}}" y="${{centerY-10}}" text-anchor="middle" font-weight="bold" font-size="16">总计</text><text x="${{centerX}}" y="${{centerY+15}}" text-anchor="middle" font-size="14">${{total}} 条</text></svg>`;
                    container.innerHTML = svg;
                }}
                function renderLineChart(containerId, chartData, title) {{
                    const container = document.getElementById(containerId);
                    if (!container || !chartData.series || chartData.series.length === 0) return;
                    const timeLabels = chartData.time_labels;
                    if (!timeLabels || timeLabels.length < 2) {{
                        container.innerHTML = '<div style="padding: 20px; text-align: center; color: #999;">数据点不足，无法生成折线图（至少需要2个时间点）</div>';
                        return;
                    }}
                    const hasValidData = chartData.series.some(s => {{
                        const validPoints = s.data.filter(v => v > 0).length;
                        return validPoints >= 2;
                    }});
                    if (!hasValidData) {{
                        container.innerHTML = '<div style="padding: 20px; text-align: center; color: #999;">有效数据点不足，无法生成折线图</div>';
                        return;
                    }}
                    const width = 800, height = 400;
                    const margin = {{top: 30, right: 150, bottom: 50, left: 60}};
                    const chartWidth = width - margin.left - margin.right;
                    const chartHeight = height - margin.top - margin.bottom;
                    const allValues = chartData.series.flatMap(s => s.data);
                    const maxValue = Math.max(...allValues);
                    let lastValidIndex = timeLabels.length - 1;
                    const allLastZero = chartData.series.every(s => s.data[s.data.length - 1] === 0);
                    if (allLastZero && lastValidIndex > 0) lastValidIndex--;
                    let svg = `<svg width="${{width}}" height="${{height}}" viewBox="0 0 ${{width}} ${{height}}">`;
                    const xScale = chartWidth / (lastValidIndex || 1);
                    const yScale = chartHeight / (maxValue || 1);
                    for (let i = 0; i <= 5; i++) {{
                        const y = margin.top + chartHeight - (i * chartHeight / 5);
                        const value = (i * maxValue / 5).toFixed(1);
                        svg += `<line x1="${{margin.left}}" y1="${{y}}" x2="${{margin.left + chartWidth}}" y2="${{y}}" stroke="#eee" stroke-width="1"/><text x="${{margin.left - 10}}" y="${{y + 4}}" text-anchor="end" font-size="12" fill="#666">${{value}}</text>`;
                    }}
                    const labelInterval = Math.ceil((lastValidIndex + 1) / 10) || 1;
                    for (let i = 0; i <= lastValidIndex; i += labelInterval) {{
                        const x = margin.left + i * xScale;
                        svg += `<text x="${{x}}" y="${{margin.top + chartHeight + 20}}" text-anchor="middle" font-size="11" fill="#666" transform="rotate(45, ${{x}}, ${{margin.top + chartHeight + 20}})">${{timeLabels[i]}}</text><line x1="${{x}}" y1="${{margin.top + chartHeight}}" x2="${{x}}" y2="${{margin.top + chartHeight + 5}}" stroke="#666" stroke-width="1"/>`;
                    }}
                    chartData.series.forEach(series => {{
                        if (series.data.length === 0) return;
                        let endIndex = lastValidIndex;
                        if (endIndex < 0) return;
                        let pathData = `M ${{margin.left}} ${{margin.top + chartHeight - series.data[0] * yScale}}`;
                        for (let i = 1; i <= endIndex; i++) {{
                            const x = margin.left + i * xScale;
                            const y = margin.top + chartHeight - series.data[i] * yScale;
                            const prevX = margin.left + (i-1) * xScale;
                            const prevY = margin.top + chartHeight - series.data[i-1] * yScale;
                            const cp1x = prevX + xScale * 0.3;
                            const cp1y = prevY;
                            const cp2x = x - xScale * 0.3;
                            const cp2y = y;
                            pathData += ` C ${{cp1x}} ${{cp1y}}, ${{cp2x}} ${{cp2y}}, ${{x}} ${{y}}`;
                        }}
                        svg += `<path d="${{pathData}}" fill="none" stroke="${{series.color}}" stroke-width="3" data-uid="${{series.uid}}" onmouseover="highlightLine('${{series.uid}}')" onmouseout="unhighlightLine('${{series.uid}}')" onclick="clickLine('${{series.uid}}')" style="cursor: pointer;"/>`;
                        for (let i = 0; i <= lastValidIndex; i++) {{
                            if (series.data[i] > 0) {{
                                const x = margin.left + i * xScale;
                                const y = margin.top + chartHeight - series.data[i] * yScale;
                                svg += `<circle cx="${{x}}" cy="${{y}}" r="4" fill="${{series.color}}" data-uid="${{series.uid}}" data-index="${{i}}" data-value="${{series.data[i]}}" onmouseover="showPointTooltip(event, '${{series.uid}}', '${{timeLabels[i]}}', ${{series.data[i]}})" onmouseout="hidePointTooltip()"/>`;
                            }}
                        }}
                    }});
                    let legendY = margin.top;
                    chartData.series.forEach(series => {{
                        svg += `<g class="chart-legend-item" data-uid="${{series.uid}}"><rect x="${{margin.left + chartWidth + 20}}" y="${{legendY}}" width="15" height="15" fill="${{series.color}}"/><text x="${{margin.left + chartWidth + 40}}" y="${{legendY + 12}}" font-size="12">${{series.uid}}</text></g>`;
                        legendY += 20;
                    }});
                    svg += `<text x="${{width/2}}" y="${{margin.top - 10}}" text-anchor="middle" font-size="16" font-weight="bold">${{title}}</text><text x="${{width/2}}" y="${{height - 10}}" text-anchor="middle" font-size="14">时间</text><text x="10" y="${{height/2}}" text-anchor="middle" font-size="14" transform="rotate(-90, 10, ${{height/2}}) translate(0, -20)">执行次数</text></svg>`;
                    container.innerHTML = svg;
                }}
                function highlightLine(uid) {{
                    document.querySelectorAll(`[data-uid='${{uid}}']`).forEach(el => {{
                        if (el.tagName === 'path') {{ el.style.strokeWidth = '5'; el.style.filter = 'drop-shadow(0 0 3px rgba(0,0,0,0.3))'; }}
                    }});
                    showTooltip(event, `Unique ID: ${{uid}}`);
                }}
                function unhighlightLine(uid) {{
                    document.querySelectorAll(`[data-uid='${{uid}}']`).forEach(el => {{
                        if (el.tagName === 'path') {{ el.style.strokeWidth = '3'; el.style.filter = 'none'; }}
                    }});
                    hideTooltip();
                }}
                function clickLine(uid) {{
                    const detailRow = document.getElementById(`detail-${{uid}}`);
                    if (detailRow) {{
                        document.querySelectorAll('.detail-table tr.highlighted').forEach(row => row.classList.remove('highlighted'));
                        detailRow.classList.add('highlighted');
                        detailRow.scrollIntoView({{behavior: 'smooth', block: 'center'}});
                        setTimeout(() => detailRow.classList.remove('highlighted'), 3000);
                    }}
                }}
                function showTooltip(event, text) {{
                    let tooltip = document.getElementById('chart-tooltip');
                    if (!tooltip) {{
                        tooltip = document.createElement('div');
                        tooltip.id = 'chart-tooltip';
                        tooltip.style.cssText = 'position: absolute; background: rgba(0,0,0,0.8); color: white; padding: 5px 10px; border-radius: 4px; font-size: 12px; pointer-events: none; z-index: 1000;';
                        document.body.appendChild(tooltip);
                    }}
                    tooltip.innerHTML = text;
                    tooltip.style.left = (event.pageX + 10) + 'px';
                    tooltip.style.top = (event.pageY - 30) + 'px';
                    tooltip.style.display = 'block';
                }}
                function hideTooltip() {{
                    const tooltip = document.getElementById('chart-tooltip');
                    if (tooltip) tooltip.style.display = 'none';
                }}
                function showPointTooltip(event, uid, time, value) {{
                    showTooltip(event, `${{uid}}<br>${{time}}<br>次数: ${{value}}`);
                }}
                function hidePointTooltip() {{ hideTooltip(); }}
                document.addEventListener('DOMContentLoaded', function() {{
                    if (chartData.summary_pie && chartData.summary_pie.length > 0) {{
                        const pieContainer = document.createElement('div');
                        pieContainer.className = 'chart-container pie-layout';
                        pieContainer.innerHTML = '<h3 class="chart-title" style="width:100%;text-align:center;">慢SQL耗时分布饼图</h3><div class="chart-box" id="pie-chart"></div>';
                        const summarySection = document.querySelector('#summary-section');
                        const top10Heading = Array.from(summarySection.querySelectorAll('h3')).find(h => h.textContent.includes('Top 10'));
                        if (top10Heading) summarySection.insertBefore(pieContainer, top10Heading);
                        else summarySection.appendChild(pieContainer);
                        renderPieChart('pie-chart', chartData.summary_pie);
                        const legend = document.createElement('div');
                        legend.className = 'chart-legend vertical';
                        chartData.summary_pie.forEach(item => {{
                            legend.innerHTML += `<div class="legend-item"><div class="legend-color" style="background-color: ${{item.color}};"></div><span>${{item.name}} (${{item.count}}条, ${{item.percent.toFixed(1)}}%)</span></div>`;
                        }});
                        pieContainer.appendChild(legend);
                    }}
                    const timeAnalysisSection = document.querySelector('#time-analysis-section');
                    const dimOrder = ['by_minute', 'by_10minute', 'by_hour', 'by_day'];
                    const dimNames = {{ 'by_minute': '每分钟慢SQL执行趋势 (Top 10)', 'by_10minute': '每10分钟慢SQL执行趋势 (Top 10)', 'by_hour': '每小时慢SQL执行趋势 (Top 10)', 'by_day': '每日慢SQL执行趋势 (Top 10)' }};
                    const allCharts = [];
                    for (const dimKey of dimOrder) {{
                        if (chartData.time_analysis[dimKey] && chartData.time_analysis[dimKey].time_labels && chartData.time_analysis[dimKey].time_labels.length > 0 && chartData.time_analysis[dimKey].series && chartData.time_analysis[dimKey].series.length > 0) {{
                            allCharts.push({{ id: dimKey.replace('by_', '') + '-chart', title: dimNames[dimKey] || dimKey.replace('by_', '') + '慢SQL执行趋势 (Top 10)', data: chartData.time_analysis[dimKey], chartTitle: (dimNames[dimKey] || dimKey.replace('by_', '')).replace(' (Top 10)', '') }});
                        }}
                    }}
                    for (const dimKey in chartData.time_analysis) {{
                        if (!dimOrder.includes(dimKey) && chartData.time_analysis[dimKey] && chartData.time_analysis[dimKey].time_labels && chartData.time_analysis[dimKey].time_labels.length > 0 && chartData.time_analysis[dimKey].series && chartData.time_analysis[dimKey].series.length > 0) {{
                            const dimName = dimKey.replace('by_', '').replace('minute', '分钟');
                            allCharts.push({{ id: dimKey.replace('by_', '') + '-chart', title: `每${{dimName}}慢SQL执行趋势 (Top 10)`, data: chartData.time_analysis[dimKey], chartTitle: `每${{dimName}}慢SQL执行趋势` }});
                        }}
                    }}
                    allCharts.sort((a, b) => {{
                        const getInterval = (id) => {{
                            const match = id.match(/(\\d+)?minute/);
                            if (match) return match[1] ? parseInt(match[1]) : 1;
                            else if (id.includes('hour')) return 60;
                            else if (id.includes('day')) return 1440;
                            return 9999;
                        }};
                        return getInterval(a.id) - getInterval(b.id);
                    }});
                    for (let i = 0; i < allCharts.length; i += 2) {{
                        const rowCharts = allCharts.slice(i, i + 2);
                        const rowContainer = document.createElement('div');
                        rowContainer.className = 'line-charts-row';
                        rowCharts.forEach(chart => {{
                            const chartContainer = document.createElement('div');
                            chartContainer.className = 'chart-container';
                            chartContainer.innerHTML = `<h3 class="chart-title">${{chart.title}}</h3><div class="chart-box" id="${{chart.id}}"></div>`;
                            rowContainer.appendChild(chartContainer);
                        }});
                        timeAnalysisSection.appendChild(rowContainer);
                        rowCharts.forEach(chart => {{ renderLineChart(chart.id, chart.data, chart.chartTitle); }});
                    }}
                    function highlightTargetRow() {{
                        const hash = window.location.hash;
                        if (hash && hash.startsWith('#detail-')) {{
                            document.querySelectorAll('.detail-table tr.highlighted').forEach(row => row.classList.remove('highlighted'));
                            const targetId = hash.substring(1);
                            const targetRow = document.getElementById(targetId);
                            if (targetRow) {{
                                targetRow.classList.add('highlighted');
                                targetRow.scrollIntoView({{ behavior: 'smooth', block: 'center' }});
                                setTimeout(() => targetRow.classList.remove('highlighted'), 3000);
                            }}
                        }}
                    }}
                    highlightTargetRow();
                    window.addEventListener('hashchange', highlightTargetRow);
                }});
                function filterByUniqueId(searchTerm) {{
                    searchTerm = searchTerm.trim().toLowerCase();
                    document.querySelectorAll('.period-table tr').forEach(row => {{
                        if (row.querySelector('th')) return;
                        let uidCell = row.querySelector('td:nth-child(2) a.uid-link');
                        if (!uidCell) uidCell = row.querySelector('td:nth-child(3) a.uid-link');
                        if (!uidCell) uidCell = row.querySelector('td:nth-child(2)');
                        if (!uidCell) uidCell = row.querySelector('td:nth-child(3)');
                        if (uidCell) {{
                            const uid = uidCell.textContent.trim().toLowerCase();
                            if (searchTerm === '' || uid.includes(searchTerm)) {{
                                row.classList.remove('row-hidden');
                                row.style.display = '';
                            }} else {{
                                row.classList.add('row-hidden');
                                row.style.display = 'none';
                            }}
                        }}
                    }});
                    filterChartSeries(searchTerm);
                }}
                function filterChartSeries(searchTerm) {{
                    document.querySelectorAll('.chart-box').forEach(chartBox => {{
                        chartBox.querySelectorAll('.chart-legend-item').forEach(legendItem => {{
                            const uid = legendItem.getAttribute('data-uid');
                            if (uid) {{
                                if (searchTerm === '' || uid.toLowerCase().includes(searchTerm)) legendItem.classList.remove('series-hidden');
                                else legendItem.classList.add('series-hidden');
                            }}
                        }});
                        chartBox.querySelectorAll('svg path[data-uid]').forEach(path => {{
                            const uid = path.getAttribute('data-uid');
                            if (uid) {{
                                if (searchTerm === '' || uid.toLowerCase().includes(searchTerm)) {{
                                    path.classList.remove('series-hidden');
                                    path.style.opacity = '1';
                                }} else {{
                                    path.classList.add('series-hidden');
                                    path.style.opacity = '0';
                                }}
                            }}
                        }});
                        chartBox.querySelectorAll('svg circle[data-uid]').forEach(circle => {{
                            const uid = circle.getAttribute('data-uid');
                            if (uid) {{
                                if (searchTerm === '' || uid.toLowerCase().includes(searchTerm)) {{
                                    circle.classList.remove('series-hidden');
                                    circle.style.opacity = '1';
                                }} else {{
                                    circle.classList.add('series-hidden');
                                    circle.style.opacity = '0';
                                }}
                            }}
                        }});
                    }});
                }}
                function applySearch() {{
                    const searchValue = document.getElementById('unique-id-search').value;
                    filterByUniqueId(searchValue);
                }}
                function clearSearch() {{
                    document.getElementById('unique-id-search').value = '';
                    filterByUniqueId('');
                }}
            </script>
        </body>
        </html>
        """
        return full_html

def parse_slow_sql(start_n, blocks, total_list, total_elapsed_time=0, log_format_info=None):
    total_blocks = len(blocks) // 2
    processed = 0
    start_time = datetime.now()
    if log_format_info is None:
        log_format_info = parse_log_prefix_format('%m %u %d %r %p %S')
    parse_func = log_format_info['parse_func']
    for i in range(start_n, len(blocks), 2):
        processed += 1
        if processed % 5000 == 0:
            show_progress(processed, total_blocks, "解析慢查询", start_time, total_elapsed_time)
        timestamp = parse_datetime(blocks[i])
        log_block = blocks[i + 1]
        if "duration:" in log_block and ("execute" in log_block or "statement:" in log_block):
            try:
                match = EXEC_PATTERN.search(log_block)
                if match:
                    full_prefix_part = log_block[:match.start()].strip()
                else:
                    full_prefix_part = log_block.strip()
                parsed_line = parse_func(full_prefix_part)
                if parsed_line is None:
                    content0 = SPLIT_PATTERN.split(full_prefix_part)
                    IP, database, user = _parse_log_fallback(content0, log_format_info)
                    if not IP and not database and not user:
                        continue
                else:
                    IP = parsed_line.get('remote_host', '')
                    database = parsed_line.get('database', '')
                    user = parsed_line.get('user', '')
                query_content = EXEC_PATTERN.split(log_block)
                if len(query_content) < 4:
                    continue
                duration_match = DURATION_EXTRACT_PATTERN.search(log_block)
                if duration_match:
                    duration = float(duration_match.group(1))
                else:
                    duration_str_parts = SPLIT_PATTERN.split(query_content[1])
                    if len(duration_str_parts) < 2:
                        continue
                    duration = float(duration_str_parts[1].strip()) / 1000
                query_text, unique_id = query_content[3], query_content[2].strip()
                query_text = query_text.strip()
                sql_keywords = ('SELECT', 'INSERT', 'UPDATE', 'DELETE', 'CREATE', 'DROP', 'ALTER', 'TRUNCATE', 'COPY', 'WITH', 'BEGIN', 'COMMIT', 'ROLLBACK', 'SET', 'MERGE', 'CALL', 'EXECUTE', 'VACUUM', 'ANALYZE', 'REINDEX', 'CLUSTER', 'REFRESH', 'PREPARE', 'DEALLOCATE', 'DISCARD', 'LISTEN', 'NOTIFY', 'UNLISTEN', 'SHOW', 'GRANT', 'REVOKE', 'SAVEPOINT', 'RELEASE', 'LOCK', 'UNLOCK')
                stripped_text = query_text.lstrip()
                if not any(stripped_text.upper().startswith(keyword) for keyword in sql_keywords):
                    first_space_pos = stripped_text.find(' ')
                    if first_space_pos > 0:
                        query_text = stripped_text[first_space_pos:].strip()
                    else:
                        query_text = stripped_text
                else:
                    query_text = stripped_text
                v_params = ''
                if i + 3 < len(blocks) and "parameters:" in blocks[i + 3]:
                    try:
                        v_params = PARAMETERS_PATTERN.split(blocks[i + 3])[1].strip()
                    except IndexError:
                        v_params = ''
                total_list.append({
                    'time': timestamp, 'qry_text': query_text, 'qry_params': v_params,
                    'IP': IP, 'database': database, 'user': user, 'duration': duration, 'unique_id': unique_id
                })
            except (IndexError, ValueError, Exception) as e:
                continue
    show_progress(total_blocks, total_blocks, "解析慢查询", start_time, total_elapsed_time)
    gc.collect()

def main():
    parser = argparse.ArgumentParser(description='Vastbase/PostgreSQL 慢查询日志分析工具')
    parser.add_argument('-f', '--file', type=str, nargs='+', help="输入日志文件路径")
    parser.add_argument('-b', '--begin', type=str, help="分析开始时间")
    parser.add_argument('-e', '--end', type=str, help="分析结束时间")
    parser.add_argument('-p', '--prefix', type=str, help="日志行前缀格式")
    parser.add_argument('--diff', type=str, default='1d', help="对比时间间隔")
    parser.add_argument('-v', '--version', action='store_true', help="显示版本信息")
    args = parser.parse_args()
    file_names = args.file
    if args.version:
        print("The version is 1.5")
        sys.exit(0)
    log_prefix = args.prefix
    if not log_prefix:
        print("未指定日志前缀格式，尝试从数据库获取...")
        log_prefix = get_log_line_prefix()
        if log_prefix:
            print(f"从数据库获取到日志前缀格式: {log_prefix}")
        else:
            print("无法从数据库获取日志前缀格式，使用默认格式")
            log_prefix = '%m %u %d %r %p %S [%x]'
    else:
        print(f"使用指定的日志前缀格式: {log_prefix}")
    diff_interval = parse_diff_interval(args.diff)
    if not args.file:
        print("未指定日志文件，尝试自动获取数据库日志目录...")
        log_directory = get_db_log_directory()
        if log_directory:
            print(f"获取到日志目录: {log_directory}")
            begin_time = None
            end_time = None
            if args.begin:
                begin_time = parse_datetime(args.begin)
            if args.end:
                end_time = parse_datetime(args.end)
            if begin_time or end_time:
                recent_files = find_recent_log_files(log_directory, days=7, begin_time=begin_time, end_time=end_time)
                if recent_files:
                    print(f"找到 {len(recent_files)} 个指定时间范围内的日志文件:")
                    for i, file_name in enumerate(recent_files, 1):
                        print(f"  {i}. {file_name}")
                    file_names = recent_files
                else:
                    print("在指定时间范围内未找到日志文件")
                    sys.exit(1)
            else:
                recent_files = find_recent_log_files(log_directory, days=7)
                if recent_files:
                    print(f"找到 {len(recent_files)} 个最近的日志文件:")
                    for i, file_name in enumerate(recent_files, 1):
                        print(f"  {i}. {file_name}")
                    file_names = recent_files
                else:
                    print("在日志目录中未找到最近的日志文件")
                    sys.exit(1)
        else:
            print("无法获取数据库日志目录，请手动指定日志文件")
            sys.exit(1)
    else:
        file_names = expand_file_patterns(args.file)
        if not file_names:
            print("Error: No valid files found.")
            sys.exit(1)
        print(f"找到 {len(file_names)} 个文件:")
        for i, file_name in enumerate(file_names, 1):
            print(f"  {i}. {file_name}")
    log_format_info = parse_log_prefix_format(log_prefix)
    print(f"日志格式: {log_format_info['format_name']}")
    print(f"字段顺序: {', '.join(log_format_info['fields'])}")
    all_total_list, total_size_mb_all, total_elapsed_seconds_all = process_multiple_files(file_names, args, log_format_info)
    total_list = all_total_list
    total_list.sort(key=lambda x: x['unique_id'])
    grouped = {key: list(group) for key, group in groupby(total_list, key=lambda x: x['unique_id'])}
    stats = {}
    for unique_id, group in grouped.items():
        durations = [item['duration'] for item in group]
        times = [item['time'] for item in group]
        max_duration_item = max(group, key=lambda x: x['duration'])
        min_duration_item = min(group, key=lambda x: x['duration'])
        max_filled_query, max_param_values = fill_sql_params(max_duration_item['qry_text'], max_duration_item['qry_params'])
        min_filled_query, min_param_values = fill_sql_params(min_duration_item['qry_text'], min_duration_item['qry_params'])
        stats[unique_id] = {
            'max_duration': max(durations), 'min_duration': min(durations), 'avg_duration': mean(durations),
            'sum_duration': sum(durations), 'count': len(group), 'max_times': max(times), 'min_times': min(times),
            'qry_params': group[0]['qry_params'], 'IP': group[0]['IP'], 'database': group[0]['database'],
            'user': group[0]['user'], 'qry_text': group[0]['qry_text'], 'max_duration_query': max_filled_query,
            'min_duration_query': min_filled_query, 'max_param_values': max_param_values, 'min_param_values': min_param_values
        }
    sorted_data = sorted(stats.items(), key=lambda x: x[1]['sum_duration'], reverse=True)
    base_filename = get_base_filename_from_files(file_names)
    report_name = f"{base_filename}_slow_query_report"
    if args.begin and args.end:
        overall_min_time = parse_datetime(args.begin) if isinstance(args.begin, str) else args.begin
        overall_max_time = parse_datetime(args.end) if isinstance(args.end, str) else args.end
    else:
        all_times = []
        for unique_id, stat in sorted_data:
            all_times.append(stat['min_times'])
            all_times.append(stat['max_times'])
        overall_min_time = min(all_times) if all_times else "N/A"
        overall_max_time = max(all_times) if all_times else "N/A"
    summary_info = ReportGenerator.generate_sql_summary(stats, all_total_list)
    time_analysis_info = ReportGenerator.generate_time_analysis(all_total_list, overall_min_time, overall_max_time, diff_interval, args.diff)
    full_html = ReportGenerator.generate_full_html_report(
        sorted_data=sorted_data, summary_info=summary_info, time_analysis_info=time_analysis_info,
        overall_min_time=overall_min_time, overall_max_time=overall_max_time,
        total_size_mb_all=total_size_mb_all, total_elapsed_seconds_all=total_elapsed_seconds_all,
        all_total_list=all_total_list
    )
    with open(f"{report_name}.html", "w", encoding='utf-8') as f:
        f.write(full_html)
    print('成功导出增强版HTML报告到 {}.html'.format(report_name))

if __name__ == "__main__":
    main()
PYTHON_EOF

    # Execute the python script with the provided arguments
    python3 "$TEMP_SCRIPT" "$@"
    
    # Clean up
    rm -f "$TEMP_SCRIPT"
}
