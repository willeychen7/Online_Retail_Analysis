-- =========================================================================
-- weekly_update.sql：清洗规则 + 每周/每月更新（在 pgAdmin 的 Query Tool 里打开，按 F5 运行整个文件）
--
-- 第一次：先运行 initial_load.sql，再运行这个文件（最下面保持 NULL），处理历史数据。
-- 以后每次：新文件放进 /Users/Shared/retail_data/（PostgreSQL 没有权限读桌面文件夹），
--           把最下面 CALL 里的 NULL 换成这个文件的完整路径（加单引号），按 F5。
-- 结果摘要显示在下方的 Messages 标签页。
--
-- 所有清洗规则都在这个文件里。改了规则（清洗规则、品类关键词、检查项），改这个文件再运行就生效；
-- 已有的数据不会被删除或覆盖（每次运行会先删掉再重建视图和流程，视图不存数据）。
--
-- 加载前会检查，有问题的批次不加载，标记为 flagged：
--   日期不够新 / 新编码有多个描述 / 已有商品描述不同 / 没有任何有效行 / 处理失败
-- 分析师不替上游或业务方做选择。处理方法见文件最后。
-- =========================================================================

-- 还没建表就停下
DO $$
BEGIN
  IF to_regclass('raw.load_log') IS NULL THEN
    RAISE EXCEPTION '还没建表：请先运行 initial_load.sql。';
  END IF;
END $$;


-- =========================================================================
-- 1. 人工处理用的两个命令（每条都必须写说明，时间自动记录）
-- =========================================================================
-- 人工设定商品名称：新商品补名称，或已有商品改名。必须写说明，时间自动记录
--   SELECT ops.set_product_name('77777A', 'BLUE TEAPOT', '商品负责人确认：LARGE 是写错');
CREATE OR REPLACE FUNCTION ops.set_product_name(p_code text, p_name text, p_note text)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_old text;
BEGIN
  IF coalesce(btrim(p_note), '') = '' THEN
    RAISE EXCEPTION '请写明说明：谁确认的、为什么这样定';
  END IF;
  SELECT standard_description INTO v_old FROM mart.dim_product WHERE stock_code = p_code;
  INSERT INTO mart.dim_product (stock_code, standard_description, source, updated_at, change_note)
  VALUES (p_code, p_name, 'manual', now(), p_note)
  ON CONFLICT (stock_code) DO UPDATE
    SET standard_description = EXCLUDED.standard_description,
        source = 'manual', updated_at = now(), change_note = EXCLUDED.change_note;
  INSERT INTO ops.product_name_changes (stock_code, old_name, new_name, note)
  VALUES (p_code, v_old, p_name, p_note);
  RETURN p_code || '：' || coalesce(v_old, '（新商品）') || ' → ' || p_name;
END $$;

-- 确认被标记的批次。必须写说明，时间自动记录
--   SELECT ops.confirm_batch('完整路径/sales_2011_02.csv', '上游确认 85048 只是写错；77777A 已补名称');
CREATE OR REPLACE FUNCTION ops.confirm_batch(p_file text, p_note text)
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  IF coalesce(btrim(p_note), '') = '' THEN
    RAISE EXCEPTION '请写明说明：查到了什么原因、怎么处理的';
  END IF;
  UPDATE raw.load_log
  SET status = 'confirmed', confirmed_at = now(), confirm_note = p_note
  WHERE file = p_file AND status = 'flagged';
  IF NOT FOUND THEN
    RAISE EXCEPTION '没有找到这个被标记的批次：%', p_file;
  END IF;
  RETURN '已确认：' || p_file || '。再运行一次 weekly_update.sql 就会加载。';
END $$;



-- =========================================================================
-- 2. 清洗规则（视图）
-- 规则的依据见 Retail_Analysis.Rmd。改了规则，重新执行这个文件就生效。
-- =========================================================================
-- (1) 批次内完全相同的行只留一行（Retail_Analysis.Rmd 2.1）
--     统一大小写和空白，剔除坏账（Retail_Analysis.Rmd 2.2）
DROP VIEW IF EXISTS stg.sales_final;        -- 依赖 sales_normalized，先删
DROP VIEW IF EXISTS stg.sales_normalized;
CREATE VIEW stg.sales_normalized AS
WITH batch AS (
  SELECT file, sheet, status
  FROM raw.load_log
  WHERE status IN ('new', 'ready', 'confirmed')
),
dedup AS (
  SELECT DISTINCT r.file, r.sheet, r.invoice, r.stock_code, r.description, r.quantity,
                  r.invoice_date, r.price, r.customer_id, r.country
  FROM raw.sales_lines r
  JOIN batch b USING (file, sheet)
)
SELECT d.file,
       d.sheet,
       b.status,
       d.invoice,
       upper(regexp_replace(d.stock_code, '^\s+|\s+$', '', 'g'))              AS stock_code,
       btrim(upper(regexp_replace(d.description, '\s+', ' ', 'g')))           AS description,
       d.quantity::integer                                                    AS quantity,
       d.invoice_date,
       d.price,
       nullif(btrim(d.customer_id), '')                                       AS customer_id,
       d.country
FROM dedup d
JOIN batch b USING (file, sheet)
WHERE coalesce(d.description, '') !~* 'bad debt';


