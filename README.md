# vb_tool

VastBase 数据库运维脚本工具集。

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

## 使用方法

```bash
vb_tool <command> [options]
```

查看完整帮助：

```bash
vb_tool --help
vb_tool list
```

## 命令列表

| 命令 | 说明 |
|------|------|
| `as [pid]` | 显示活跃会话信息 |
| `asp <type> -b <begin> -e <end>` | 活跃会话概要分析 (cnt/event/waitchain/sql) |
| `analyze_log` | 分析数据库日志 (慢查询或执行计划) |
| `analyze_log_v2` | 增强版日志分析，输出 HTML 报告 |
| `collect_log` | 收集集群或单节点日志 |
| `dead_tups` | 显示死元组信息 |
| `flamegraph` | 生成 CPU 火焰图 |
| `index_check` | 显示冗余/未使用/不可用索引 |
| `kill` | 按条件终止会话 |
| `lockchain` | 显示锁等待链 |
| `lock_details` | 显示锁详细信息 |
| `lsds` | 列出块设备和元数据 |
| `mem` | 显示内存使用信息 |
| `memhist` | 显示内存使用历史 |
| `net` | 显示网络信息 |
| `osw [interval] [duration]` | 收集系统性能数据 |
| `planbyline [file]` | 按行分析执行计划 |
| `priv` | 显示用户/表/库/模式权限 |
| `recover_table` | 通过 CTID 扫描恢复表数据 |
| `redo -f <log_file>` | 分析 Redo 日志 |
| `relxlog [START_WAL] [END_WAL]` | 分析关系的 WAL 记录 |
| `repl` | 显示流复制延迟 |
| `slow` | 显示 Top 慢 SQL |
| `sp [guc]` | 显示 GUC 参数 |
| `sqlhc [unique_query_id]` | SQL 健康检查 |
| `sqlstat [unique_query_id]` | 显示 SQL 统计信息 |
| `sqltext [unique_query_id]` | 从慢日志获取 SQL 文本 |
| `ssh_setup` | 配置主机间 SSH 连通性 |
| `st [relname]` | 显示表或视图 |
| `tabsize` | 显示 Top 表大小（含索引） |
| `tabstat` | 显示表统计信息 |
| `tps` | 分析 TPS（每10分钟） |
| `wdr_event` | 显示 WDR Top 事件 |
| `wdr_summary` | 显示 WDR 负载汇总 |
| `wdr_topsql` | 显示 WDR Top SQL |
| `wdr_tabstat` | 显示 WDR 表统计 |
| `workload [begin/end]` | 采集负载信息 |
| `xlogcom [START_WAL] [END_WAL]` | 分析 WAL 每秒提交数 |
| `xloghc` | 显示 XLOG 健康检查信息 |

## 依赖

- VastBase/openGauss 数据库 (`psql` 或 `gsql`)
- Python 3 (analyze_log_v2, lsds 等命令需要)
- 常用系统工具: `top`, `sar`, `iostat`, `free`, `df`, `ip`

## 项目结构

```
vb_tool/
├── vb_tool              # 主入口
├── lib/
│   ├── common.sh        # 公共工具函数
│   └── help.sh          # 帮助信息
└── commands/
    ├── as.sh            # 各命令模块
    ├── asp.sh
    ├── ...
    └── xlogcom.sh
```

## 版本

- v1.4.11 (2026-05-25)

## License

MIT License
