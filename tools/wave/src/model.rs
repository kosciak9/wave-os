pub const BASE: &str = "/var/lib/wave-os";
pub const PROFILE: &str = "/nix/var/nix/profiles/system";
pub const CURRENT: &str = "/run/current-system";

pub fn sha40(value: &str) -> bool {
    value.len() == 40
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
