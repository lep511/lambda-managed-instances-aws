use base64::{engine::general_purpose::STANDARD, Engine};
use lambda_runtime::{run_concurrent, service_fn, Error, LambdaEvent};
use polars::prelude::*;
use rand::Rng;
use serde::{Deserialize, Serialize};
use std::time::Instant;
use tracing::info;

#[derive(Deserialize)]
struct Request {
    csv_base64: Option<String>,
    generate_rows: Option<usize>,
}

#[derive(Serialize)]
struct Response {
    status_code: u16,
    request_id: String,
    processing: ProcessingInfo,
    stats: serde_json::Value,
    analysis: serde_json::Value,
    advanced: serde_json::Value,
    total_duration_seconds: f64,
}

#[derive(Serialize)]
struct ProcessingInfo {
    source: String,
    rows: usize,
    columns: usize,
    memory_mb: f64,
    load_duration_seconds: f64,
}

fn parse_csv(csv_bytes: &[u8]) -> Result<DataFrame, Error> {
    let cursor = std::io::Cursor::new(csv_bytes);

    let parse_options = CsvParseOptions::default()
        .with_null_values(Some(NullValues::AllColumnsSingle("NA".into())));

    let df = CsvReadOptions::default()
        .with_has_header(true)
        .with_infer_schema_length(Some(50000))
        .with_parse_options(parse_options)
        .into_reader_with_file_handle(cursor)
        .finish()?;

    Ok(df)
}

fn generate_flight_csv(n: usize) -> String {
    let mut rng = rand::thread_rng();
    let carriers = ["WN", "AA", "DL", "UA", "US", "B6", "AS", "NK", "F9", "HA"];
    let airports = [
        "ATL", "ORD", "DFW", "DEN", "LAX", "SFO", "SEA", "LAS", "PHX", "IAH",
        "MSP", "DTW", "BOS", "SLC", "BWI", "MDW", "SAN", "TPA", "PDX", "STL",
    ];

    let mut csv = String::with_capacity(n * 80);
    csv.push_str(
        "Year,Month,DayofMonth,DayOfWeek,DepTime,ArrTime,\
         UniqueCarrier,FlightNum,Origin,Dest,Distance,AirTime,\
         ArrDelay,DepDelay,Cancelled\n",
    );

    for _ in 0..n {
        let cancelled = rng.gen_bool(0.02);
        let distance: i32 = rng.gen_range(100..=3000);
        let origin_idx = rng.gen_range(0..airports.len());
        let mut dest_idx = rng.gen_range(0..airports.len());
        while dest_idx == origin_idx {
            dest_idx = rng.gen_range(0..airports.len());
        }

        let (dep_time, arr_time, air_time, arr_delay, dep_delay) = if cancelled {
            (
                "NA".to_string(),
                "NA".to_string(),
                "NA".to_string(),
                "NA".to_string(),
                "NA".to_string(),
            )
        } else {
            (
                rng.gen_range(600..=2359).to_string(),
                rng.gen_range(600..=2359).to_string(),
                format!("{}", (distance as f64 / rng.gen_range(5.0..=9.0_f64)) as i32),
                rng.gen_range(-30..=180).to_string(),
                rng.gen_range(-20..=120).to_string(),
            )
        };

        use std::fmt::Write;
        let _ = writeln!(
            csv,
            "2008,{},{},{},{},{},{},{},{},{},{},{},{},{},{}",
            rng.gen_range(1..=12),
            rng.gen_range(1..=28),
            rng.gen_range(1..=7),
            dep_time,
            arr_time,
            carriers[rng.gen_range(0..carriers.len())],
            rng.gen_range(100..=9999),
            airports[origin_idx],
            airports[dest_idx],
            distance,
            air_time,
            arr_delay,
            dep_delay,
            if cancelled { 1 } else { 0 },
        );
    }

    csv
}

