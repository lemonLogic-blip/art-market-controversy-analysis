-- =====================================
-- TRACK A: MARKET & PUBLIC REACTION
-- =====================================

-- 1. DATA PREPARATION (CLEAN VIEW)
USE art_project;
GO

CREATE OR ALTER VIEW dbo.vw_auction_enriched AS
WITH cleaned AS (
    SELECT
        *,
        TRY_CONVERT(float, REPLACE(realized_price, ',', '')) AS realized_price_num,
        TRY_CONVERT(float, REPLACE(estimate_low, ',', '')) AS estimate_low_num,
        TRY_CONVERT(float, REPLACE(estimate_high, ',', '')) AS estimate_high_num
    FROM dbo.fact_auction
),
fx AS (
    SELECT
        *,
        CASE 
            WHEN currency = 'USD' THEN 1.00
            WHEN currency = 'GBP' THEN 1.27
            WHEN currency = 'EUR' THEN 1.08
            ELSE NULL
        END AS fx_to_usd
    FROM cleaned
)
SELECT
    auction_id,
    artist_id,
    TRY_CONVERT(date, sale_date) AS sale_date,
    auction_house,
    sale_region,
    lot_title,
    medium,
    currency,
    sale_status,
    realized_price_num,
    estimate_low_num,
    estimate_high_num,
    realized_price_num * fx_to_usd AS realized_price_usd,
    ((estimate_low_num + estimate_high_num) / 2.0) * fx_to_usd AS estimate_mid_usd,
    CASE 
        WHEN sale_status = 'sold'
         AND realized_price_num IS NOT NULL
         AND estimate_low_num IS NOT NULL
         AND estimate_high_num IS NOT NULL
         AND (estimate_low_num + estimate_high_num) <> 0
        THEN realized_price_num / ((estimate_low_num + estimate_high_num) / 2.0)
        ELSE NULL
    END AS price_to_estimate_ratio,
    TRY_CONVERT(int, post_event_flag) AS post_event_flag
FROM fx;
GO

-- 2. DATA VALIDATION
SELECT *
FROM dbo.vw_auction_enriched;

-- 3. OVERALL MARKET PERFORMANCE BY ARTIST
SELECT
    a.artist_name,
    COUNT(*) AS total_lots,
    SUM(CASE WHEN LOWER(v.sale_status) = 'sold' THEN 1 ELSE 0 END) AS sold,
    SUM(CASE WHEN LOWER(v.sale_status) IN ('unsold') THEN 1 ELSE 0 END) AS unsold,
    ROUND(
        100.0 * SUM(CASE WHEN LOWER(v.sale_status) = 'sold' THEN 1 ELSE 0 END) 
        / NULLIF(COUNT(*), 0), 1
    ) AS sell_through_rate_pct,
    ROUND(AVG(v.realized_price_usd), 0) AS avg_realized_price_usd,
    ROUND(AVG(v.price_to_estimate_ratio), 3) AS avg_price_to_estimate_ratio
FROM dbo.vw_auction_enriched v
JOIN dbo.dim_artist a ON v.artist_id = a.artist_id
GROUP BY a.artist_name
ORDER BY a.artist_name;

-- 4. PRE VS POST EVENT MARKET COMPARISON
SELECT
    a.artist_name,
    v.post_event_flag,
    COUNT(*) AS total_lots,
    SUM(CASE WHEN LOWER(v.sale_status) = 'sold' THEN 1 ELSE 0 END) AS sold,
    ROUND(AVG(v.realized_price_usd), 0) AS avg_price_usd,
    ROUND(AVG(v.price_to_estimate_ratio), 3) AS avg_ratio
FROM dbo.vw_auction_enriched v
JOIN dbo.dim_artist a ON v.artist_id = a.artist_id
GROUP BY 
    a.artist_name,
    v.post_event_flag
ORDER BY 
    a.artist_name,
    v.post_event_flag;

-- 5. MARKET SUPPLY TREND (LOT VOLUME OVER TIME)
SELECT
    a.artist_name,
    YEAR(v.sale_date) AS sale_year,
    COUNT(*) AS total_lots,
    SUM(CASE WHEN LOWER(v.sale_status) = 'sold' THEN 1 ELSE 0 END) AS sold_count,
    SUM(CASE WHEN LOWER(v.sale_status) IN ('unsold') THEN 1 ELSE 0 END) AS unsold_count,
    ROUND(
        100.0 * SUM(CASE WHEN LOWER(v.sale_status) = 'sold' THEN 1 ELSE 0 END)
        / NULLIF(COUNT(*), 0), 1
    ) AS sell_through_rate_pct,
    ROUND(AVG(v.price_to_estimate_ratio), 3) AS avg_estimate_ratio