-- (2) 用主档的标准名补全缺失或占位的描述（Retail_Analysis.Rmd 3.1）
--     业务规则：只保留商品的正常销售（Quantity > 0）和退货或取消（Quantity < 0）（Retail_Analysis.Rmd 3.3）
--     事实表需要的字段（Retail_Analysis.Rmd Step 4）
DROP VIEW IF EXISTS stg.sales_final;
CREATE VIEW stg.sales_final AS
WITH named AS (
  SELECT n.*,
         p.standard_description,
         CASE WHEN n.description IS NULL OR n.description IN ('', 'NA', 'CHECK', 'UNKNOWN')
              THEN p.standard_description
              ELSE n.description END AS description_filled
  FROM stg.sales_normalized n
  LEFT JOIN mart.dim_product p USING (stock_code)
)
SELECT DISTINCT
       file,
       sheet,
       status,                                      -- 写入事实表时只取 ready / confirmed；批次检查的诊断用 new
       invoice,
       stock_code,
       customer_id,
       country,
       invoice_date,
       invoice_date::date                           AS date_key,
       quantity,
       price,
       round(quantity * price, 2)                   AS line_amount,
       (invoice LIKE 'C%' OR quantity < 0)          AS is_return,
       (customer_id IS NULL)                        AS is_anonymous,
       standard_description
FROM named
WHERE quantity <> 0
  AND price > 0
  -- 非商品编码：GIFT / TEST / ADJUST 有多种写法，用前缀规则
  AND stock_code !~ '^(ADJUST|GIFT|TEST)'
  -- 邮费、手续费、平台费、慈善、折扣、手工调整等
  AND stock_code NOT IN ('AMAZONFEE', 'BANK CHARGES', 'C2', 'CRUK', 'D', 'DOT', 'M', 'POST', 'S')
  -- 平台调整、代金券、损耗 / 样品 / 丢失
  AND coalesce(description_filled, '') !~* 'amazon|ebay'
  AND coalesce(description_filled, '') !~* 'voucher'
  AND coalesce(description_filled, '') !~* 'damag|damg|thrown|sample|unsaleable|bad quality|lost|missing';




-- =========================================================================
-- 3. 数据质量检查（视图）
-- =========================================================================
DROP VIEW IF EXISTS ops.v_dq_checks;
CREATE VIEW ops.v_dq_checks AS
WITH c AS (
  -- Range：取值范围
  SELECT 'Range' AS category, 'Price > 0' AS check_name, 'FAIL' AS severity, count(*) FILTER (WHERE price <= 0) AS n FROM mart.fact_sales
  UNION ALL SELECT 'Range', 'Quantity <> 0', 'FAIL', count(*) FILTER (WHERE quantity = 0) FROM mart.fact_sales
  UNION ALL SELECT 'Range', 'InvoiceDate 不晚于现在', 'FAIL', count(*) FILTER (WHERE invoice_date > now()) FROM mart.fact_sales
  UNION ALL SELECT 'Range', '|Quantity| >= 5000 的极端行（需人工确认）', 'WARN',
                   count(*) FILTER (WHERE abs(quantity) >= 5000) FROM mart.fact_sales
  -- Validity：格式
  UNION ALL SELECT 'Validity', 'Invoice 格式 = 可选 C + 6 位数字', 'FAIL',
                   count(*) FILTER (WHERE invoice !~ '^C?[0-9]{6}$') FROM mart.fact_sales
  UNION ALL SELECT 'Validity', 'Customer ID 格式 = 5 位数字（非匿名）', 'FAIL',
                   count(*) FILTER (WHERE customer_id !~ '^[0-9]{5}$') FROM mart.fact_sales
  -- Standardization：格式统一
  UNION ALL SELECT 'Standardization', 'Country 无首尾空格', 'FAIL',
                   count(*) FILTER (WHERE country <> btrim(country)) FROM mart.fact_sales
  UNION ALL SELECT 'Standardization', 'Country 为 Unspecified / European Community 的行', 'WARN',
                   count(*) FILTER (WHERE country IN ('Unspecified', 'European Community')) FROM mart.fact_sales
  -- Business Rules：口径一致
  UNION ALL SELECT 'Business Rules', '取消发票（C 开头）的 Quantity 必须为负', 'FAIL',
                   count(*) FILTER (WHERE invoice LIKE 'C%' AND quantity > 0) FROM mart.fact_sales
  -- Consistency：一张发票只对应一个客户、一个国家
  UNION ALL SELECT 'Consistency', '一张发票只对应一个 Customer ID', 'FAIL', count(*)
            FROM (SELECT invoice FROM mart.fact_sales WHERE customer_id IS NOT NULL
                  GROUP BY invoice HAVING count(DISTINCT customer_id) > 1) x
  UNION ALL SELECT 'Consistency', '一张发票只对应一个 Country', 'FAIL', count(*)
            FROM (SELECT invoice FROM mart.fact_sales
                  GROUP BY invoice HAVING count(DISTINCT country) > 1) x
)
SELECT category, check_name, n AS n_violations,
       CASE WHEN n = 0 THEN 'PASS' ELSE severity END AS status
FROM c;




-- =========================================================================
-- 4. 处理流程
-- =========================================================================

