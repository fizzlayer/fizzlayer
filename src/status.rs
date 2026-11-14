//! `GET /api/status`. Shared by the Vercel function and the self-host server.

use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};
use vercel_runtime::{Request, Response, ResponseBody};

use crate::{
    customer::{error, reply},
    store::{ConnectionError, Supabase},
};

/// Same window as `silence_scheduler_active` in the alerts list: a scan in the
/// last five minutes means silence alerts can still fire.
const SCHEDULER_FRESH_SECS: i64 = 300;

pub async fn handle(request: Request) -> Response<ResponseBody> {
    if request.method() != "GET" {
        return error(405, "method_not_allowed", "Use GET.");
    }
    let (database, scheduler) = match Supabase::from_env() {
        Ok(supabase) => match supabase.check_connection().await {
            Ok(()) => ("connected", scheduler_status(&supabase).await),
            Err(_) => ("unavailable", unknown_scheduler()),
        },
        Err(ConnectionError::MissingConfiguration) => ("unconfigured", unconfigured_scheduler()),
        Err(_) => ("unavailable", unknown_scheduler()),
    };
    reply(200, document(database, scheduler), None)
}

fn document(database: &str, scheduler: Value) -> Value {
    json!({
        "service": "fizz",
        "status": if database == "connected" { "ok" } else { "degraded" },
        "database": database,
        "scheduler": scheduler,
        "description": "The secure connection layer for AI agents"
    })
}

fn unconfigured_scheduler() -> Value {
    json!({"status": "unconfigured", "last_success_at": Value::Null, "recent": []})
}

fn unknown_scheduler() -> Value {
    json!({"status": "unknown", "last_success_at": Value::Null, "recent": []})
}

async fn scheduler_status(supabase: &Supabase) -> Value {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| i64::try_from(duration.as_secs()).unwrap_or(i64::MAX))
        .unwrap_or(0);
    // Prefer recent_scans from 20261114000200_scheduler_history.sql. A database
    // that has not applied it still has last_scan_at from the silence scan.
    let rows = match supabase
        .rest_get("fizz_scheduler_status?select=last_scan_at,recent_scans&id=eq.true")
        .await
    {
        Ok(value) => value,
        Err(_) => match supabase
            .rest_get("fizz_scheduler_status?select=last_scan_at&id=eq.true")
            .await
        {
            Ok(value) => value,
            Err(_) => return unknown_scheduler(),
        },
    };
    scheduler_from_rows(&rows, now)
}

pub(crate) fn scheduler_from_rows(rows: &Value, now_unix: i64) -> Value {
    let Some(rows) = rows.as_array() else {
        return unknown_scheduler();
    };
    let Some(row) = rows.first() else {
        return json!({"status": "stale", "last_success_at": Value::Null, "recent": []});
    };
    let last = row.get("last_scan_at").and_then(Value::as_str);
    let status = match last.and_then(parse_rfc3339_unix) {
        Some(then) if now_unix.saturating_sub(then) <= SCHEDULER_FRESH_SECS => "healthy",
        None if last.is_some() => "unknown",
        Some(_) | None => "stale",
    };
    let recent = row
        .get("recent_scans")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .take(8)
                .map(str::to_owned)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    json!({
        "status": status,
        "last_success_at": last,
        "recent": recent,
    })
}

/// `YYYY-MM-DDTHH:MM:SS[.fraction]Z` or with a numeric offset, which is what
/// PostgREST returns for `timestamptz`.
fn parse_rfc3339_unix(input: &str) -> Option<i64> {
    let (date, rest) = input.split_once('T')?;
    let mut date_parts = date.split('-');
    let year: i32 = date_parts.next()?.parse().ok()?;
    let month: u32 = date_parts.next()?.parse().ok()?;
    let day: u32 = date_parts.next()?.parse().ok()?;
    if date_parts.next().is_some() {
        return None;
    }
    let (time, offset) = split_offset(rest)?;
    let time = time.split('.').next()?;
    let mut time_parts = time.split(':');
    let hour: u32 = time_parts.next()?.parse().ok()?;
    let minute: u32 = time_parts.next()?.parse().ok()?;
    let second: u32 = time_parts.next()?.parse().ok()?;
    if time_parts.next().is_some() || hour > 23 || minute > 59 || second > 60 {
        return None;
    }
    let days = civil_days(year, month, day)?;
    Some(
        days * 86_400 + i64::from(hour) * 3_600 + i64::from(minute) * 60 + i64::from(second)
            - offset,
    )
}

