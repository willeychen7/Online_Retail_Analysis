-- =========================================================================
-- initial_load.sql：初始加载（只运行一次）。在 pgAdmin 的 Query Tool 里打开，按 F5 运行整个文件
--
-- 运行之前：运行 Retail_Analysis.Rmd，导出两个 CSV 到 /Users/Shared/retail_data/
--   online_retail_II_raw.csv   两个 sheet 合并后、还没清洗的原始数据
--   product_dict.csv           EDA 定好的标准商品名
--   （放在 /Users/Shared：PostgreSQL 没有权限读桌面文件夹里的文件）
--
-- 这个文件做所有只做一次的事：建表、导入 EDA 的商品主档、把历史数据原样读进 raw。
-- 运行完之后，再运行 weekly_update.sql（最下面保持 NULL），用同一套清洗规则处理历史数据。
-- 历史商品名称已经由 EDA 定好，所以历史数据直接是“已确认”，不做商品描述检查。
-- 已经做过初始加载，再运行会被挡住。需要 PostgreSQL 15 及以上（用到 NULLS NOT DISTINCT）。
-- =========================================================================


-- =========================================================================
-- 1. 建 schema 和表
-- =========================================================================
CREATE SCHEMA IF NOT EXISTS raw;    -- 上游数据原样保存，永远不改
CREATE SCHEMA IF NOT EXISTS stg;    -- 清洗规则（视图）
CREATE SCHEMA IF NOT EXISTS mart;   -- 给 Tableau 的事实表和维度表
CREATE SCHEMA IF NOT EXISTS ops;    -- 变化日志、清洗漏斗、数据质量检查

-- 每个批次（一个文件的一个 sheet）的状态：
--   new       刚读入，还没处理
--   ready     通过日期检查，等待处理
--   flagged   没通过日期检查，需要人工查看
--   confirmed 人工查清后确认可以加载
--   loaded    已进入事实表
CREATE TABLE IF NOT EXISTS raw.load_log (
  file                     text        NOT NULL,
  sheet                    text        NOT NULL,
  ingested_at              timestamptz NOT NULL DEFAULT now(),
  rows_raw                 integer,
  status                   text        NOT NULL DEFAULT 'new'
                           CHECK (status IN ('new', 'ready', 'flagged', 'confirmed', 'loaded')),
  note                     text,
  -- 日期检查的诊断
  batch_first_month        text,
  batch_last_month         text,
  fact_latest_month        text,
  rows_already_in_fact     integer,
  rows_new                 integer,
  invoices_already_in_fact integer,
  -- 处理结果
  rows_loaded              integer,
  processed_at             timestamptz,
  -- 人工确认（被标记的批次）
  confirmed_at             timestamptz,
  confirm_note             text,
  PRIMARY KEY (file, sheet)
);

-- 上游数据原样保存（包括重复行、坏账、费用），清洗规则改了可以从这里重新处理
CREATE TABLE IF NOT EXISTS raw.sales_lines (
  file         text NOT NULL,
  sheet        text NOT NULL,
  invoice      text,
  stock_code   text,
  description  text,
  quantity     numeric,
  invoice_date timestamp,
  price        numeric,
  customer_id  text,
  country      text,
  FOREIGN KEY (file, sheet) REFERENCES raw.load_log (file, sheet)
);
CREATE INDEX IF NOT EXISTS ix_sales_lines_batch ON raw.sales_lines (file, sheet);

-- 商品主档：一个编码一个标准名，名称不变。
-- source：eda = EDA 定的（初始加载导入）；auto = 之后的新商品；manual = 手工修改过
CREATE TABLE IF NOT EXISTS mart.dim_product (
  stock_code           text PRIMARY KEY,
  standard_description text NOT NULL,
  added_date           date NOT NULL DEFAULT current_date,
  source               text NOT NULL DEFAULT 'auto' CHECK (source IN ('eda', 'auto', 'manual')),
  updated_at           timestamptz,   -- 最近一次人工修改的时间
  change_note          text,          -- 最近一次人工修改的说明
  category             text,     -- 每次运行按规则重新推导（ops.process_pending 的第 2 步）
  season_theme         text
);

-- 事实表：一行 = 一张发票里的一个商品
CREATE TABLE IF NOT EXISTS mart.fact_sales (
  invoice      text          NOT NULL,
  stock_code   text          NOT NULL REFERENCES mart.dim_product (stock_code),
  customer_id  text,                     -- NULL = 匿名交易
  country      text          NOT NULL,
  invoice_date timestamp     NOT NULL,
  date_key     date          NOT NULL,
  quantity     integer       NOT NULL,
  price        numeric       NOT NULL,
  line_amount  numeric(14,2) NOT NULL,   -- 数量 × 单价，两位小数；销售为正，退货为负
  is_return    boolean       NOT NULL,
  is_anonymous boolean       NOT NULL,
  file         text          NOT NULL,   -- 来自哪个批次（追溯用）
  sheet        text          NOT NULL,
  -- 这 6 列都一样就是同一行订单：重复的行会被自动跳过
  CONSTRAINT uq_order_line UNIQUE NULLS NOT DISTINCT
    (invoice, stock_code, customer_id, invoice_date, quantity, price)
);
CREATE INDEX IF NOT EXISTS ix_fact_sales_date ON mart.fact_sales (date_key);

CREATE TABLE IF NOT EXISTS mart.dim_date (
  date_key   date PRIMARY KEY,
  year_month text,
  year       integer,
  quarter    text,
  month_num  integer
);

