//! The host's approximate location from GeoClue, shared by session daemons.

use crate::dbus::{
    GeoClueClientProxyBlocking, GeoClueLocationProxyBlocking, GeoClueManagerProxyBlocking,
};
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::mpsc::Sender;
use zbus::blocking::Connection;

/// GeoClue authorizes clients by this desktop ID; see its appConfig on jayce.
const DESKTOP_ID: &str = "wave";
/// GeoClue's city level; nothing here needs a street.
const CITY_ACCURACY: u32 = 4;
/// Updates only after moving this far, so a laptop at rest stays quiet.
const DISTANCE_THRESHOLD_METERS: u32 = 10_000;
const CACHE_FILE: &str = "location.json";

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Coordinates {
    pub latitude: f64,
    pub longitude: f64,
}

impl Coordinates {
    fn valid(&self) -> bool {
        (-90.0..=90.0).contains(&self.latitude) && (-180.0..=180.0).contains(&self.longitude)
    }
}

pub enum Event {
    Moved(Coordinates),
    Lost(String),
}

/// A file in wave's cache directory, where session daemons leave what they
/// learned for the next start and for the desktop shell.
fn cache_path(name: &str) -> Option<PathBuf> {
    let base = std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".cache")))?;
    Some(base.join("wave").join(name))
}

/// Replaces the cache file in one rename, so readers never see half of it.
pub fn store_cached(name: &str, value: &impl Serialize) -> Result<()> {
    let path = cache_path(name).context("no cache directory")?;
    std::fs::create_dir_all(path.parent().expect("cache file has a parent"))?;
    let temporary = path.with_extension("tmp");
    std::fs::write(&temporary, serde_json::to_vec(value)?)?;
    std::fs::rename(&temporary, &path)?;
    Ok(())
}

/// The last location GeoClue reported, kept so a restart starts in place.
pub fn cached() -> Option<Coordinates> {
    let coordinates: Coordinates =
        serde_json::from_slice(&std::fs::read(cache_path(CACHE_FILE)?).ok()?).ok()?;
    coordinates.valid().then_some(coordinates)
}

/// Starts a GeoClue client and forwards every location it reports, caching
/// each one. The client lives as long as the forwarding thread.
pub fn follow<T: From<Event> + Send + 'static>(events: Sender<T>) -> Result<()> {
    let bus = Connection::system().context("system bus unavailable")?;
    let client_path = GeoClueManagerProxyBlocking::new(&bus)?.get_client()?;
    let client = GeoClueClientProxyBlocking::builder(&bus)
        .path(client_path)?
        .build()?;
    client.set_desktop_id(DESKTOP_ID)?;
    client.set_requested_accuracy_level(CITY_ACCURACY)?;
    client.set_distance_threshold(DISTANCE_THRESHOLD_METERS)?;
    let updates = client.receive_location_updated()?;
    client
        .start()
        .context("GeoClue refused to locate this host")?;
    std::thread::spawn(move || {
        let _client = client;
        for signal in updates {
            let Ok(args) = signal.args() else { continue };
            let read = || -> zbus::Result<Coordinates> {
                let location = GeoClueLocationProxyBlocking::builder(&bus)
                    .path(args.new.to_owned())?
                    .build()?;
                Ok(Coordinates {
                    latitude: location.latitude()?,
                    longitude: location.longitude()?,
                })
            };
            match read() {
                Ok(coordinates) if coordinates.valid() => {
                    if let Err(error) = store_cached(CACHE_FILE, &coordinates) {
                        eprintln!("wave location: cannot cache the location: {error:#}");
                    }
                    if events.send(Event::Moved(coordinates).into()).is_err() {
                        return;
                    }
                }
                Ok(_) => eprintln!("wave location: GeoClue reported invalid coordinates"),
                Err(error) => eprintln!("wave location: cannot read the location: {error}"),
            }
        }
        let _ = events.send(Event::Lost("GeoClue location signals ended".into()).into());
    });
    Ok(())
}