-- 4.1 把一个 CSV 原样读进 raw（不做任何清洗）
--     CSV 的列顺序：Invoice, StockCode, Description, Quantity, InvoiceDate, Price, Customer ID, Country
--     PostgreSQL 在本机读取这个文件，所以要用完整路径
CREATE OR REPLACE PROCEDURE ops.load_file(p_file text)
LANGUAGE plpgsql AS $proc$
BEGIN
  IF EXISTS (SELECT 1 FROM raw.load_log WHERE file = p_file) THEN
    RAISE EXCEPTION '这个文件已经加载过：%。如果是上游重新发送的数据，请换一个文件名。', p_file;
  END IF;

  CREATE TEMP TABLE csv_in (
    invoice      text,
    stock_code   text,
    description  text,
    quantity     numeric,
    invoice_date timestamp,
    price        numeric,
    customer_id  text,
    country      text
  );
  EXECUTE format('COPY csv_in FROM %L WITH (FORMAT csv, HEADER true)', p_file);

  EXECUTE format($q$
    INSERT INTO raw.load_log (file, sheet, rows_raw)
    SELECT %L, 'csv', count(*) FROM csv_in$q$, p_file);

  EXECUTE format($q$
    INSERT INTO raw.sales_lines (file, sheet, invoice, stock_code, description, quantity,
                                 invoice_date, price, customer_id, country)
    SELECT %L, 'csv', invoice, stock_code, description, quantity,
           invoice_date, price, nullif(btrim(customer_id), ''), country
    FROM csv_in$q$, p_file);

  DROP TABLE csv_in;
END $proc$;




-- 4.2 处理所有等待中的批次（新读入的 + 人工确认过的）
--     任何一步出错，或数据质量检查有 FAIL，这一步做的所有改动全部撤销（原始数据仍在 raw）
CREATE OR REPLACE PROCEDURE ops.process_pending()
LANGUAGE plpgsql AS $proc$
DECLARE
  v_missing text;
  v_failed  text;
