use bundles_rs::{ans104::tags::Tag, bundler::BundlerClient};
use once_cell;
use once_cell::sync::Lazy;
use std::sync::Mutex;

pub const MU_RL: &str = "https://mu.ao-testnet.xyz";

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