fn split_offset(time_and_zone: &str) -> Option<(&str, i64)> {
    if let Some(time) = time_and_zone.strip_suffix('Z') {
        return Some((time, 0));
    }
    let sign_at = time_and_zone.rfind(['+', '-'])?;
    if sign_at == 0 {
        return None;
    }
    let (time, zone) = time_and_zone.split_at(sign_at);
    let sign: i64 = if zone.starts_with('+') { 1 } else { -1 };
    let (hours, minutes) = zone[1..].split_once(':')?;
    let hours: i64 = hours.parse().ok()?;
    let minutes: i64 = minutes.parse().ok()?;
    if !(0..=23).contains(&hours) || !(0..=59).contains(&minutes) {
        return None;
    }
    Some((time, sign * (hours * 3_600 + minutes * 60)))
}

/// Days from the Unix epoch to a real civil date.
fn civil_days(year: i32, month: u32, day: u32) -> Option<i64> {
    let max_day = match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if is_leap(year) => 29,
        2 => 28,
        _ => return None,
    };
    if day == 0 || day > max_day {
        return None;
    }
    // Howard Hinnant's `days_from_civil`.
    let year_of_era = if month <= 2 { year - 1 } else { year };
    let era = if year_of_era >= 0 {
        year_of_era
    } else {
        year_of_era - 399
    } / 400;
    let year_in_era = (year_of_era - era * 400) as u64;
    let month_prime = if month > 2 { month - 3 } else { month + 9 };
    let day_of_year = (153 * u64::from(month_prime) + 2) / 5 + u64::from(day) - 1;
    let day_of_era = year_in_era * 365 + year_in_era / 4 - year_in_era / 100 + day_of_year;
    Some(i64::from(era) * 146_097 + i64::try_from(day_of_era).ok()? - 719_468)
}

fn is_leap(year: i32) -> bool {
    year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unix_epoch_and_offsets_parse() {
        assert_eq!(parse_rfc3339_unix("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(
            parse_rfc3339_unix("2026-11-14T08:00:00+00:00"),
            parse_rfc3339_unix("2026-11-14T00:00:00-08:00")
        );
        assert_eq!(
            parse_rfc3339_unix("2026-11-14T08:00:00.123456Z"),
            parse_rfc3339_unix("2026-11-14T08:00:00Z")
        );
        assert_eq!(parse_rfc3339_unix("2023-02-29T00:00:00Z"), None);
        assert!(parse_rfc3339_unix("2024-02-29T00:00:00Z").is_some());
        assert_eq!(parse_rfc3339_unix("not-a-time"), None);
    }

    #[test]
    fn scheduler_is_healthy_for_five_minutes_and_keeps_recent_runs() {
        let now = parse_rfc3339_unix("2026-11-14T08:00:00Z").unwrap();
        let fresh = scheduler_from_rows(
            &json!([{
                "last_scan_at": "2026-11-14T07:56:00Z",
                "recent_scans": ["2026-11-14T07:56:00Z", "2026-11-14T07:55:00Z"]
            }]),
            now,
        );
        assert_eq!(fresh["status"], "healthy");
        assert_eq!(fresh["last_success_at"], "2026-11-14T07:56:00Z");
        assert_eq!(fresh["recent"].as_array().unwrap().len(), 2);

        let stale = scheduler_from_rows(&json!([{"last_scan_at": "2026-11-14T07:50:00Z"}]), now);
        assert_eq!(stale["status"], "stale");
        assert_eq!(stale["recent"].as_array().unwrap().len(), 0);
        assert_eq!(scheduler_from_rows(&json!([]), now)["status"], "stale");
        assert_eq!(
            scheduler_from_rows(&json!({"error": "no"}), now)["status"],
            "unknown"
        );
        assert_eq!(
            scheduler_from_rows(&json!([{"last_scan_at": "yesterday"}]), now)["status"],
            "unknown"
        );
    }

    #[test]
    fn database_and_scheduler_are_reported_separately() {
        let body = document(
            "connected",
            json!({"status": "healthy", "last_success_at": "t", "recent": []}),
        );
        assert_eq!(body["status"], "ok");
        assert_eq!(body["database"], "connected");
        assert_eq!(body["scheduler"]["status"], "healthy");
        let down = document("unconfigured", unconfigured_scheduler());
        assert_eq!(down["status"], "degraded");
        assert_eq!(down["scheduler"]["status"], "unconfigured");
    }
}