BEGIN
  -- -----------------------------------------------------------------------
  -- 第 1 步：批次检查。有问题的批次标记为 flagged，不加载
  --   日期不够新 / 新编码有多个描述 / 已有商品描述不同 / 没有任何有效行
  --   分析师不替上游或业务方做选择：查清原因、处理好之后，用 ops.confirm_batch() 确认
  --   初始加载的批次直接是 confirmed（历史商品名称已经由 EDA 定好），不经过这些检查
  -- -----------------------------------------------------------------------
  -- (1) 问题明细
  INSERT INTO ops.batch_issues (file, sheet, issue, stock_code, master_name, batch_descriptions)
  -- 日期不够新
  SELECT b.file, b.sheet, '日期不够新', NULL, NULL,
         '最早月份 ' || b.first_m || ' 不晚于已有数据的最新月份 ' || l.m
  FROM (SELECT file, sheet, to_char(min(invoice_date), 'YYYY-MM') AS first_m
        FROM stg.sales_normalized WHERE status = 'new' GROUP BY file, sheet) b
  CROSS JOIN (SELECT to_char(max(date_key), 'YYYY-MM') AS m FROM mart.fact_sales) l
  WHERE l.m IS NOT NULL AND b.first_m <= l.m
  UNION ALL
  -- 新编码有多个描述
  SELECT file, sheet, '新编码有多个描述', stock_code, NULL,
         string_agg(DISTINCT description, ' | ')
  FROM stg.sales_normalized
  WHERE status = 'new'
    AND description IS NOT NULL AND description NOT IN ('', 'NA', 'CHECK', 'UNKNOWN')
    AND stock_code NOT IN (SELECT stock_code FROM mart.dim_product)
  GROUP BY file, sheet, stock_code
  HAVING count(DISTINCT description) > 1
  UNION ALL
  -- 已有商品的描述和主档不同
  SELECT n.file, n.sheet, '已有商品描述不同', n.stock_code, p.standard_description,
         string_agg(DISTINCT n.description, ' | ')
  FROM stg.sales_normalized n
  JOIN mart.dim_product p USING (stock_code)
  WHERE n.status = 'new'
    AND n.description IS NOT NULL AND n.description NOT IN ('', 'NA', 'CHECK', 'UNKNOWN')
    AND n.description <> p.standard_description
  GROUP BY n.file, n.sheet, n.stock_code, p.standard_description
  UNION ALL
  -- 没有任何有效行（去掉坏账后一行都不剩）
  SELECT l.file, l.sheet, '没有任何有效行', NULL, NULL, '请检查文件'
  FROM raw.load_log l
  WHERE l.status = 'new'
    AND NOT EXISTS (SELECT 1 FROM stg.sales_normalized n WHERE n.file = l.file AND n.sheet = l.sheet);

  -- (2) 日期诊断：和已有数据重叠了多少行、多少张发票（帮助判断“日期不够新”的原因）
  WITH latest AS (
    SELECT to_char(max(date_key), 'YYYY-MM') AS m FROM mart.fact_sales
  ),
  batch_range AS (
    SELECT file, sheet,
           to_char(min(invoice_date), 'YYYY-MM') AS first_m,
           to_char(max(invoice_date), 'YYYY-MM') AS last_m
    FROM stg.sales_normalized
    WHERE status = 'new'
    GROUP BY file, sheet
  ),
  overlap AS (
    SELECT n.file, n.sheet,
           count(f.invoice)            AS rows_dup,
           count(*) - count(f.invoice) AS rows_new
    FROM stg.sales_final n                       -- 用清洗规则之后的行：只数真正会进事实表的行
    LEFT JOIN mart.fact_sales f
      ON  f.invoice = n.invoice
      AND f.stock_code = n.stock_code
      AND coalesce(f.customer_id, '') = coalesce(n.customer_id, '')
      AND f.invoice_date = n.invoice_date
      AND f.quantity = n.quantity
      AND f.price = n.price
    WHERE n.status = 'new'
    GROUP BY n.file, n.sheet
  ),
  inv AS (
    SELECT b.file, b.sheet, count(*) AS n
    FROM (SELECT DISTINCT file, sheet, invoice FROM stg.sales_normalized WHERE status = 'new') b
    WHERE EXISTS (SELECT 1 FROM mart.fact_sales f WHERE f.invoice = b.invoice)
    GROUP BY b.file, b.sheet
  )
  UPDATE raw.load_log l
  SET batch_first_month        = r.first_m,
      batch_last_month         = r.last_m,
      fact_latest_month        = latest.m,
      rows_already_in_fact     = coalesce(o.rows_dup, 0),
      rows_new                 = coalesce(o.rows_new, 0),
      invoices_already_in_fact = coalesce(i.n, 0)
  FROM batch_range r
  CROSS JOIN latest
  LEFT JOIN overlap o USING (file, sheet)
  LEFT JOIN inv     i USING (file, sheet)
  WHERE l.file = r.file AND l.sheet = r.sheet;

  -- (3) 批次状态：有问题的 flagged，没问题的 ready
  UPDATE raw.load_log l
  SET status = CASE WHEN x.issues IS NULL THEN 'ready' ELSE 'flagged' END,
      note   = x.issues
  FROM (
    SELECT l2.file, l2.sheet,
           (SELECT string_agg(DISTINCT issue, '；') FROM ops.batch_issues b
            WHERE b.file = l2.file AND b.sheet = l2.sheet AND b.logged_at = now()) AS issues
    FROM raw.load_log l2
    WHERE l2.status = 'new'
  ) x
  WHERE l.file = x.file AND l.sheet = x.sheet;

  -- -----------------------------------------------------------------------
  -- 第 2 步：商品主档与品类
  --   已有商品的名称来自 EDA 或人工确认，流程本身不会改名；只有新商品进来时主档才会变化
  -- -----------------------------------------------------------------------
  -- (1) 新商品（主档里没有的 StockCode），而且只有一个描述：直接用这个描述，写进主档并记录
  --    有多个描述的新编码不会自动选名称（批次检查已经标记出来），
  --    要由上游或商品负责人确定名称后，手工写进主档（source = 'manual'）
  WITH new_codes AS (
    SELECT stock_code,
           min(description)                                  AS description,
           string_agg(DISTINCT file, '; ')                    AS batches
    FROM stg.sales_normalized
    WHERE status IN ('ready', 'confirmed')
      AND description IS NOT NULL
      AND description NOT IN ('', 'NA', 'CHECK', 'UNKNOWN')
      AND stock_code NOT IN (SELECT stock_code FROM mart.dim_product)
    GROUP BY stock_code
    HAVING count(DISTINCT description) = 1
  ),
  ins AS (
    INSERT INTO mart.dim_product (stock_code, standard_description)
    SELECT stock_code, description FROM new_codes
    RETURNING stock_code
  )
  INSERT INTO ops.product_change_log (stock_code, standard_description, batches)
  SELECT stock_code, description, batches FROM new_codes;

  -- (2) 品类与节日主题：每次对全部商品重新推导，规则改了马上生效
  --    CASE 从上往下判断，第一个符合的生效，所以顺序很重要
  --    \y 是 PostgreSQL 正则里的单词边界（相当于 R 里的 \b）
  UPDATE mart.dim_product
  SET category = CASE
      WHEN standard_description ~* 'T-?LIGHT|TEA ?LIGHT|CANDLE|LANTERN|\yLAMP|\yLIGHTS\y|NIGHT ?LIGHT|LIGHT CHAIN|CHANDELIER|LIGHTING|CANDELABRA|FAIRY LIGHT|TORCH|\yLED\y|MATCHES' THEN 'Candles & lighting'
      WHEN standard_description ~* '\yBAGS?\y|SHOPPER|PURSE|WALLET|UMBRELLA|PARASOL|SCARF|GLOVES?\y|\yHAT\y|SUNGLASSES|KEY ?RING|BACKPACK|RUCKSACK|SLIPPERS?\y|SOCKS|LUGGAGE|PASSPORT|HAIR ?(CLIP|SLIDE|BAND|COMB|GRIP)|BANDANA|PONCHO|SOMBRERO|SILK FAN|BUTTERFLY CLIPS|KEY FOB|SANDALWOOD FAN|HAND WARMER|SUNHAT|\yHATS?\y' THEN 'Bags & accessories'
      WHEN standard_description ~* 'BUNTING|BALLOON|PARTY|GARLAND|PAPER CHAIN|PAPER (CUP|PLATE|NAPKIN)|NAPKIN|CONFETTI|STREAMER|CRACKER|BIRTHDAY|WEDDING|CAKE CASES|CAKE TOPPER|SPARKLER|POPCORN HOLDER' THEN 'Party & celebration'
      WHEN standard_description ~* '\yCARDS?\y(?! HOLDER)|NOTEBOOK|\yPENS?\y|PENCIL|ERASER|RUBBER|STICKER|WRAPS?\y|TWINE|CHALK|GIFT TAG|\yTAGS?\y|ENVELOPE|DIARY|CALENDAR|ADDRESS BOOK|\yBOOKS?\y|STAMP|RIBBON|TISSUE|POSTCARD|JOURNAL|PAPER|SEWING|KNITTING|\yFELT|CRAFT|GLUE|SCISSORS|PAINT|CRAYON|COLOURING|RULER|SHARPENER|PHOTO ALBUM|MEMO PAD|STATIONERY SET|PATCHES|SCISSOR' THEN 'Stationery & craft'
      WHEN standard_description ~* 'CHRISTMAS|XMAS|ADVENT|WREATH|STOCKING|SANTA|REINDEER|SNOWMAN|SNOWFLAKE|BAUBLE|TINSEL|HALLOWEEN|EASTER|NATIVITY|SLEIGH BELLS|\yTREE\y' THEN 'Party & celebration'
      WHEN standard_description ~* 'NECKLACE|BRACELET|EARRING|\yRINGS?\y|PENDANT|BROOCH|\yBEADS?\y|\yCHARMS?\y|JEWELLERY(?! (BOX|DRAWER|STAND|HOLDER|CABINET|ORGANI))|ANKLET|CHOKER|BANGLE|TIARA' THEN 'Jewellery'
      WHEN standard_description ~* 'SOAP|\yBATH\y(?! BUILDING)|SPONGE|INCENSE|PERFUME|SCENT|OIL BURNER|TOOTHBRUSH|LOTION|HAND CREAM|SHOWER|FRAGRANCE|POT ?POURRI|LIP GLOSS|NAIL|MAKE ?UP|COSMETIC' THEN 'Bath & fragrance'
      WHEN standard_description ~* 'CUSHION|FLANNEL|\yMAT\y|FILLER PAD|BLANKET|(?<!TEA )\yTOWELS?\y|DOORMAT|HOT WATER BOTTLE|QUILT|\yTHROW\y|\yRUG\y|CURTAIN|PILLOW' THEN 'Home textiles & comfort'
      WHEN standard_description ~* '\yMUGS?\y|\yCUPS?\y|SAUCER|PLATES?\y|BOWLS?\y|\yJUGS?\y|TEAPOT|TEA SET|TEA TOWEL|CAKE ?STAND|CUTLERY|SPOONS?\y|FORKS?\y|KNIVES|KNIFE|APRON|BAKING|COOKIE|BISCUIT|LUNCH BOX|SANDWICH|PICNIC|DRINK|GLASSES|TUMBLER|KITCHEN|PANTRY|SPICE|\yCAKES?\y|\yJARS?\y|TRAY|COASTER|PLACEMAT|CORKSCREW|\yEGG|\yTEA\y|COFFEE|TOASTER|COLANDER|CHOPPING|ROLLING PIN|GRATER|MEASURING|\ySALT|PEPPER|CASSEROLE|MOULD|JELLY|\yJAM\y|BEAKER|WATER BOTTLE|BOTTLE|CHOCOLATE|SWEETS|PRESERVE|BUTTER DISH|BEURRE|\yDISH\y|FRYING PAN|\yPAN\y|BREAKFAST|\yBUTTER\y|CAKE SLICE|SERVING|TABLECLOTH|FOOD COVER|SUGAR|TONGS|COOKING SET|HONEYPOT|FLASK|TOAST' THEN 'Kitchen & dining'
      WHEN standard_description ~* '\yTOYS?\y|GAMES?\y|PUZZLE|DOLLS?\y|SKIPPING ROPE|DOMINOES|\yBLOCKS?\y|PLAYING|SOLDIER|TEDDY|ROBOT|RATTLE|\yBALLS?\y|CHILDREN|\yKIDS\y|BUBBLES|\yKITE|YO-?YO|PLAYHOUSE|MARBLES|SKITTLES|GLIDERS|CLAY|SNAKES|LADDERS|BINGO|SPINNING TOP|MODELLING|PIGGY BANK|MONEY BOX|JIGSAW|HARMONICA|XYLOPHONE|MUSICAL|\yDRUM\y|LUDO|NAUGHTS|SPORTING FUN|TATTOO|SPADE|GLOBE|BABY GIFT SET' THEN 'Toys & games'
      WHEN standard_description ~* 'GARDEN|PLANTER|PLANT POT|FLOWER POT|WATERING|\ySEEDS?\y|LAWN|HERB|TROWEL|WINDMILL|BIRD ?(HOUSE|FEEDER|TABLE|BATH)|WHEELBARROW|OUTDOOR|HAMMOCK|GROW YOUR OWN|PLANT\y' THEN 'Garden & outdoor'
      WHEN standard_description ~* 'STORAGE|BOXES|\yBOX\y|BASKET|DRAWER|CABINET|\yRACK\y|\yHOOKS?\y|SHELF|SHELVES|TRUNK|\yCHEST\y|\yBINS?\y|CRATE|ORGANI[SZ]ER|\yCASES?\y|CADDY|WARDROBE|\yTINS?\y|CONTAINER|\yPEGS?\y|TRINKET|BIN\y' THEN 'Storage & organisers'
      WHEN standard_description ~* 'FRAME|MIRROR|CLOCK|\ySIGN\y|\yWALL\y|PLAQUE|ORNAMENT|DECORATION|\yVASE|FLOWERS?\y|HEART|BLACKBOARD|\yBOARD\y|POSTER|FIGURINE|SCULPTURE|STATUE|WICKER|ANGEL|\yDOOR\y|HOLDER|\ySTAND\y|DISPLAY|MOBILE|WIND ?CHIME|\yBIRD|MEMOBOARD|CHALKBOARD|DOORSTOP|PHOTO|SLATE|BUTTERFLY|FLYING DUCKS|\yCUBE\y|\yBELLS?\y|WINDOW|ICICLE|MAGNETS?\y|LETTERS|STOOL|\ySEAT\y|DRESSING TABLE|FLAGS?\y|ROSETTE|HANGING|\yDEC\y' THEN 'Home decor'
      ELSE 'Other'
    END,
    season_theme = CASE
      WHEN standard_description ~* 'CHRISTMAS|XMAS|ADVENT|SANTA|REINDEER|SNOWMAN|SNOWFLAKE|BAUBLE|TINSEL|STOCKING|HOLLY|NATIVITY|SLEIGH' THEN 'Christmas'
      WHEN standard_description ~* 'EASTER' THEN 'Easter'
      WHEN standard_description ~* 'HALLOWEEN' THEN 'Halloween'
      ELSE 'None'
    END;

  -- -----------------------------------------------------------------------
  -- 第 3 步：写入事实表
  -- -----------------------------------------------------------------------
  -- (1) 有商品没有任何名称（这个编码从来没有过有效描述）：停下
  SELECT string_agg(DISTINCT stock_code, ', ') INTO v_missing
  FROM stg.sales_final
  WHERE status IN ('ready', 'confirmed') AND standard_description IS NULL;

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION '以下 StockCode 在商品主档里没有名称：%。请和上游或商品负责人确认名称，用 SELECT ops.set_product_name(...) 写进主档、用 ops.confirm_batch() 确认批次后，再运行一次 weekly_update.sql。', v_missing;
  END IF;

  -- (2) 清洗漏斗：每一步还剩多少行、多少销售额和退货额
  INSERT INTO ops.cleaning_funnel (file, sheet, step, rows, sales_amt, return_amt)
  SELECT file, sheet, step, count(*),
         round(sum(quantity * price) FILTER (WHERE quantity > 0), 2),
         round(sum(quantity * price) FILTER (WHERE quantity < 0), 2)
  FROM (
    SELECT r.file, r.sheet, '0. 原始数据' AS step, r.quantity, r.price
    FROM raw.sales_lines r JOIN raw.load_log l USING (file, sheet)
    WHERE l.status IN ('ready', 'confirmed')
    UNION ALL
    SELECT d.file, d.sheet, '2.1 去除完全重复行', d.quantity, d.price
    FROM (SELECT DISTINCT r.* FROM raw.sales_lines r JOIN raw.load_log l USING (file, sheet)
          WHERE l.status IN ('ready', 'confirmed')) d
    UNION ALL
    SELECT file, sheet, '2.2 剔除坏账', quantity, price
    FROM stg.sales_normalized WHERE status IN ('ready', 'confirmed')
    UNION ALL
    SELECT file, sheet, '3.3 业务规则', quantity, price
    FROM stg.sales_final WHERE status IN ('ready', 'confirmed')
  ) s
  GROUP BY file, sheet, step;

  -- (3) 追加进事实表。和已有数据（或同一次运行的其他批次）重复的行自动跳过；ORDER BY 让先到的批次优先
  WITH ins AS (
    INSERT INTO mart.fact_sales (invoice, stock_code, customer_id, country, invoice_date, date_key,
                                 quantity, price, line_amount, is_return, is_anonymous, file, sheet)
    SELECT invoice, stock_code, customer_id, country, invoice_date, date_key,
           quantity, price, line_amount, is_return, is_anonymous, file, sheet
    FROM stg.sales_final
    WHERE status IN ('ready', 'confirmed')     -- 被标记 (flagged) 和还没检查 (new) 的批次不写入
    ORDER BY file, sheet
    ON CONFLICT ON CONSTRAINT uq_order_line DO NOTHING
    RETURNING file, sheet, quantity, price
  )
  INSERT INTO ops.cleaning_funnel (file, sheet, step, rows, sales_amt, return_amt)
  SELECT file, sheet, '4. 去重后入库', count(*),
         round(sum(quantity * price) FILTER (WHERE quantity > 0), 2),
         round(sum(quantity * price) FILTER (WHERE quantity < 0), 2)
  FROM ins
  GROUP BY file, sheet;

  -- (4) 更新批次状态
  UPDATE raw.load_log l
  SET status       = 'loaded',
      processed_at = now(),
      rows_loaded  = coalesce((SELECT f.rows FROM ops.cleaning_funnel f
                               WHERE f.file = l.file AND f.sheet = l.sheet
                                 AND f.step = '4. 去重后入库'
                               ORDER BY f.logged_at DESC LIMIT 1), 0)
  WHERE l.status IN ('ready', 'confirmed');

  -- -----------------------------------------------------------------------
  -- 第 4 步：日期维度（按事实表的日期范围重新生成）
  -- -----------------------------------------------------------------------
  TRUNCATE mart.dim_date;

  INSERT INTO mart.dim_date (date_key, year_month, year, quarter, month_num)
  SELECT d::date,
         to_char(d, 'YYYY-MM'),
         extract(year from d)::integer,
         'Q' || extract(quarter from d),
         extract(month from d)::integer
  FROM generate_series((SELECT min(date_key) FROM mart.fact_sales),
                       (SELECT max(date_key) FROM mart.fact_sales),
                       interval '1 day') AS d;

  -- -----------------------------------------------------------------------
  -- 第 5 步：数据质量检查，有 FAIL 就撤销
  -- -----------------------------------------------------------------------
  SELECT string_agg(check_name || '（' || n_violations || '）', '；') INTO v_failed
  FROM ops.v_dq_checks WHERE status = 'FAIL';
  IF v_failed IS NOT NULL THEN
    RAISE EXCEPTION '数据质量检查有 FAIL，本次处理已全部撤销：%', v_failed;
  END IF;

  INSERT INTO ops.dq_history (category, check_name, n_violations, status)
  SELECT * FROM ops.v_dq_checks;
