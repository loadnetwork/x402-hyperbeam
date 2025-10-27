use crate::constants::MU_RL;
use anyhow::{Error, Result, anyhow};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use reqwest::header::{ACCEPT, CONTENT_TYPE};

pub fn arweave_b64_to_32(s: &str) -> Result<[u8; 32], Error> {
    let decoded = URL_SAFE_NO_PAD
        .decode(s.trim())
        .map_err(|e| anyhow!("invalid base64url Arweave string: {e}"))?;
    decoded
        .as_slice()
        .try_into()
        .map_err(|_| anyhow!("decoded length is {}, expected 32", decoded.len()))
}

pub async fn post_to_mu(bytes: Vec<u8>) -> Result<()> {
    let client = reqwest::Client::new();

    let response = client
        .post(MU_RL)
        .header(CONTENT_TYPE, "application/octet-stream")
        .header(ACCEPT, "application/json")
        .body(bytes)
        .send()
        .await?;

    let status = response.status();
    let body = response.text().await.unwrap_or_else(|err| {
        eprintln!("failed to read MU response body: {err}");
        String::new()
    });

    if status.is_success() {
        println!("MU accepted message: {body}");
        Ok(())
    } else {
        Err(anyhow!("MU rejected message ({status}): {body}"))
    }
}
