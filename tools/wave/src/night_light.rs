//! Warm the screen through civil twilight: identity while the sun is up,
//! 4000 K once it is 6° below the horizon, and a linear ramp in between.

use crate::dbus::LoginManagerProxyBlocking;
use crate::location::{self, Coordinates};
use anyhow::{Context, Result, bail, ensure};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::mpsc::{self, RecvTimeoutError};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use zbus::blocking::Connection;

/// Used until GeoClue reports a location for the first time.
const WARSAW: Coordinates = Coordinates {
    latitude: 52.2,
    longitude: 21.0,
};
const NIGHT_TEMPERATURE: u32 = 4000;
const DAY_TEMPERATURE: u32 = 6500;
/// Sun elevations: the upper limb at the horizon, and the end of civil twilight.
const SUNRISE_ELEVATION: f64 = -0.833;
const CIVIL_TWILIGHT_ELEVATION: f64 = -6.0;
/// Temperatures are applied in steps of this size during the ramp.
const TEMPERATURE_STEP: u32 = 10;
const RAMP_UPDATE: Duration = Duration::from_secs(60);
/// How far ahead the next change is searched for; polar days end eventually.
const LOOKAHEAD: Duration = Duration::from_secs(48 * 3600);
const RETRY: Duration = Duration::from_secs(60);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(2);

#[derive(Clone, Copy, Debug, PartialEq)]
enum Setting {
    Identity,
    Temperature(u32),
}

enum Event {
    Location(location::Event),
    Resumed,
    Lost(&'static str),
}

impl From<location::Event> for Event {
    fn from(event: location::Event) -> Self {
        Self::Location(event)
    }
}

/// Solar elevation in degrees (NOAA's low-precision formulas, ~0.01°).
fn solar_elevation(place: Coordinates, time: SystemTime) -> f64 {
    let seconds = time
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64();
    let days = seconds / 86_400.0 + 2_440_587.5 - 2_451_545.0;
    let mean_longitude = (280.460 + 0.985_647_4 * days).rem_euclid(360.0);
    let mean_anomaly = (357.528 + 0.985_600_3 * days)
        .rem_euclid(360.0)
        .to_radians();
    let ecliptic_longitude =
        (mean_longitude + 1.915 * mean_anomaly.sin() + 0.020 * (2.0 * mean_anomaly).sin())
            .to_radians();
    let obliquity = (23.439 - 0.000_000_4 * days).to_radians();
    let right_ascension = (obliquity.cos() * ecliptic_longitude.sin())
        .atan2(ecliptic_longitude.cos())
        .to_degrees();
    let declination = (obliquity.sin() * ecliptic_longitude.sin()).asin();
    let sidereal = (18.697_374_558 + 24.065_709_824_419_08 * days).rem_euclid(24.0) * 15.0;
    let hour_angle = (sidereal + place.longitude - right_ascension).to_radians();
    let latitude = place.latitude.to_radians();
    (latitude.sin() * declination.sin() + latitude.cos() * declination.cos() * hour_angle.cos())
        .asin()
        .to_degrees()
}

fn setting_at(place: Coordinates, time: SystemTime) -> Setting {
    let elevation = solar_elevation(place, time);
    if elevation >= SUNRISE_ELEVATION {
        return Setting::Identity;
    }
    if elevation <= CIVIL_TWILIGHT_ELEVATION {
        return Setting::Temperature(NIGHT_TEMPERATURE);
    }
    let progress =
        (elevation - CIVIL_TWILIGHT_ELEVATION) / (SUNRISE_ELEVATION - CIVIL_TWILIGHT_ELEVATION);
    let kelvin =
        f64::from(NIGHT_TEMPERATURE) + progress * f64::from(DAY_TEMPERATURE - NIGHT_TEMPERATURE);
    Setting::Temperature((kelvin as u32) / TEMPERATURE_STEP * TEMPERATURE_STEP)
}

/// How long the current setting holds: a minute during the ramp, otherwise
/// until the minute the sun crosses into the next phase.
fn holds_for(place: Coordinates, now: SystemTime) -> Duration {
    let current = setting_at(place, now);
    if !matches!(
        current,
        Setting::Identity | Setting::Temperature(NIGHT_TEMPERATURE)
    ) {
        return RAMP_UPDATE;
    }
    let mut ahead = RAMP_UPDATE;
    while ahead < LOOKAHEAD {
        if setting_at(place, now + ahead) != current {
            return ahead;
        }
        ahead += RAMP_UPDATE;
    }
    LOOKAHEAD
}

struct Hyprsunset(PathBuf);

impl Hyprsunset {
    fn from_environment() -> Result<Self> {
        let runtime = std::env::var_os("XDG_RUNTIME_DIR").context("XDG_RUNTIME_DIR is not set")?;
        let signature = std::env::var("HYPRLAND_INSTANCE_SIGNATURE")
            .context("HYPRLAND_INSTANCE_SIGNATURE is not set")?;
        ensure!(
            !signature.contains('/'),
            "invalid HYPRLAND_INSTANCE_SIGNATURE"
        );
        Ok(Self(
            PathBuf::from(runtime)
                .join("hypr")
                .join(signature)
                .join(".hyprsunset.sock"),
        ))
    }

