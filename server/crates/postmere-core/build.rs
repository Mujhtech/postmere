fn main() {
    // sqlx embeds migrations at compile time. Rebuild when migrations are added
    // as well as when an existing migration changes.
    println!("cargo:rerun-if-changed=../../migrations");
}
