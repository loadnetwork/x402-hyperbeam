use bundles_rs::{ans104::tags::Tag, bundler::BundlerClient};
use once_cell::{self, sync::Lazy};
use std::sync::Mutex;

pub const MU_RL: &str = "https://mu.ao-testnet.xyz";

pub const DEFAULT_SUPPORTED_TOKENS: [&str; 2] = [
    "0syT13r0s0tgPmIed95bJnuSqaD29HQNN8D3ElLSrsc", // $AO
    "SAR3pyWRX7dbIcCRgbJsoCQ1i0jPh67b0SUlAM1XhVg", // $1984 (internal testing token)
];

pub static SUPPORTED_TOKENS: Lazy<Mutex<Vec<String>>> = Lazy::new(|| {
    Mutex::new(DEFAULT_SUPPORTED_TOKENS.iter().map(|token| token.to_string()).collect())
});

pub static AO_TAGS: Lazy<Mutex<Vec<Tag>>> = Lazy::new(|| {
    let network_tags = vec![
        Tag::new("Action", "Transfer"),
        Tag::new("Client", "x402"),
        Tag::new("Data-Protocol", "ao"),
        Tag::new("Variant", "ao.TN.1"),
        Tag::new("Type", "Message"),
        Tag::new("Content-Type", "text/plain"),
        Tag::new("SDK", "x402-facilitator"),
    ];
    Mutex::new(network_tags)
});

pub static BUNDLER_CLIENT: Lazy<Mutex<BundlerClient>> = Lazy::new(|| {
    let client = BundlerClient::turbo().build().unwrap();
    Mutex::new(client)
});

pub static RT: Lazy<tokio::runtime::Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("failed to build tokio runtime")
});
