#!/bin/bash
# Command: lsds - List block devices

run_lsds() {
    TEMP_SCRIPT=$(mktemp)
    cat << 'PYTHON_EOF' > "$TEMP_SCRIPT"
#!/usr/bin/env python3

import os
import sys
import re
from pathlib import Path

SYSFS_BASE = "/sys/class/block"
MODULE_BASE = "/sys/module"
SECTOR_SIZE = 512
VALUE_MISSING = "-"
FILTER_REGEX = r"(^dm|^loop|^[a-z]+\d+p\d+$|^[a-z]+\d+n\d+p\d+$)"

COLUMN_MAP = {
    "DEVNAME": {"source": "devname", "verbose_source": "{dev_path}"},
    "MAJ:MIN": {"source": "file", "path": "dev", "verbose_source": "{dev_path}/dev"},
    "SIZE": {"source": "size", "verbose_source": "{dev_path}/size * {sector_size}"},
    "RO": {"source": "file", "path": "ro", "verbose_source": "{dev_path}/ro"},
    "TYPE": {"source": "type", "verbose_source": "devname, {dev_path}/partition"},
    "SCHED": {"source": "scheduler", "verbose_source": "{dev_path}/queue/scheduler"},
    "NR_RQ": {"source": "file", "path": "queue/nr_requests", "verbose_source": "{dev_path}/queue/nr_requests"},
    "ROT": {"source": "file", "path": "queue/rotational", "verbose_source": "{dev_path}/queue/rotational"},
    "VENDOR": {"source": "file", "path": "device/vendor", "verbose_source": "{dev_path}/device/vendor"},
    "MODEL": {"source": "file", "path": "device/model", "verbose_source": "{dev_path}/device/model"},
    "QDEPTH": {"source": "qdepth", "verbose_source": "{dev_path}/device/queue_depth (N/A for NVMe)"},
    "WCACHE": {"source": "file", "path": "queue/write_cache", "verbose_source": "{dev_path}/queue/write_cache"},
    "FUA": {"source": "file", "path": "queue/fua", "verbose_source": "{dev_path}/queue/fua"},
    "HWSEC": {"source": "file", "path": "queue/hw_sector_size", "verbose_source": "{dev_path}/queue/hw_sector_size"},
}

DEFAULT_COLUMNS = ["DEVNAME", "MAJ:MIN", "SIZE", "TYPE", "SCHED", "ROT", "MODEL", "QDEPTH", "NR_RQ", "WCACHE"]

def read_sysfs_attr(base_path, attr_path_fragment, default=VALUE_MISSING):
    value = default
    status = "unknown"
    real_path_accessed = VALUE_MISSING

    if not base_path or not attr_path_fragment:
        return value, real_path_accessed, "no_path"

    full_path = os.path.join(base_path, attr_path_fragment)
    try:
        p = Path(full_path)
        if not p.exists():
            if p.is_symlink():
                real_path_accessed = str(p.resolve())
            else:
                real_path_accessed = str(p.absolute())
            status = "not_found"
            return value, real_path_accessed, status

        real_path_accessed = str(p.resolve())
        if not os.access(real_path_accessed, os.R_OK):
            status = "permission"
            return value, real_path_accessed, status

        with open(real_path_accessed, 'r') as f:
            value_read = f.read().strip()
            value = value_read if value_read else default
            status = "ok"

    except PermissionError:
        status = "permission"
    except FileNotFoundError:
        status = "not_found"
        real_path_accessed = str(Path(full_path).absolute())
    except NotADirectoryError:
        status = "not_found"
        real_path_accessed = str(Path(full_path).absolute())
    except OSError as e:
        status = "read_error"
        real_path_accessed = str(Path(full_path).absolute())

    return value, real_path_accessed, status

def parse_scheduler(raw_value, default=VALUE_MISSING):
    if raw_value == default or not isinstance(raw_value, str):
        return default
    match = re.search(r'\[(\w+(?:-\w+)?)\]', raw_value)
    return match.group(1) if match else raw_value

def human_readable_size(size_bytes, default=VALUE_MISSING):
    if not isinstance(size_bytes, (int, float)) or size_bytes < 0:
        return default
    if size_bytes == 0:
        return "0.0 GiB"
    power = 3
    unit = "GiB"
    size_converted = size_bytes / (1024 ** power)
    return f"{size_converted:.1f} {unit}"

def infer_device_type(device_name, dev_path):
    if device_name.startswith("loop"):
        return "Loop"
    if device_name.startswith("dm-"):
        return "DM"

    partition_file = os.path.join(dev_path, "partition")
    if os.path.exists(partition_file):
        if device_name.startswith("nvme"):
            return "NVMePart"
        else:
            return "Part"

    if device_name.startswith("nvme"):
        if re.match(r'^nvme\d+n\d+$', device_name):
            return "NVMeDisk"
        else:
            return "NVMeDev"

    if device_name.startswith("sd") or device_name.startswith("hd") or device_name.startswith("vd"):
        if re.match(r'^[svh]d[a-z]+$', device_name):
            return "Disk"

    return "BlockDev"

def get_qdepth_info(device, dev_path, device_type):
    if device_type.startswith("NVMe"):
        return VALUE_MISSING, "ok"

    dev_base_path = os.path.join(SYSFS_BASE, device)
    qdepth, real_path, status = read_sysfs_attr(dev_base_path, "device/queue_depth", default=VALUE_MISSING)

    if status == "not_found":
        scsi_device_path = os.path.join(dev_path, "device/scsi_device")
        if os.path.islink(scsi_device_path):
            try:
                real_scsi_path = os.path.realpath(scsi_device_path)
                qdepth_path = os.path.join(real_scsi_path, "queue_depth")
                if not os.path.exists(qdepth_path):
                    status = "not_found"
                elif not os.access(qdepth_path, os.R_OK):
                    status = "permission"
                else:
                    with open(qdepth_path, 'r') as f:
                        qdepth = f.read().strip()
                    status = "ok"
            except (FileNotFoundError, PermissionError, OSError):
                if isinstance(sys.exc_info()[1], PermissionError):
                    status = "permission"
    return qdepth, status

def get_block_devices(filter_pattern=None):
    try:
        devices = sorted(os.listdir(SYSFS_BASE))
        if filter_pattern is None:
            filter_pattern = FILTER_REGEX
        pattern = re.compile(filter_pattern)
        filtered_devices = [dev for dev in devices if not pattern.match(dev)]
        return filtered_devices
    except FileNotFoundError:
        print(f"Error: Sysfs block device directory not found at {SYSFS_BASE}", file=sys.stderr)
        sys.exit(1)
    except OSError as e:
        print(f"Error: Could not list block devices in {SYSFS_BASE}: {e}", file=sys.stderr)
        sys.exit(1)

def get_device_info(device, columns_to_get):
    dev_path = os.path.join(SYSFS_BASE, device)
    info = {}
    device_type = infer_device_type(device, dev_path)

    for col in columns_to_get:
        value = VALUE_MISSING
        source_description = VALUE_MISSING
        status = "unknown"

        if col not in COLUMN_MAP:
            value = "InvalidCol"
            source_description = "Internal Error"
            status = "error"
        else:
            device_info = COLUMN_MAP[col]
            source_type = device_info["source"]
            raw_source_tmpl = device_info.get("verbose_source", "Unknown Source")
            source_description = raw_source_tmpl.format(
                dev_path=dev_path, sysfs_base=SYSFS_BASE, module_base=MODULE_BASE,
                device=device, sector_size=SECTOR_SIZE
            )

            if source_type == "devname":
                value = device
                status = "ok"
            elif source_type == "type":
                value = device_type
                status = "inferred"
            elif source_type == "size":
                raw_size, real_path, read_status = read_sysfs_attr(dev_path, "size", default='0')
                status = read_status
                if status == 'ok':
                    try:
                        size_bytes = int(raw_size) * SECTOR_SIZE
                        value = human_readable_size(size_bytes, default=VALUE_MISSING)
                        status = "calculated" if value != VALUE_MISSING else "error"
                    except ValueError:
                        value = VALUE_MISSING
                        status = "error"
            elif source_type == "scheduler":
                raw_sched, real_path, read_status = read_sysfs_attr(dev_path, "queue/scheduler", default=VALUE_MISSING)
                status = read_status
                if status == 'ok':
                    value = parse_scheduler(raw_sched, default=VALUE_MISSING)
                    status = "parsed"
            elif source_type == "qdepth":
                value, status = get_qdepth_info(device, dev_path, device_type)
            elif source_type == "file":
                value, real_path, status = read_sysfs_attr(dev_path, device_info["path"], default=VALUE_MISSING)
            else:
                value = VALUE_MISSING
                status = "error"

        info[col] = {'value': value, 'source': source_description, 'status': status}

    return info

def main():
    selected_columns = list(DEFAULT_COLUMNS) + ["FUA", "HWSEC"]
    
    block_devices = get_block_devices()
    all_device_data = []
    
    for device in block_devices:
        device_data = get_device_info(device, selected_columns)
        all_device_data.append(device_data)

    if not all_device_data:
        print("No block devices found or accessible.")
        return

    display_data = []
    for info in all_device_data:
        row_data = {}
        for col in selected_columns:
            cell_info = info.get(col, {'value': VALUE_MISSING, 'source': VALUE_MISSING, 'status': 'error'})
            row_data[col] = str(cell_info['value'])
        display_data.append(row_data)

    widths = {col: len(col) for col in selected_columns}
    for row in display_data:
        for col in selected_columns:
            widths[col] = max(widths[col], len(row.get(col, '')))

    header = "  ".join(f"{col:<{widths[col]}}" for col in selected_columns)
    print(header)
    
    for row in display_data:
        row_str = "  ".join(f"{row.get(col, VALUE_MISSING):<{widths[col]}}" for col in selected_columns)
        print(row_str)

if __name__ == "__main__":
    main()
PYTHON_EOF

    if ! command -v python3 &> /dev/null; then
        echo "Error: python3 is required for lsds but not found" >&2
        rm -f "$TEMP_SCRIPT"
        exit 1
    fi

    python3 "$TEMP_SCRIPT"
    
    rm -f "$TEMP_SCRIPT"
}
