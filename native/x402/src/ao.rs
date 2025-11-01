use crate::constants::MU_RL;
use anyhow::{Error, Result, anyhow};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use bundles_rs::ans104::data_item::DataItem;
use reqwest::header::{ACCEPT, CONTENT_TYPE};

use crate::constants::{AO_TAGS, SUPPORTED_TOKENS};

pub fn arweave_b64_to_32(s: &str) -> Result<[u8; 32], Error> {
    let decoded = URL_SAFE_NO_PAD
        .decode(s.trim())
        .map_err(|e| anyhow!("invalid base64url Arweave string: {e}"))?;
    decoded
        .as_slice()
        .try_into()
        .map_err(|_| anyhow!("decoded length is {}, expected 32", decoded.len()))
}
pub async fn settle(bytes: Vec<u8>) -> Result<()> {
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

pub async fn verify(x_payment: &str) -> Result<DataItem, Error> {
    let di_bytes = URL_SAFE_NO_PAD
        .decode(x_payment.trim())
        .map_err(|err| anyhow!("invalid base64 data item: {err}"))?;

    let data_item = DataItem::from_bytes(di_bytes.as_slice())
        .map_err(|err| anyhow!("invalid ANS-104 dataitem: {err}"))?;
    let encoded_target = data_item
        .target
        .as_ref()
        .map(|target| URL_SAFE_NO_PAD.encode(target))
        .ok_or_else(|| anyhow!("dataitem missing target field"))?;

    anyhow::ensure!(
        {
            let tokens =
                SUPPORTED_TOKENS.lock().map_err(|_| anyhow!("failed to lock supported tokens"))?;
            tokens.iter().any(|accepted| accepted == &encoded_target)
        },
        "unsupported payment target {encoded_target}"
    );
    let required_tags = AO_TAGS.lock().map_err(|_| anyhow!("failed to lock AO tags"))?.clone();

    for required in &required_tags {
        if !data_item.tags.contains(required) {
            return Err(anyhow!(
                "dataitem missing required tag {}={}",
                required.name,
                required.value
            ));
        }
    }

    Ok(data_item)
}
