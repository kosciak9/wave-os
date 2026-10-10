//! Keep the paired InfiniTime watch connected through BlueZ, set its clock
//! on every connection and send it the weather for this host's location.

use crate::dbus::{
    BluezAdapterProxyBlocking, BluezDeviceProxyBlocking, GattCharacteristicProxyBlocking,
    LoginManagerProxyBlocking,
};
use crate::location::{self, Coordinates};
use anyhow::{Context, Result, bail};
use serde::Deserialize;
use std::collections::HashMap;
use std::process::Command;
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::time::{Duration, Instant};
use zbus::blocking::Connection;
use zbus::blocking::fdo::{ObjectManagerProxy, PropertiesProxy};
use zbus::zvariant::{OwnedObjectPath, OwnedValue};

const WATCH_NAME: &str = "InfiniTime";
const CURRENT_TIME: &str = "00002a2b-0000-1000-8000-00805f9b34fb";
/// InfiniTime's SimpleWeatherService data characteristic.
const WEATHER: &str = "00050001-78fc-48fe-8e23-433b3a1942d0";
/// A connection attempt waits inside BlueZ until the watch shows up or BlueZ
/// gives up; further attempts back off while the watch stays away.
const FIRST_RETRY: Duration = Duration::from_secs(1);
const LAST_RETRY: Duration = Duration::from_secs(60);
/// With nothing scheduled the loop only wakes for events.
const IDLE_WAIT: Duration = Duration::from_secs(3600);
const WEATHER_REFRESH: Duration = Duration::from_secs(3600);
const WEATHER_RETRY: Duration = Duration::from_secs(15 * 60);
const FORECAST_URL: &str = "https://api.met.no/weatherapi/locationforecast/2.0/compact";
/// MET Norway requires an identifying User-Agent.
const USER_AGENT: &str = "wave-os/0.1 github.com/kosciak9/wave-os";

enum Event {
    DeviceChanged,
    AdapterChanged,
    Resumed,
    Location(location::Event),
    Connected(Result<(), String>),
    Lost(String),
}

impl From<location::Event> for Event {
    fn from(event: location::Event) -> Self {
        Self::Location(event)
    }
}

/// What InfiniTime's weather screen shows: °C and its icon enum.
#[derive(Clone, Copy)]
struct Weather {
    temperature: f64,
    minimum: f64,
    maximum: f64,
    icon: u8,
}

/// The paired watch's D-Bus object, found by its advertised name.
fn find_watch(objects: &ObjectManagerProxy<'_>) -> Result<OwnedObjectPath> {
    let objects = objects.get_managed_objects()?;
    let text = |properties: &HashMap<String, OwnedValue>, key: &str| {
        properties
            .get(key)
            .and_then(|value| String::try_from(value.try_clone().ok()?).ok())
    };
    objects
        .iter()
        .find_map(|(path, interfaces)| {
            let device = interfaces.get("org.bluez.Device1")?;
            let paired = device
                .get("Paired")
                .and_then(|value| bool::try_from(value).ok())
                .unwrap_or(false);
            (paired && text(device, "Name").as_deref() == Some(WATCH_NAME)).then(|| path.clone())
        })
        .with_context(|| format!("no paired {WATCH_NAME} watch in BlueZ"))
}

fn characteristic(
    bus: &Connection,
    watch: &OwnedObjectPath,
    uuid: &str,
) -> Result<GattCharacteristicProxyBlocking<'static>> {
    let objects = ObjectManagerProxy::builder(bus)
        .destination("org.bluez")?
        .path("/")?
        .build()?
        .get_managed_objects()?;
    let path = objects
        .iter()
        .find(|(path, interfaces)| {
            path.as_str().starts_with(watch.as_str())
                && interfaces
                    .get("org.bluez.GattCharacteristic1")
                    .and_then(|properties| properties.get("UUID"))
                    .and_then(|value| String::try_from(value.try_clone().ok()?).ok())
                    .is_some_and(|value| value.eq_ignore_ascii_case(uuid))
        })
        .map(|(path, _)| path.clone())
        .with_context(|| format!("the watch has no characteristic {uuid}"))?;
    Ok(GattCharacteristicProxyBlocking::builder(bus)
        .path(path)?
        .build()?)
}

