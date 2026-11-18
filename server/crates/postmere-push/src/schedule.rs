use chrono::{DateTime, Datelike, Duration, Timelike, Utc};
use chrono_tz::Tz;
use postmere_core::error::AppError;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct AccountPreference {
    pub account_id: Uuid,
    pub enabled: bool,
    pub schedule_enabled: bool,
    pub start_minute: u16,
    pub end_minute: u16,
    pub weekdays: Vec<u8>,
    pub time_zone: String,
    pub show_subject: bool,
    pub filter_criteria: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sender_policy: Option<crate::SenderPolicy>,
}

impl AccountPreference {
    pub fn validate(&self) -> Result<(), AppError> {
        if self.start_minute >= 1440
            || self.end_minute >= 1440
            || self.weekdays.len() > 7
            || self.weekdays.iter().any(|day| !(1..=7).contains(day))
            || self.time_zone.parse::<Tz>().is_err()
            || self.filter_criteria.len() > 512
            || self.filter_criteria.is_empty()
            || self.filter_criteria.chars().any(char::is_control)
        {
            return Err(AppError::bad_request("Invalid notification preferences."));
        }
        if let Some(policy) = &self.sender_policy {
            policy.validate()?;
        }
        Ok(())
    }

    pub fn permits(&self, date: DateTime<Utc>) -> bool {
        if !self.enabled {
            return false;
        }
        if !self.schedule_enabled {
            return true;
        }
        let Ok(zone) = self.time_zone.parse::<Tz>() else {
            return false;
        };
        let local = date.with_timezone(&zone);
        let minute = (local.hour() * 60 + local.minute()) as u16;
        let weekday = local.weekday().number_from_sunday() as u8;
        if self.start_minute == self.end_minute {
            return self.weekdays.contains(&weekday);
        }
        if self.start_minute < self.end_minute {
            self.weekdays.contains(&weekday)
                && minute >= self.start_minute
                && minute < self.end_minute
        } else if minute >= self.start_minute {
            self.weekdays.contains(&weekday)
        } else {
            let previous = if weekday == 1 { 7 } else { weekday - 1 };
            minute < self.end_minute && self.weekdays.contains(&previous)
        }
    }

    /// Walk actual UTC minutes, so nonexistent/repeated wall times obey the
    /// same local schedule without guessing a DST offset.
    pub fn next_permitted(
        &self,
        now: DateTime<Utc>,
        expires: DateTime<Utc>,
    ) -> Option<DateTime<Utc>> {
        if now >= expires || !self.enabled {
            return None;
        }
        if self.permits(now) {
            return Some(now);
        }
        let mut candidate = now.with_second(0)?.with_nanosecond(0)? + Duration::minutes(1);
        let bound = expires.min(now + Duration::days(8));
        while candidate < bound {
            if self.permits(candidate) {
                return Some(candidate);
            }
            candidate += Duration::minutes(1);
        }
        None
    }

    /// Stop Apple's store-and-forward window at the next quiet period. APNs
    /// itself remains best effort, so the OS can still deliver an alert late.
    pub fn delivery_expiration(&self, now: DateTime<Utc>, expires: DateTime<Utc>) -> DateTime<Utc> {
        if !self.schedule_enabled {
            return expires;
        }
        if !self.permits(now) {
            return now;
        }
        let mut candidate = now
            .with_second(0)
            .and_then(|value| value.with_nanosecond(0))
            .unwrap_or(now)
            + Duration::minutes(1);
        while candidate < expires {
            if !self.permits(candidate) {
                return candidate;
            }
            candidate += Duration::minutes(1);
        }
        expires
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn profile() -> AccountPreference {
        AccountPreference {
            account_id: Uuid::nil(),
            enabled: true,
            schedule_enabled: true,
            start_minute: 22 * 60,
            end_minute: 2 * 60,
            weekdays: vec![6],
            time_zone: "America/New_York".into(),
            show_subject: false,
            filter_criteria: "fixture".into(),
            sender_policy: None,
        }
    }
    #[test]
    fn overnight_schedule_uses_start_day_and_dst_uses_actual_time() {
        let mut p = profile();
        let friday: DateTime<Utc> = "2026-11-07T03:30:00Z".parse().unwrap();
        assert!(p.permits(friday));
        assert!(p.permits(friday + Duration::hours(2)));
        assert!(!p.permits(friday + Duration::hours(4)));
        p.start_minute = 150;
        p.end_minute = 180;
        p.weekdays = vec![1];
        let gap: DateTime<Utc> = "2026-03-08T06:00:00Z".parse().unwrap();
        assert_eq!(p.next_permitted(gap, gap + Duration::hours(24)), None);
        p.start_minute = 60;
        p.end_minute = 120;
        assert!(p.permits("2026-11-01T05:30:00Z".parse().unwrap()));
        assert!(p.permits("2026-11-01T06:30:00Z".parse().unwrap()));
        let repeated: DateTime<Utc> = "2026-11-01T05:30:00Z".parse().unwrap();
        assert_eq!(
            p.delivery_expiration(repeated, repeated + Duration::days(1)),
            "2026-11-01T07:00:00Z".parse::<DateTime<Utc>>().unwrap()
        );
    }
}