    fn apply(&self, setting: Setting) -> Result<()> {
        let request = match setting {
            Setting::Identity => "identity".to_owned(),
            Setting::Temperature(kelvin) => format!("temperature {kelvin}"),
        };
        let mut stream = UnixStream::connect(&self.0).context("hyprsunset is not running")?;
        stream.set_read_timeout(Some(REQUEST_TIMEOUT))?;
        stream.set_write_timeout(Some(REQUEST_TIMEOUT))?;
        stream.write_all(request.as_bytes())?;
        // hyprsunset answers once but keeps the connection open.
        let mut buffer = [0u8; 64];
        let length = stream
            .read(&mut buffer)
            .context("hyprsunset did not answer")?;
        let reply = String::from_utf8_lossy(&buffer[..length]);
        ensure!(
            reply.trim() == "ok",
            "hyprsunset rejected {request:?}: {}",
            reply.trim()
        );
        Ok(())
    }
}

/// Runs until a signal source fails; systemd restarts it.
pub fn run() -> Result<i32> {
    let hyprsunset = Hyprsunset::from_environment()?;
    let (events, incoming) = mpsc::channel::<Event>();
    if let Err(error) = location::follow(events.clone()) {
        eprintln!("wave night-light: {error:#}; keeping the last known location");
    }
    let bus = Connection::system().context("system bus unavailable")?;
    let sleeps = LoginManagerProxyBlocking::new(&bus)?.receive_prepare_for_sleep()?;
    {
        let events = events.clone();
        std::thread::spawn(move || {
            for signal in sleeps {
                let resumed = signal.args().is_ok_and(|args| !args.start);
                if resumed && events.send(Event::Resumed).is_err() {
                    return;
                }
            }
            let _ = events.send(Event::Lost("logind sleep signals ended"));
        });
    }
    drop(events);

    let mut place = location::cached().unwrap_or(WARSAW);
    let mut applied = None;
    loop {
        let now = SystemTime::now();
        let setting = setting_at(place, now);
        let mut wait = holds_for(place, now);
        if applied != Some(setting) {
            match hyprsunset.apply(setting) {
                Ok(()) => applied = Some(setting),
                Err(error) => {
                    eprintln!("wave night-light: {error:#}");
                    wait = wait.min(RETRY);
                }
            }
        }
        // Monotonic waits stop during suspend; resume re-evaluates the sky.
        match incoming.recv_timeout(wait) {
            Ok(Event::Location(location::Event::Moved(coordinates))) => place = coordinates,
            Ok(Event::Location(location::Event::Lost(reason))) => bail!("{reason}"),
            Ok(Event::Resumed) => applied = None,
            Ok(Event::Lost(reason)) => bail!("{reason}"),
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => bail!("all event sources stopped"),
        }
    }
}