fn local_time() -> libc::tm {
    let now = unsafe { libc::time(std::ptr::null_mut()) };
    let mut local: libc::tm = unsafe { std::mem::zeroed() };
    unsafe { libc::localtime_r(&now, &mut local) };
    local
}

/// Bluetooth Current Time: local wall-clock time, Monday = 1.
fn current_time_value() -> Vec<u8> {
    let local = local_time();
    let year = (local.tm_year + 1900) as u16;
    let weekday = if local.tm_wday == 0 {
        7
    } else {
        local.tm_wday as u8
    };
    let mut value = year.to_le_bytes().to_vec();
    value.extend([
        (local.tm_mon + 1) as u8,
        local.tm_mday as u8,
        local.tm_hour as u8,
        local.tm_min as u8,
        local.tm_sec as u8,
        weekday,
        0,
        1, // adjust reason: manual time update
    ]);
    value
}

/// SimpleWeatherService "current weather", version 0: local timestamp,
/// temperatures in hundredths of °C, an empty location label and the icon.
fn weather_value(weather: &Weather) -> Vec<u8> {
    let local = local_time();
    let now = unsafe { libc::time(std::ptr::null_mut()) };
    let hundredths = |celsius: f64| ((celsius * 100.0).round() as i16).to_le_bytes();
    let mut value = vec![0, 0];
    value.extend((now + local.tm_gmtoff).to_le_bytes());
    value.extend(hundredths(weather.temperature));
    value.extend(hundredths(weather.minimum));
    value.extend(hundredths(weather.maximum));
    value.extend([0u8; 32]);
    value.push(weather.icon);
    value
}

/// Maps MET Norway symbol codes onto InfiniTime's weather icons.
fn icon(symbol: &str) -> u8 {
    let kind = symbol.split('_').next().unwrap_or_default();
    match kind {
        _ if kind.contains("thunder") => 6,
        _ if kind.contains("snow") || kind.contains("sleet") => 7,
        "fog" => 8,
        _ if kind.ends_with("showers") => 5,
        _ if kind.contains("rain") => 4,
        "clearsky" => 0,
        "fair" => 1,
        "partlycloudy" => 2,
        "cloudy" => 3,
        _ => 255,
    }
}

#[derive(Deserialize)]
struct Forecast {
    properties: ForecastProperties,
}

#[derive(Deserialize)]
struct ForecastProperties {
    timeseries: Vec<TimeStep>,
}

#[derive(Deserialize)]
struct TimeStep {
    data: TimeStepData,
}

#[derive(Deserialize)]
struct TimeStepData {
    instant: Now,
    next_1_hours: Option<Period>,
    next_6_hours: Option<Period>,
}

#[derive(Deserialize)]
struct Now {
    details: InstantDetails,
}

#[derive(Deserialize)]
struct InstantDetails {
    air_temperature: f64,
}

#[derive(Deserialize)]
struct Period {
    summary: Option<Summary>,
    details: Option<PeriodDetails>,
}

#[derive(Deserialize)]
struct Summary {
    symbol_code: String,
}

#[derive(Deserialize)]
struct PeriodDetails {
    air_temperature_min: Option<f64>,
    air_temperature_max: Option<f64>,
}