END $proc$;




-- 4.3 处理并记录：成功或失败都写进 ops.run_log，结果摘要显示在 pgAdmin 的 Messages 里
--     失败时显示 WARNING（不是报错），这样原始数据、批次标记和运行记录都会保留下来
CREATE OR REPLACE PROCEDURE ops.process_and_log(p_run_type text, p_file text, p_start timestamptz, p_error text)
LANGUAGE plpgsql AS $proc$
DECLARE
  v_err     text := p_error;
  v_summary text;
  r         record;
BEGIN
  IF v_err IS NULL THEN
    BEGIN
      CALL ops.process_pending();
    EXCEPTION WHEN others THEN
      v_err := SQLERRM;          -- 处理过程中的所有改动已撤销
    END;

    -- 处理失败：这次等待处理的批次都标记为 flagged，写明原因，避免以后每次运行都被它卡住
    -- 查清原因、处理好之后（例如补上商品名称，或请上游重新发送正确的文件），再用 ops.confirm_batch() 确认
    IF v_err IS NOT NULL THEN
      INSERT INTO ops.batch_issues (file, sheet, issue, batch_descriptions)
      SELECT file, sheet, '处理失败', v_err
      FROM raw.load_log WHERE status IN ('new', 'confirmed');

      UPDATE raw.load_log
      SET status = 'flagged', note = '处理失败：' || v_err
      WHERE status IN ('new', 'confirmed');
    END IF;
  END IF;

  SELECT string_agg(regexp_replace(file, '^.*/', '') || '：' || status
                    || CASE WHEN status = 'loaded' THEN '（加载 ' || rows_loaded || ' 行）' ELSE '' END
                    || CASE WHEN status = 'flagged' THEN '（' || note || '）' ELSE '' END, '；')
  INTO v_summary
  FROM raw.load_log
  WHERE processed_at >= p_start OR ingested_at >= p_start;

  INSERT INTO ops.run_log (started_at, run_type, file, result, message)
  VALUES (p_start, p_run_type, p_file,
          CASE WHEN v_err IS NULL THEN '成功' ELSE '失败' END,
          coalesce(v_err, v_summary, '没有需要处理的批次'));
  -- 失败：处理过程中的改动已撤销；原始数据、批次标记和这条记录会保留
  IF v_err IS NOT NULL THEN
    RAISE WARNING '本次处理失败（已记录在 ops.run_log）：%', v_err;
    RETURN;
  END IF;

  RAISE NOTICE '==================== % 完成 ====================', p_run_type;
  FOR r IN
    SELECT regexp_replace(file, '^.*/', '') AS f, status, rows_loaded, note
    FROM raw.load_log
    WHERE processed_at >= p_start OR ingested_at >= p_start
    ORDER BY ingested_at
  LOOP
    RAISE NOTICE '批次 %：%', r.f, r.status
      || CASE WHEN r.status = 'loaded'  THEN '，加载 ' || r.rows_loaded || ' 行' ELSE '' END
      || CASE WHEN r.status = 'flagged' THEN '，问题：' || r.note || '（明细：SELECT * FROM ops.v_open_issues;）' ELSE '' END;
  END LOOP;
  RAISE NOTICE '新增商品：% 个（SELECT * FROM ops.v_last_run_new_products;）',
    (SELECT count(*) FROM ops.product_change_log WHERE logged_at >= p_start);
  RAISE NOTICE '数据质量检查：% 项 WARN（SELECT * FROM ops.v_dq_checks;）',
    (SELECT count(*) FROM ops.v_dq_checks WHERE status = 'WARN');
  IF EXISTS (SELECT 1 FROM raw.load_log WHERE processed_at >= p_start AND note LIKE '初始加载%') THEN
    RAISE NOTICE '历史数据已处理。和旧版本对账：SELECT * FROM ops.v_reconciliation;  品类覆盖：SELECT * FROM ops.v_category_coverage;';
  END IF;
  RAISE NOTICE '事实表：% 行，日期 % 到 %',
    (SELECT count(*) FROM mart.fact_sales),
    (SELECT min(date_key) FROM mart.fact_sales), (SELECT max(date_key) FROM mart.fact_sales);
