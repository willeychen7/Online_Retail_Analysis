# Online Retail Analysis

用一家英国线上礼品零售商两年的交易数据（UCI Online Retail II，2009-12 至 2011-12，约 107 万行），完成一个从原始数据到商业建议的完整数据分析项目。

## 项目目标

模拟数据分析师在工作中的真实流程：

1. **把原始数据变成可信的数据**：检查数据质量，定下清洗规则，并说明每条规则的依据。
2. **搭建可持续更新的数据模型**：事实表加维度表（星型模型）。上游每周或每月给新数据时，增量追加，并自动检查、记录、标记问题。
3. **为不同的Team做看板**：管理层、Marketing、Product 团队关心的指标不同，看板也不同。
4. **从数据得出商业建议**：找出主要收入来源、增长和下降的市场、核心商品和潜力商品，并用统计方法验证结论。

## 数据

- 来源：[UCI Machine Learning Repository: Online Retail II](https://archive.ics.uci.edu/dataset/502/online+retail+ii)
- 字段：Invoice、StockCode、Description、Quantity、InvoiceDate、Price、Customer ID、Country
- 原始数据文件较大（约 45 MB），不放在仓库里，请从上面的链接下载。

## 工具分工

| 工具 | 做什么 |
|---|---|
| **R** | 数据探索（EDA），发现问题并定下清洗规则；之后做统计分析 |
| **PostgreSQL（SQL）** | 执行清洗规则，建事实表和维度表，初始加载和每周增量更新，批次检查与数据质量检查，运行记录 |
| **Tableau Desktop** | 业务看板 |

## 数据流程

```
上游数据 (xlsx)
   │  R：合并、导出 CSV（不清洗）；EDA 定下的标准商品名导出为 product_dict.csv
   ▼
raw      原始数据原样保存，每个文件是一个批次，记录加载状态
   │  批次检查：日期是否够新、新商品是否有多个描述、已有商品描述是否改变
   │  有问题的批次不加载，标记出来，由上游或业务方确认后再加载
   ▼
stg      清洗规则（视图）：去重、统一格式、剔除坏账和非商品交易、补全商品名称
   ▼
mart     fact_sales（事实表）、dim_product（商品主档 + 品类）、dim_date（日期维度）
   │  数据质量检查：有 FAIL 就撤销本次处理
   ▼
Tableau  看板

ops      运行记录、问题明细、新增商品、清洗漏斗、数据质量检查历史、人工修改记录
```

设计原则：

- **原始数据永远不改**：清洗规则改了，可以从 raw 重新处理。
- **规则只有一份**：初始加载和每周更新用同一套 SQL 规则。
- **分析师不替业务做选择**：商品描述不一致、日期重叠等问题会被标记，确认后才加载；每次人工确认都必须写说明，并记录时间。
- **每次运行都有记录**：成功或失败都写进 `ops.run_log`。

## 怎么运行

1. 下载数据，运行 `Retail_Analysis.Rmd`（Step 1 到 Step 3），导出两个 CSV 到 `/Users/Shared/retail_data/`。
2. 在 PostgreSQL（15 及以上）建一个数据库 `retail`。
3. 在 pgAdmin 的 Query Tool 里运行 `sql/initial_load.sql`：建表、导入商品主档、读入历史数据。
4. 运行 `sql/weekly_update.sql`（最下面保持 `NULL`）：用清洗规则处理历史数据。
5. 以后每周：把新文件放进同一个文件夹，修改 `weekly_update.sql` 最下面的文件路径，再运行。

## 目前进度

- [x] Part 1：数据探索与清洗规则（`Retail_Analysis.Rmd`）
- [x] SQL 数据管道：初始加载、每周增量更新、批次检查、数据质量检查、运行记录（`sql/`）
- [ ] Part 2：分析建模
- [ ] Part 3：Tableau 看板与最终交付

## 文件

| 文件 | 说明 |
|---|---|
| `Retail_Analysis.Rmd` | 数据读取、数据质量检查、清洗规则的发现，导出给 SQL 用的 CSV |
| `sql/initial_load.sql` | 初始加载（只运行一次）：建表、导入 EDA 定好的商品主档、读入历史数据、对账 |
| `sql/weekly_update.sql` | 清洗规则和每周更新流程：批次检查、商品主档与品类、写入事实表、日期维度、数据质量检查 |