/// Coordinates are rounded to two decimals (about 1 km), as MET asks and
/// as the forecast needs no more.
fn fetch_weather(place: Coordinates) -> Result<Weather> {
    let url = format!(
        "{FORECAST_URL}?lat={:.2}&lon={:.2}",
        place.latitude, place.longitude
    );
    let mut command = Command::new("curl");
    command.args([
        "-q",
        "-sSf",
        "--proto",
        "=https",
        "--max-time",
        "20",
        "-A",
        USER_AGENT,
        &url,
    ]);
    let output = crate::process::capture(&mut command, Duration::from_secs(25))?;
    if !output.success() {
        bail!("MET Norway request failed ({})", output.code);
    }
    let forecast: Forecast = serde_json::from_slice(&output.stdout).context("invalid forecast")?;
    let now = &forecast
        .properties
        .timeseries
        .first()
        .context("empty forecast")?
        .data;
    let temperature = now.instant.details.air_temperature;
    let range = now
        .next_6_hours
        .as_ref()
        .and_then(|period| period.details.as_ref());
    let symbol = now
        .next_1_hours
        .as_ref()
        .or(now.next_6_hours.as_ref())
        .and_then(|period| period.summary.as_ref())
        .map(|summary| summary.symbol_code.as_str())
        .unwrap_or_default();
    Ok(Weather {
        temperature,
        minimum: range
            .and_then(|details| details.air_temperature_min)
            .unwrap_or(temperature)
            .min(temperature),
        maximum: range
            .and_then(|details| details.air_temperature_max)
            .unwrap_or(temperature)
            .max(temperature),
        icon: icon(symbol),
    })
}

fn forward_properties(
    bus: &Connection,
    path: &str,
    interface: &'static str,
    watched: &'static [&'static str],
    event: fn() -> Event,
    events: Sender<Event>,
) -> Result<()> {
    let changes = PropertiesProxy::builder(bus)
        .destination("org.bluez")?
        .path(path.to_owned())?
        .build()?
        .receive_properties_changed()?;
    std::thread::spawn(move || {
        for signal in changes {
            let relevant = signal.args().is_ok_and(|args| {
                args.interface_name.as_str() == interface
                    && args
                        .changed_properties
                        .keys()
                        .any(|name| watched.contains(name))
            });
            if relevant && events.send(event()).is_err() {
                return;
            }
        }
        let _ = events.send(Event::Lost(format!("{interface} signals ended")));
    });
    Ok(())
}