END $proc$;




-- 4.4 每周更新：读入新文件（可以不带文件），处理所有等待中的批次（包括初始加载读入的历史数据）
CREATE OR REPLACE PROCEDURE ops.weekly_update(p_file text DEFAULT NULL)
LANGUAGE plpgsql AS $proc$
DECLARE
  v_start timestamptz := now();   -- 本次运行开始的时间
  v_err   text;
BEGIN
  IF p_file IS NOT NULL THEN
    BEGIN
      CALL ops.load_file(p_file);
    EXCEPTION WHEN others THEN
      v_err := SQLERRM;
    END;
  END IF;

  CALL ops.process_and_log('每周更新', p_file, v_start, v_err);
END $proc$;


-- =========================================================================
-- 5. 查看结果用的视图
-- =========================================================================

-- 所有批次（最新的在前）
DROP VIEW IF EXISTS ops.v_batches;
CREATE VIEW ops.v_batches AS
SELECT regexp_replace(file, '^.*/', '') AS file, status, rows_raw, rows_loaded, note,
       batch_first_month, batch_last_month, fact_latest_month,
       rows_already_in_fact, rows_new, invoices_already_in_fact,
       ingested_at, processed_at, confirmed_at, confirm_note, file AS full_path
FROM raw.load_log
ORDER BY ingested_at DESC;