FROM dbo.vw_auction_enriched v
JOIN dbo.dim_artist a 
    ON v.artist_id = a.artist_id
WHERE v.sale_date IS NOT NULL
GROUP BY 
    a.artist_name,
    YEAR(v.sale_date)
ORDER BY 
    a.artist_name,
    sale_year;

-- 6. MARKET CHANNEL SHIFT (AUCTION TIER ANALYSIS)
SELECT
    a.artist_name,

    CASE 
        WHEN f.post_event_flag = 0 THEN 'Pre'
        WHEN f.post_event_flag = 1 THEN 'Post'
        ELSE 'No Event'
    END AS event_period,

    CASE 
        WHEN f.auction_house IN ('Christie''s')
            THEN 'top_tier'
        WHEN f.auction_house IN ('Invaluable')
            THEN 'low_tier'
    END AS market_tier,
    COUNT(*) AS lot_count

FROM dbo.vw_auction_enriched f
JOIN dbo.dim_artist a 
    ON f.artist_id = a.artist_id

WHERE a.artist_name = 'Graham Ovenden'
GROUP BY 
    a.artist_name,

    CASE 
        WHEN f.post_event_flag = 0 THEN 'Pre'
        WHEN f.post_event_flag = 1 THEN 'Post'
        ELSE 'No Event'
    END,

    CASE 
        WHEN f.auction_house IN ('Christie''s')
            THEN 'top_tier'
        WHEN f.auction_house IN ('Invaluable')
            THEN 'low_tier'
    END

ORDER BY 
    event_period,
    market_tier;

-- 7. PUBLIC ATTENTION VS MARKET ACTIVITY (MONTHLY)
WITH attention_monthly AS (
    SELECT
        artist_id,
        TRY_CONVERT(date, [date] + '-01') AS month_start,
        TRY_CONVERT(float, REPLACE(metric_value, '<1', '0.5')) AS attention_index,
        TRY_CONVERT(int, event_relative_month) AS event_relative_month
    FROM dbo.fact_public_attention
),
auction_monthly AS (
    SELECT
        artist_id,
        DATEFROMPARTS(YEAR(sale_date), MONTH(sale_date), 1) AS month_start,
        COUNT(auction_id) AS lot_count,
        SUM(CASE WHEN LOWER(sale_status) = 'sold' THEN 1 ELSE 0 END) AS sold_count
    FROM dbo.vw_auction_enriched
    WHERE sale_date IS NOT NULL
    GROUP BY
        artist_id,
        DATEFROMPARTS(YEAR(sale_date), MONTH(sale_date), 1)
)
SELECT
    da.artist_name,
    FORMAT(am.month_start, 'yyyy-MM') AS month,
    am.attention_index,
    am.event_relative_month,
    COALESCE(au.lot_count, 0) AS lot_count,
    COALESCE(au.sold_count, 0) AS sold_count
FROM attention_monthly am
JOIN dbo.dim_artist da
    ON am.artist_id = da.artist_id
LEFT JOIN auction_monthly au
    ON am.artist_id = au.artist_id
   AND am.month_start = au.month_start
ORDER BY
    da.artist_name,
    am.month_start;

-- 8. PUBLIC ATTENTION VS MARKET ACTIVITY (YEARLY)
WITH attention_monthly AS (
    SELECT
        artist_id,
        TRY_CONVERT(date, [date] + '-01') AS month_start,
        TRY_CONVERT(float, REPLACE(metric_value, '<1', '0.5')) AS attention_index,
        TRY_CONVERT(int, event_relative_month) AS event_relative_month
    FROM dbo.fact_public_attention
),
auction_monthly AS (
    SELECT
        artist_id,
        DATEFROMPARTS(YEAR(sale_date), MONTH(sale_date), 1) AS month_start,
        COUNT(auction_id) AS lot_count,
        SUM(CASE WHEN LOWER(sale_status) = 'sold' THEN 1 ELSE 0 END) AS sold_count
    FROM dbo.vw_auction_enriched
    WHERE sale_date IS NOT NULL
    GROUP BY
        artist_id,
        DATEFROMPARTS(YEAR(sale_date), MONTH(sale_date), 1)
),
combined_monthly AS (
    SELECT
        da.artist_name,
        am.artist_id,
        am.month_start,
        am.attention_index,
        am.event_relative_month,
        COALESCE(au.lot_count, 0) AS lot_count,
        COALESCE(au.sold_count, 0) AS sold_count
    FROM attention_monthly am
    JOIN dbo.dim_artist da 
        ON am.artist_id = da.artist_id
    LEFT JOIN auction_monthly au
        ON am.artist_id = au.artist_id
       AND am.month_start = au.month_start
)
SELECT
    artist_name,
    YEAR(month_start) AS year,
    ROUND(AVG(attention_index), 1) AS avg_attention_index,
    SUM(lot_count) AS total_lots,
    SUM(sold_count) AS total_sold,
    ROUND(
        100.0 * SUM(sold_count) / NULLIF(SUM(lot_count), 0), 
        1
    ) AS sell_through_rate_pct