fn compute_basic_stats(df: &DataFrame) -> Result<serde_json::Value, Error> {
    let total_rows = df.height();
    let memory_mb = df.estimated_size() as f64 / (1024.0 * 1024.0);

    let cancelled = df
        .column("Cancelled")?
        .i64()?
        .iter()
        .filter(|v| v.unwrap_or(0) == 1)
        .count();

    let arr_delay = df.column("ArrDelay")?.i64()?;
    let (delay_sum, delay_count) = arr_delay
        .iter()
        .filter_map(|v| v)
        .fold((0i64, 0usize), |(s, c), v| (s + v, c + 1));
    let avg_delay = if delay_count > 0 {
        delay_sum as f64 / delay_count as f64
    } else {
        0.0
    };

    Ok(serde_json::json!({
        "total_flights": total_rows,
        "columns": df.width(),
        "memory_mb": (memory_mb * 100.0).round() / 100.0,
        "cancelled_flights": cancelled,
        "cancellation_rate_pct": (cancelled as f64 / total_rows as f64 * 10000.0).round() / 100.0,
        "avg_delay_minutes": (avg_delay * 100.0).round() / 100.0,
    }))
}

fn compute_flight_analysis(df: &DataFrame) -> Result<serde_json::Value, Error> {
    let carriers_df = df
        .clone()
        .lazy()
        .group_by([col("UniqueCarrier")])
        .agg([len().alias("count")])
        .sort(
            ["count"],
            SortMultipleOptions::default().with_order_descending(true),
        )
        .limit(5)
        .collect()?;

    let top_carriers: Vec<serde_json::Value> = carriers_df
        .column("UniqueCarrier")?
        .str()?
        .iter()
        .zip(carriers_df.column("count")?.u32()?.iter())
        .filter_map(|(c, n)| Some(serde_json::json!({"carrier": c?, "flights": n?})))
        .collect();

    let routes_df = df
        .clone()
        .lazy()
        .with_column(
            (col("Origin").cast(DataType::String)
                + lit("-")
                + col("Dest").cast(DataType::String))
            .alias("Route"),
        )
        .group_by([col("Route")])
        .agg([len().alias("count")])
        .sort(
            ["count"],
            SortMultipleOptions::default().with_order_descending(true),
        )
        .limit(5)
        .collect()?;

    let top_routes: Vec<serde_json::Value> = routes_df
        .column("Route")?
        .str()?
        .iter()
        .zip(routes_df.column("count")?.u32()?.iter())
        .filter_map(|(r, n)| Some(serde_json::json!({"route": r?, "flights": n?})))
        .collect();

    let delay_df = df
        .clone()
        .lazy()
        .filter(col("ArrDelay").is_not_null())
        .group_by([col("Month")])
        .agg([col("ArrDelay").mean().alias("avg_delay")])
        .sort(["Month"], Default::default())
        .collect()?;

    let delay_by_month: Vec<serde_json::Value> = delay_df
        .column("Month")?
        .i64()?
        .iter()
        .zip(delay_df.column("avg_delay")?.f64()?.iter())
        .filter_map(|(m, d)| {
            Some(serde_json::json!({
                "month": m?,
                "avg_delay": (d? * 100.0).round() / 100.0
            }))
        })
        .collect();

    let airports_df = df
        .clone()
        .lazy()
        .group_by([col("Origin")])
        .agg([len().alias("count")])
        .sort(
            ["count"],
            SortMultipleOptions::default().with_order_descending(true),
        )
        .limit(10)
        .collect()?;

    let top_airports: Vec<serde_json::Value> = airports_df
        .column("Origin")?
        .str()?
        .iter()
        .zip(airports_df.column("count")?.u32()?.iter())
        .filter_map(|(a, n)| Some(serde_json::json!({"airport": a?, "flights": n?})))
        .collect();

    Ok(serde_json::json!({
        "top_carriers": top_carriers,
        "top_routes": top_routes,
        "delay_by_month": delay_by_month,
        "top_airports": top_airports,
    }))
}

