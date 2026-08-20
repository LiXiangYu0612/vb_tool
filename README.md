# vb_tool

VastBase 数据库运维脚本工具集（单文件 Bash 工具，23000+ 行）。

## 安装

```bash
git clone https://github.com/LiXiangYu0612/vb_tool.git
cd vb_tool
chmod +x vb_tool
```

将 `vb_tool` 加入 PATH 即可直接使用：

```bash
export PATH=/path/to/vb_tool:$PATH
```

> v1.4.12 起恢复**单文件发布**（`vb_tool` 即全部功能，无外部依赖文件）。
> v1.4.11 及之前的模块化结构（`commands/` + `lib/`）保留在 tag `v1.4.11` 中。

## 使用方法

```bash
vb_tool <command> [options]
```

查看完整帮助：

```bash
vb_tool --help
vb_tool list
```

## 命令列表（节选）

| 命令 | 说明 |
|------|------|
| `as [pid]` | 显示活跃会话信息 |
| `asp <type> -b <begin> -e <end>` | 活跃会话概要分析 (cnt/event/waitchain/sql) |
| `awr create` | 手动创建 AWR 单点快照 |
| `awr enable` / `awr disable` | 启停 cron 定时采样（间隔由 `awr config interval` 控制，默认 60 分钟） |
| `awr awrrpt begin <id> end <id>` | 生成两快照区间 AWR 报告 (HTML) |
| `awr awrdiff begin <a> end <b> begin <c> end <d>` | 两区间对比报告 |
| `awr list [YYYY-MM-DD]` | 快照清单（snap_id 倒序，默认最新 30 条；指定日期列出全天） |
| `awr show` | 总览：运行状态 / 采样间隔 / 保留期 / 最老最新快照 |
| `awr delete until <time>` | 手动按时间清理快照 / 采样日志 / HTML 报告 |
| `awr config retention <days>` | 保留期（默认 30 天，0=永久；改小立即清理过期数据） |
| `awr config interval <min>` | 采样间隔（1-60 分钟，默认 60；enabled 状态下改完即时生效） |
| `analyze_log` / `analyze_log_v2` | 数据库日志分析（v2 输出 HTML 报告） |
| `wdr_summary` / `wdr_topsql` / `wdr_tabstat` / `wdr_event` | WDR 报告数据提取分析 |
| `osw_netstat` | 解析 OSWbb oswnetstat 归档（v8/zzz/gz/批量） |
| `collect_log` | 收集集群或单节点日志 |
| `tps` / `tabstat` / `tabsize` / `sqlstat` | 性能与对象统计 |
| `lock_details` / `lockchain` | 锁等待分析 |
| `sqlhc` | SQL 健康检查（支持 .log/.csv 及其 .gz 压缩日志） |

完整命令见 `vb_tool list`。

## AWR 快照存储

默认 `~/.vb_tool/awrs/`（`VB_TOOL_HOME` 可覆盖）：

```
~/.vb_tool/awrs/
├── sequence                 # snap_id 序列
├── retention                # 保留天数（默认 30，0=永久）
├── interval                 # 采样间隔分钟（默认 60）
├── snap_<id>/               # 每快照: meta.json + os/ + db/*.csv
├── repl_<YYYYMMDD>.log      # pg_stat_replication 每分钟采样
└── slot_<YYYYMMDD>.log      # pg_replication_slots 每分钟采样
```

## 依赖

- VastBase/openGauss 数据库 (`psql` 或 `gsql`)
- Python 3（内嵌报告渲染等需要）
- 常用系统工具: `top`, `sar`, `iostat`, `free`, `df`, `ip`

## 版本历史

| 版本 | 日期 | 要点 |
|------|------|------|
| v1.4.18 | 2026-08-20 | `awr show` 新增 `last snap age` 存活提示（ENABLED 时显示 ok/STALE，防"crontab 还在但快照早停了"的静默故障）；修复 interval=60 时 `*/60` 触发 crontab 安装告警（改为 `0 * * * *`） |
| v1.4.17 | 2026-08-19 | 修复 `awr create -d` 报错文案：仍引导已移除的 `enable -d`，改为 `awr config interval <min>` + `awr enable` |
| v1.4.16 | 2026-08-19 | awr 增强：`list` 倒序+默认 30 条+按日期过滤；快照自动清理（保留期默认 30 天，`config retention`，0=永久，挂 create/enable 钩子）；采样间隔可配（`config interval`，enabled 下即时生效）；`awr show` 总览（吸收原 status 命令）；`enable` 移除 `-d` |
| v1.4.15 | 2026-08-18 | 修复 `GAUSSLOG` 检测：`env | grep -iw` 在 PWD/OLDPWD 含 "gausslog" 时误匹配拼坏路径，改为直接读环境变量 |
| v1.4.14 | 2026-08-18 | `sqlhc`/`sqltext` 支持压缩与轮转日志（.log.gz/.csv.gz，zgrep 预筛 + gzip 解析） |
| v1.4.13 | 2026-08-18 | awr 单点 snap 重构（Oracle 风格 snap_id + awrrpt/awrdiff + cron 采样，含 replication/slot 采样器与 `awr status`）；新增 `osw_netstat` |
| v1.4.12 | 2026-08-17 | awr 集成 baseline；恢复单文件发布 |
| v1.4.11 | 2026-05-25 | 模块化结构（commands/ + lib/） |

## License

MIT License