-- 还没处理的问题（被标记批次的问题明细）
DROP VIEW IF EXISTS ops.v_open_issues;
CREATE VIEW ops.v_open_issues AS
SELECT regexp_replace(b.file, '^.*/', '') AS file, b.issue, b.stock_code, b.master_name,
       b.batch_descriptions, b.logged_at, b.file AS full_path
FROM ops.batch_issues b
JOIN raw.load_log l USING (file, sheet)
WHERE l.status = 'flagged'
ORDER BY b.file, b.issue, b.stock_code;

-- 最近一次成功运行的清洗漏斗、新增商品
DROP VIEW IF EXISTS ops.v_last_run_funnel;
CREATE VIEW ops.v_last_run_funnel AS
SELECT regexp_replace(file, '^.*/', '') AS file, step, rows, sales_amt, return_amt
FROM ops.cleaning_funnel
WHERE logged_at >= (SELECT max(started_at) FROM ops.run_log WHERE result = '成功')
ORDER BY file, step;

DROP VIEW IF EXISTS ops.v_last_run_new_products;
CREATE VIEW ops.v_last_run_new_products AS
SELECT c.stock_code, c.standard_description, p.category,
       regexp_replace(c.batches, '[^;]*/', '', 'g') AS batches
FROM ops.product_change_log c
JOIN mart.dim_product p USING (stock_code)
WHERE c.logged_at >= (SELECT max(started_at) FROM ops.run_log WHERE result = '成功')
ORDER BY c.stock_code;



