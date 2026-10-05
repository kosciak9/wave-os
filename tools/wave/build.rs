fn main() {
    println!("cargo:rerun-if-changed=oslog.c");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        cc::Build::new().file("oslog.c").compile("wave_oslog");
    }
}
