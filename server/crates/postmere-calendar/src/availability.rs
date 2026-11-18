//! Weekly wall-clock availability expanded only inside an explicit, finite date
//! window. Ambiguous and nonexistent DST times are skipped, never guessed.
use crate::calendar_provider::Interval;
use chrono::{DateTime, Datelike, Duration, NaiveDate, TimeZone, Utc};
use chrono_tz::Tz;
use postmere_core::error::AppError;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WeeklyAvailability {
    pub start_date: NaiveDate,
    pub end_date: NaiveDate,
    pub weekdays: Vec<u32>, // ISO weekdays: Monday=1, Sunday=7.
    pub start_minute: u32,
    pub end_minute: u32,
}
pub fn expand(
    rule: &WeeklyAvailability,
    zone: Tz,
    minutes: i32,
    expires: DateTime<Utc>,
    now: DateTime<Utc>,
) -> Result<Vec<Interval>, AppError> {
    let bad = || {
        AppError::bad_request(
            "Choose distinct weekdays, daytime hours, and an availability window of up to 90 days and 1,000 times.",
        )
    };
    if !(15..=240).contains(&minutes)
        || rule.start_date > rule.end_date
        || rule.end_date - rule.start_date > Duration::days(90)
        || rule.start_date < now.with_timezone(&zone).date_naive()
        || rule.end_date > (now + Duration::days(90)).with_timezone(&zone).date_naive()
        || rule.weekdays.is_empty()
        || rule.weekdays.len() > 7
        || rule.weekdays.iter().any(|d| !(1..=7).contains(d))
        || rule.weekdays.iter().collect::<HashSet<_>>().len() != rule.weekdays.len()
        || rule.start_minute >= rule.end_minute
        || rule.end_minute > 1440
    {
        return Err(bad());
    }
    let mut slots = Vec::new();
    let mut date = rule.start_date;
    while date <= rule.end_date {
        if rule.weekdays.contains(&date.weekday().number_from_monday()) {
            let midnight = date.and_hms_opt(0, 0, 0).ok_or_else(bad)?;
            let mut minute = rule.start_minute;
            while minute + minutes as u32 <= rule.end_minute {
                let local_start = midnight + Duration::minutes(i64::from(minute));
                let local_end = local_start + Duration::minutes(i64::from(minutes));
                if let (Some(start), Some(end)) = (
                    zone.from_local_datetime(&local_start).single(),
                    zone.from_local_datetime(&local_end).single(),
                ) {
                    let start = start.with_timezone(&Utc);
                    let end = end.with_timezone(&Utc);
                    if end - start == Duration::minutes(i64::from(minutes))
                        && start > now + Duration::minutes(5)
                        && end <= expires
                        && end <= now + Duration::days(90)
                    {
                        slots.push(Interval { start, end });
                        if slots.len() > 1000 {
                            return Err(bad());
                        }
                    }
                }
                minute += minutes as u32;
            }
        }
        date = date.succ_opt().ok_or_else(bad)?;
    }
    if slots.is_empty() {
        return Err(AppError::bad_request(
            "The availability window contains no future meeting times before the link expires.",
        ));
    }
    Ok(slots)
}
#[cfg(test)]
mod tests {
    use super::*;
    fn rule(
        start: &str,
        end: &str,
        weekdays: Vec<u32>,
        start_minute: u32,
        end_minute: u32,
    ) -> WeeklyAvailability {
        WeeklyAvailability {
            start_date: start.parse().unwrap(),
            end_date: end.parse().unwrap(),
            weekdays,
            start_minute,
            end_minute,
        }
    }
    #[test]
    fn weekly_hours_keep_local_time_across_dst_and_skip_ambiguous_times() {
        let now = "2027-03-01T00:00:00Z".parse().unwrap();
        let expiry = "2027-04-01T00:00:00Z".parse().unwrap();
        let zone: Tz = "America/New_York".parse().unwrap();
        let slots = expand(
            &rule("2027-03-07", "2027-03-14", vec![7], 540, 600),
            zone,
            30,
            expiry,
            now,
        )
        .unwrap();
        assert_eq!(slots.len(), 4);
        assert_eq!(
            slots[2].start - slots[0].start,
            Duration::days(7) - Duration::hours(1)
        );
        let gap = expand(
            &rule("2027-03-14", "2027-03-14", vec![7], 90, 240),
            zone,
            30,
            expiry,
            now,
        )
        .unwrap();
        assert_eq!(gap.len(), 2); // only 03:00 and 03:30; 01:30 ends in the gap.
        let fall_now = "2027-11-01T00:00:00Z".parse().unwrap();
        let fall_expiry = "2027-12-01T00:00:00Z".parse().unwrap();
        let fold = expand(
            &rule("2027-11-07", "2027-11-07", vec![7], 60, 180),
            zone,
            30,
            fall_expiry,
            fall_now,
        )
        .unwrap();
        assert_eq!(fold.len(), 2); // ambiguous 01:xx is omitted.
    }
    #[test]
    fn bounds_and_expiry_are_enforced() {
        let now = "2027-03-01T00:00:00Z".parse().unwrap();
        let expires = "2027-03-02T09:45:00Z".parse().unwrap();
        let rule = rule("2027-03-02", "2027-03-03", vec![2, 3], 540, 600);
        let slots = expand(&rule, chrono_tz::UTC, 30, expires, now).unwrap();
        assert_eq!(slots.len(), 1);
        let mut invalid = rule.clone();
        invalid.weekdays = vec![2, 2];
        assert!(expand(&invalid, chrono_tz::UTC, 30, expires, now).is_err());
        invalid = rule;
        invalid.end_date = "2028-01-01".parse().unwrap();
        assert!(expand(&invalid, chrono_tz::UTC, 30, expires, now).is_err());
    }
}