fn compute_advanced_operations(df: &DataFrame) -> Result<serde_json::Value, Error> {
    let filtered = df
        .clone()
        .lazy()
        .filter(
            col("ArrDelay")
                .gt(15)
                .and(col("Distance").gt(500))
                .and(col("Cancelled").eq(0)),
        )
        .collect()?;

    let agg_df = df
        .clone()
        .lazy()
        .filter(col("ArrDelay").is_not_null())
        .group_by([col("UniqueCarrier")])
        .agg([
            col("ArrDelay").mean().alias("avg_delay"),
            col("ArrDelay").max().alias("max_delay"),
            col("Distance").mean().alias("avg_distance"),
            len().alias("flight_count"),
        ])
        .sort(["avg_delay"], Default::default())
        .collect()?;

    let carrier_stats: Vec<serde_json::Value> = agg_df
        .column("UniqueCarrier")?
        .str()?
        .iter()
        .zip(agg_df.column("avg_delay")?.f64()?.iter())
        .zip(agg_df.column("flight_count")?.u32()?.iter())
        .filter_map(|((c, d), n)| {
            Some(serde_json::json!({
                "carrier": c?,
                "avg_delay": (d? * 100.0).round() / 100.0,
                "flights": n?,
            }))
        })
        .collect();

    let temporal_df = df
        .clone()
        .lazy()
        .filter(col("DepTime").is_not_null())
        .with_column((col("DepTime") / lit(100)).cast(DataType::Int64).alias("DepHour"))
        .group_by([col("DepHour")])
        .agg([
            len().alias("flights"),
            col("ArrDelay").mean().alias("avg_delay"),
        ])
        .sort(["DepHour"], Default::default())
        .collect()?;

    let by_hour: Vec<serde_json::Value> = temporal_df
        .column("DepHour")?
        .i64()?
        .iter()
        .zip(temporal_df.column("avg_delay")?.f64()?.iter())
        .zip(temporal_df.column("flights")?.u32()?.iter())
        .filter_map(|((h, d), n)| {
            Some(serde_json::json!({
                "hour": h?,
                "avg_delay": (d? * 100.0).round() / 100.0,
                "flights": n?,
            }))
        })
        .collect();

    let transformed = df
        .clone()
        .lazy()
        .with_columns([
            when(col("ArrDelay").lt(0))
                .then(lit("Early"))
                .when(col("ArrDelay").lt_eq(15))
                .then(lit("OnTime"))
                .when(col("ArrDelay").lt_eq(60))
                .then(lit("Delayed"))
                .otherwise(lit("VeryDelayed"))
                .alias("DelayCategory"),
            (col("Distance") * lit(1.60934)).alias("DistanceKm"),
            (col("Distance") / (col("AirTime") / lit(60.0))).alias("AvgSpeedMph"),
        ])
        .collect()?;

    let category_counts = transformed
        .lazy()
        .group_by([col("DelayCategory")])
        .agg([len().alias("count")])
        .sort(
            ["count"],
            SortMultipleOptions::default().with_order_descending(true),
        )
        .collect()?;

    let categories: Vec<serde_json::Value> = category_counts
        .column("DelayCategory")?
        .str()?
        .iter()
        .zip(category_counts.column("count")?.u32()?.iter())
        .filter_map(|(c, n)| Some(serde_json::json!({"category": c?, "count": n?})))
        .collect();

    Ok(serde_json::json!({
        "filtered_delayed_long_distance": filtered.height(),
        "carrier_performance": carrier_stats,
        "delay_by_departure_hour": by_hour,
        "delay_categories": categories,
        "derived_columns_added": 3,
    }))
}

async fn handler(event: LambdaEvent<Request>) -> Result<Response, Error> {
    let request_id = event.context.request_id.clone();
    let total_start = Instant::now();

    let load_start = Instant::now();
    let (df, source) = if let Some(ref csv_b64) = event.payload.csv_base64 {
        let csv_bytes = STANDARD.decode(csv_b64)?;
        let df = parse_csv(&csv_bytes)?;
        (df, "base64_payload".to_string())
    } else {
        let rows = event.payload.generate_rows.unwrap_or(10_000);
        let csv_str = generate_flight_csv(rows);
        let df = parse_csv(csv_str.as_bytes())?;
        (df, format!("generated_{}_rows", rows))
    };
    let load_duration = load_start.elapsed().as_secs_f64();

    let processing = ProcessingInfo {
        source,
        rows: df.height(),
        columns: df.width(),
        memory_mb: (df.estimated_size() as f64 / (1024.0 * 1024.0) * 100.0).round() / 100.0,
        load_duration_seconds: (load_duration * 1000.0).round() / 1000.0,
    };

    info!(
        rows = processing.rows,
        columns = processing.columns,
        source = %processing.source,
        "CSV loaded"
    );

    let stats = compute_basic_stats(&df)?;
    let analysis = compute_flight_analysis(&df)?;
    let advanced = compute_advanced_operations(&df)?;

    Ok(Response {
        status_code: 200,
        request_id,
        processing,
        stats,
        analysis,
        advanced,
        total_duration_seconds: (total_start.elapsed().as_secs_f64() * 1000.0).round() / 1000.0,
    })
}

#[tokio::main]
async fn main() -> Result<(), Error> {
    tracing_subscriber::fmt()
        .json()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    run_concurrent(service_fn(handler)).await
}