CREATE TABLE IF NOT EXISTS ops.product_change_log (
  logged_at            timestamptz NOT NULL DEFAULT now(),
  stock_code           text,
  standard_description text,
  batches              text
);

-- 商品名称的人工修改记录（每次修改一行，保留旧名称）
CREATE TABLE IF NOT EXISTS ops.product_name_changes (
  changed_at  timestamptz NOT NULL DEFAULT now(),
  stock_code  text,
  old_name    text,     -- 新商品为空
  new_name    text,
  note        text
);

-- 批次检查发现的问题明细（ops.process_pending 的第 1 步）
CREATE TABLE IF NOT EXISTS ops.batch_issues (
  logged_at          timestamptz NOT NULL DEFAULT now(),
  file               text,
  sheet              text,
  issue              text,     -- 日期不够新 / 新编码有多个描述 / 已有商品描述不同 / 没有任何有效行 / 处理失败
  stock_code         text,
  master_name        text,     -- 主档里的名称（已有商品）
  batch_descriptions text      -- 这个批次里出现的描述
);

CREATE TABLE IF NOT EXISTS ops.cleaning_funnel (
  logged_at  timestamptz NOT NULL DEFAULT now(),
  file       text,
  sheet      text,
  step       text,
  rows       integer,
  sales_amt  numeric,
  return_amt numeric
);

CREATE TABLE IF NOT EXISTS ops.dq_history (
  checked_at   timestamptz NOT NULL DEFAULT now(),
  category     text,
  check_name   text,
  n_violations bigint,
  status       text
);

-- 每次运行的记录（成功或失败都会记下）
CREATE TABLE IF NOT EXISTS ops.run_log (
  run_id      serial PRIMARY KEY,
  started_at  timestamptz NOT NULL,
  finished_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  run_type    text,      -- 初始加载 / 每周更新
  file        text,      -- 本次读入的文件；没有新文件时为空
  result      text,      -- 成功 / 失败
  message     text       -- 结果摘要，或失败原因
);


-- =========================================================================
-- 2. 只在初始加载后看的检查（处理完历史数据再查）
-- =========================================================================
-- 初始加载时看：品类覆盖（Other 占比高，说明品类规则需要补充）
CREATE OR REPLACE VIEW ops.v_category_coverage AS
WITH s AS (SELECT stock_code, sum(line_amount) AS net_sales FROM mart.fact_sales GROUP BY stock_code)
SELECT p.category, count(*) AS n_products, round(sum(s.net_sales)) AS net_sales,
       round(100 * sum(s.net_sales) / sum(sum(s.net_sales)) OVER (), 1) AS share_pct
FROM mart.dim_product p JOIN s USING (stock_code)
WHERE s.net_sales > 0
GROUP BY p.category
ORDER BY net_sales DESC;

-- 初始加载时看：和旧版本（R 清洗后导出的 CSV：1,021,271 行，净销售额 18,927,315.72）对账
CREATE OR REPLACE VIEW ops.v_reconciliation AS
SELECT count(*) AS rows, count(*) - 1021271 AS diff_rows,
       sum(line_amount) AS net_sales, sum(line_amount) - 18927315.72 AS diff_sales
FROM mart.fact_sales;


-- =========================================================================
-- 3. 读入 EDA 的商品主档和历史数据（只改下面两个路径，要写完整路径）
-- =========================================================================
DO $$
DECLARE
  v_history  text := '/Users/Shared/retail_data/online_retail_II_raw.csv';
  v_products text := '/Users/Shared/retail_data/product_dict.csv';
BEGIN
  -- 已经做过初始加载就停下，防止重复运行
  IF EXISTS (SELECT 1 FROM raw.load_log) THEN
    RAISE EXCEPTION '初始加载已经完成，不要重复运行。新数据请用 weekly_update.sql。';
  END IF;

  -- 商品主档：直接用 EDA 定好的标准名
  CREATE TEMP TABLE dict_in (stock_code text, standard_description text);
  EXECUTE format('COPY dict_in FROM %L WITH (FORMAT csv, HEADER true)', v_products);
  INSERT INTO mart.dim_product (stock_code, standard_description, source)
  SELECT stock_code, standard_description, 'eda' FROM dict_in;
  DROP TABLE dict_in;

  -- 历史数据原样读进 raw，直接是“已确认”
  CREATE TEMP TABLE csv_in (
    invoice text, stock_code text, description text, quantity numeric,
    invoice_date timestamp, price numeric, customer_id text, country text
  );
  EXECUTE format('COPY csv_in FROM %L WITH (FORMAT csv, HEADER true)', v_history);

  INSERT INTO raw.load_log (file, sheet, rows_raw, status, note)
  SELECT v_history, 'csv', count(*), 'confirmed', '初始加载：商品名称来自 EDA' FROM csv_in;

  INSERT INTO raw.sales_lines (file, sheet, invoice, stock_code, description, quantity,
                               invoice_date, price, customer_id, country)
  SELECT v_history, 'csv', invoice, stock_code, description, quantity,
         invoice_date, price, nullif(btrim(customer_id), ''), country
  FROM csv_in;
  DROP TABLE csv_in;

  RAISE NOTICE '初始加载完成：商品主档 % 个商品，历史数据 % 行已读入。下一步：运行 weekly_update.sql（最下面保持 NULL），处理历史数据。',
    (SELECT count(*) FROM mart.dim_product),
    (SELECT count(*) FROM raw.sales_lines);
END $$;