-- =========================================================================
-- 6. 运行：有新文件时，把 NULL 换成完整路径，例如
--    CALL ops.weekly_update('/Users/Shared/retail_data/sales_2011_12.csv');
--    第一次（处理历史数据）或确认了被标记的批次之后，保持 NULL
-- =========================================================================
CALL ops.weekly_update(NULL);

-- 运行完自动显示：被标记批次里每一条有问题的行（结果在下方的 Data Output；没有问题时为空）
--   日期不够新 / 没有任何有效行 / 处理失败：列出整个批次；in_fact 显示这一行是否已经在事实表里
--   新编码有多个描述 / 已有商品描述不同：只列出这个商品的行
SELECT regexp_replace(r.file, '^.*/', '')   AS file,
       i.issue,
       r.invoice, r.stock_code, r.description, r.quantity, r.price,
       r.invoice_date, r.customer_id, r.country,
       CASE WHEN EXISTS (
              SELECT 1 FROM mart.fact_sales f
              WHERE f.invoice = r.invoice
                AND f.stock_code = upper(btrim(r.stock_code))
                AND coalesce(f.customer_id, '') = coalesce(r.customer_id, '')
                AND f.invoice_date = r.invoice_date
                AND f.quantity = r.quantity
                AND f.price = r.price)
            THEN '已在事实表' ELSE '不在事实表' END AS in_fact
FROM ops.batch_issues i
JOIN raw.load_log   l ON l.file = i.file AND l.sheet = i.sheet
JOIN raw.sales_lines r ON r.file = i.file AND r.sheet = i.sheet
WHERE l.status = 'flagged'
  AND (i.stock_code IS NULL                                  -- 日期不够新 / 没有任何有效行 / 处理失败：列出整个批次
       OR upper(btrim(r.stock_code)) = i.stock_code)         -- 商品描述问题：只列出这个商品的行
ORDER BY file, i.issue, r.invoice_date, r.invoice;


-- =========================================================================
-- 7. 批次被标记时（选中要运行的那一行，按 F5 只运行选中的部分）
--    先看问题，查清原因、和上游或商品负责人确认后再处理。每条命令都必须写说明，时间自动记录
-- =========================================================================
-- 问题行在运行后自动显示；按问题汇总看：SELECT * FROM ops.v_open_issues;（full_path 列是完整路径）
-- SELECT ops.set_product_name('编码', '名称', '谁确认的、为什么这样定');      -- 新编码补名称，或已有商品改名
-- SELECT ops.confirm_batch('完整路径', '查到的原因和处理方式');               -- 确认：这批数据可以加载
-- CALL ops.weekly_update(NULL);                                             -- 不带文件再运行，加载已确认的批次


-- =========================================================================
-- 8. 随时查看
-- =========================================================================
-- SELECT * FROM ops.run_log ORDER BY run_id DESC;                           -- 每次运行的记录（成功或失败）
-- SELECT * FROM ops.v_batches;                                              -- 所有批次的状态
-- SELECT * FROM ops.v_last_run_funnel;                                      -- 最近一次成功运行的清洗漏斗
-- SELECT * FROM ops.v_last_run_new_products;                                -- 最近一次成功运行新增的商品
-- SELECT * FROM ops.v_dq_checks;                                            -- 数据质量检查
-- SELECT * FROM ops.product_name_changes ORDER BY changed_at DESC;          -- 商品名称的人工修改记录