/// Runs until BlueZ or logind goes away; systemd restarts it.
pub fn run() -> Result<i32> {
    let bus = Connection::system().context("system bus unavailable")?;
    let objects = ObjectManagerProxy::builder(&bus)
        .destination("org.bluez")?
        .path("/")?
        .build()?;
    let watch_path = find_watch(&objects)?;
    let adapter_path = watch_path
        .as_str()
        .rsplit_once('/')
        .map(|(adapter, _)| adapter.to_owned())
        .context("watch path has no adapter")?;
    let watch = BluezDeviceProxyBlocking::builder(&bus)
        .path(watch_path.clone())?
        .cache_properties(zbus::proxy::CacheProperties::No)
        .build()?;
    let adapter = BluezAdapterProxyBlocking::builder(&bus)
        .path(adapter_path.clone())?
        .cache_properties(zbus::proxy::CacheProperties::No)
        .build()?;

    let (events, incoming) = mpsc::channel::<Event>();
    forward_properties(
        &bus,
        watch_path.as_str(),
        "org.bluez.Device1",
        &["Connected", "ServicesResolved"],
        || Event::DeviceChanged,
        events.clone(),
    )?;
    forward_properties(
        &bus,
        &adapter_path,
        "org.bluez.Adapter1",
        &["Powered"],
        || Event::AdapterChanged,
        events.clone(),
    )?;
    {
        let sleeps = LoginManagerProxyBlocking::new(&bus)?.receive_prepare_for_sleep()?;
        let events = events.clone();
        std::thread::spawn(move || {
            for signal in sleeps {
                let resumed = signal.args().is_ok_and(|args| !args.start);
                if resumed && events.send(Event::Resumed).is_err() {
                    return;
                }
            }
            let _ = events.send(Event::Lost("logind sleep signals ended".into()));
        });
    }
    if let Err(error) = location::follow(events.clone()) {
        eprintln!("wave watch: {error:#}; keeping the last known location");
    }

    let mut place = location::cached();
    let mut weather: Option<Weather> = None;
    let mut weather_due = Instant::now();
    let mut connecting = false;
    let mut retry_delay = FIRST_RETRY;
    let mut connect_due = Some(Instant::now());
    let mut synced = false;

    loop {
        let now = Instant::now();
        let ready =
            watch.connected().unwrap_or(false) && watch.services_resolved().unwrap_or(false);
        if !ready {
            synced = false;
        }

        if now >= weather_due
            && let Some(place) = place
        {
            match fetch_weather(place) {
                Ok(fresh) => {
                    weather = Some(fresh);
                    weather_due = now + WEATHER_REFRESH;
                    synced = false;
                }
                Err(error) => {
                    eprintln!("wave watch: weather unavailable: {error:#}");
                    weather_due = now + WEATHER_RETRY;
                }
            }
        }

        if ready && !synced {
            let time = characteristic(&bus, &watch_path, CURRENT_TIME).and_then(|time| {
                time.write_value(&current_time_value(), HashMap::new())
                    .context("cannot set the watch's clock")
            });
            let forecast = match &weather {
                Some(weather) => characteristic(&bus, &watch_path, WEATHER).and_then(|target| {
                    target
                        .write_value(&weather_value(weather), HashMap::new())
                        .context("cannot send the weather")
                }),
                None => Ok(()),
            };
            match (time, forecast) {
                (Ok(()), Ok(())) => synced = true,
                (time, forecast) => {
                    for error in [time.err(), forecast.err()].into_iter().flatten() {
                        eprintln!("wave watch: {error:#}");
                    }
                }
            }
        }

        let connected = watch.connected().unwrap_or(false);
        if connected {
            retry_delay = FIRST_RETRY;
            connect_due = None;
        } else if !connecting
            && adapter.powered().unwrap_or(false)
            && connect_due.is_some_and(|due| now >= due)
        {
            connecting = true;
            connect_due = None;
            let bus = bus.clone();
            let path = watch_path.clone();
            let events = events.clone();
            std::thread::spawn(move || {
                let attempt = BluezDeviceProxyBlocking::builder(&bus)
                    .path(path)
                    .and_then(|builder| builder.build())
                    .and_then(|device| device.connect());
                let _ = events.send(Event::Connected(attempt.map_err(|error| error.to_string())));
            });
        }

        let due = [connect_due, (place.is_some()).then_some(weather_due)]
            .into_iter()
            .flatten()
            .min();
        let wait = due.map_or(IDLE_WAIT, |due| {
            due.saturating_duration_since(Instant::now())
        });
        match incoming.recv_timeout(wait) {
            Ok(Event::DeviceChanged) => {
                if !connecting && !watch.connected().unwrap_or(false) {
                    connect_due.get_or_insert(Instant::now());
                }
            }
            Ok(Event::AdapterChanged) => {
                retry_delay = FIRST_RETRY;
                connect_due = Some(Instant::now());
            }
            // Monotonic deadlines stand still during suspend.
            Ok(Event::Resumed) => {
                retry_delay = FIRST_RETRY;
                connect_due = Some(Instant::now());
                weather_due = Instant::now();
                synced = false;
            }
            Ok(Event::Connected(result)) => {
                connecting = false;
                if let Err(error) = result {
                    if !watch.connected().unwrap_or(false) {
                        connect_due = Some(Instant::now() + retry_delay);
                        retry_delay = (retry_delay * 2).min(LAST_RETRY);
                    }
                    if retry_delay == LAST_RETRY {
                        eprintln!("wave watch: still unreachable: {error}");
                    }
                }
            }
            Ok(Event::Location(location::Event::Moved(coordinates))) => {
                place = Some(coordinates);
                weather_due = Instant::now();
            }
            Ok(Event::Location(location::Event::Lost(reason))) | Ok(Event::Lost(reason)) => {
                bail!("{reason}")
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => bail!("all event sources stopped"),
        }
    }
}