FROM combined_monthly
GROUP BY 
    artist_name, 
    YEAR(month_start)
ORDER BY 
    artist_name, 
    year;

-- =====================================
-- TRACK B: INSTITUTIONAL POSITIONING
-- =====================================

-- 9. MUSEUM PRESENCE & DISPLAY STATUS
SELECT
    a.artist_name,
    a.group_type,
    COUNT(*) AS museum_record_count,
    SUM(CASE WHEN LOWER(m.display_status) = 'on view' THEN 1 ELSE 0 END) AS on_display_count,
    SUM(CASE WHEN LOWER(m.display_status) IN ('not on view', 'restricted view') THEN 1 ELSE 0 END) AS not_on_display_count,
    MIN(TRY_CONVERT(int, m.accession_year)) AS earliest_accession_year,
    MAX(TRY_CONVERT(int, m.accession_year)) AS latest_accession_year
FROM dbo.fact_museum_presence m
JOIN dbo.dim_artist a 
    ON m.artist_id = a.artist_id
GROUP BY
    a.artist_name,
    a.group_type
ORDER BY
    a.artist_name;

-- =====================================
-- VIEW 2: PUBLIC ATTENTION + MARKET ACTIVITY (MONTHLY)
-- Purpose: monthly-level data source for Power BI trend, dual-axis, and yearly aggregation
-- =====================================
USE art_project;
GO

CREATE OR ALTER VIEW dbo.vw_attention_market_monthly AS
WITH attention_monthly AS (
    SELECT
        artist_id,
        TRY_CONVERT(date, CONCAT(CAST([date] AS varchar(7)), '-01')) AS month_start,
        TRY_CONVERT(float, REPLACE(CAST(metric_value AS varchar(20)), '<1', '0.5')) AS attention_index,
        TRY_CONVERT(int, event_relative_month) AS event_relative_month
    FROM dbo.fact_public_attention
),
auction_monthly AS (
    SELECT
        artist_id,
        DATEFROMPARTS(YEAR(sale_date), MONTH(sale_date), 1) AS month_start,
        COUNT(auction_id) AS lot_count,
        SUM(CASE WHEN LOWER(sale_status) = 'sold' THEN 1 ELSE 0 END) AS sold_count
    FROM dbo.vw_auction_enriched
    WHERE sale_date IS NOT NULL
    GROUP BY
        artist_id,
        DATEFROMPARTS(YEAR(sale_date), MONTH(sale_date), 1)
)
SELECT
    am.artist_id,
    da.artist_name,
    am.month_start,
    FORMAT(am.month_start, 'yyyy-MM') AS month_label,
    YEAR(am.month_start) AS year,
    am.attention_index,
    am.event_relative_month,
    COALESCE(au.lot_count, 0) AS lot_count,
    COALESCE(au.sold_count, 0) AS sold_count
FROM attention_monthly am
JOIN dbo.dim_artist da
    ON am.artist_id = da.artist_id
LEFT JOIN auction_monthly au
    ON am.artist_id = au.artist_id
   AND am.month_start = au.month_start;
GO
-- =====================================
-- VIEW 3: Museum presence clean
-- Purpose: 
-- =====================================
USE art_project;
GO

CREATE OR ALTER VIEW dbo.vw_institutional_signal AS
SELECT
    a.artist_id,
    a.artist_name,
    a.group_type,
    m.museum_name,
    LOWER(LTRIM(RTRIM(m.display_status))) AS display_status,
    CASE 
        WHEN LOWER(LTRIM(RTRIM(m.display_status))) = 'on view' THEN 'on_display'
        WHEN LOWER(LTRIM(RTRIM(m.display_status))) = 'not on view' THEN 'not_on_display'
        WHEN LOWER(LTRIM(RTRIM(m.display_status))) = 'restricted view' THEN 'restricted'
        ELSE 'unknown'
    END AS display_status_group,
    m.medium,
    m.object_date,
    TRY_CONVERT(int, m.accession_year) AS accession_year
FROM dbo.fact_museum_presence m
JOIN dbo.dim_artist a 
    ON m.artist_id = a.artist_id;
GO
