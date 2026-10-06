use serde::{Deserialize, Serialize};
use std::path::PathBuf;

pub const BASE: &str = "/var/lib/wave-os";
pub const PROFILE: &str = "/nix/var/nix/profiles/system";
pub const CURRENT: &str = "/run/current-system";
pub const DEPLOY_REV: &str = "cf64c8cbadd9b13ea79ba7720aa2930500f2ece7";
pub const CONFIRM_TIMEOUT: u64 = 150;
pub const ACTIVATION_TIMEOUT: u64 = 300;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, clap::ValueEnum)]
#[serde(rename_all = "lowercase")]
pub enum Host {
    Renekton,
    Jayce,
    Ahri,
}

impl Host {
    pub fn name(self) -> &'static str {
        match self {
            Self::Renekton => "renekton",
            Self::Jayce => "jayce",
            Self::Ahri => "ahri",
        }
    }

    pub fn platform(self) -> &'static str {
        match self {
            Self::Renekton => "aarch64-darwin",
            Self::Jayce => "x86_64-linux",
            Self::Ahri => "aarch64-linux",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Snapshot {
    pub profile: PathBuf,
    pub system: PathBuf,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Operation {
    pub id: String,
    pub host: Host,
    pub commit: String,
    pub old: Snapshot,
    pub new: Snapshot,
    pub temp: PathBuf,
    pub cancelled: bool,
    pub health_approved: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Outcome {
    Success,
    Restored,
    Reconciled,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ResultRecord {
    pub id: String,
    pub commit: String,
    pub outcome: Outcome,
    pub snapshot: Snapshot,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct State {
    pub operation: Option<Operation>,
    pub last_result: Option<ResultRecord>,
    pub rollback_commit: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NativeReceipt {
    pub operation: Operation,
    pub supervisor_pid: u32,
    pub child_pid: u32,
    pub exit_code: Option<i32>,
    pub terminal: bool,
    pub confirmed: bool,
    pub snapshot: Option<Snapshot>,
}

pub fn sha40(value: &str) -> bool {
    value.len() == 40
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
