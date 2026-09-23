// The sign-in client IDs are read with option_env! (src/api/signin.rs): rebuild when any
// of them changes, so a cached build never ships an old one.
fn main() {
    for var in [
        "FLOMSI_GOOGLE_CLIENT_ID",
        "FLOMSI_GOOGLE_CLIENT_SECRET",
        "FLOMSI_GOOGLE_IOS_CLIENT_ID",
        "FLOMSI_GOOGLE_ANDROID_CLIENT_ID",
        "FLOMSI_MICROSOFT_CLIENT_ID",
    ] {
        println!("cargo:rerun-if-env-changed={var}");
    }
}
