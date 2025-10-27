use anyhow::{Result, anyhow};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use bundles_rs::ans104::data_item::DataItem;
use once_cell::sync::Lazy;

pub mod ao;
pub mod bundler;
pub mod constants;

use ao::post_to_mu;
use constants::{AO_TAGS, RT};

async fn verify_construct_payment(x_payment: &str) -> Result<String> {
    let di_bytes = URL_SAFE_NO_PAD
        .decode(x_payment.trim())
        .map_err(|err| anyhow!("invalid base64 data item: {err}"))?;

    let data_item = DataItem::from_bytes(di_bytes.as_slice())
        .map_err(|err| anyhow!("invalid ANS-104 dataitem: {err}"))?;

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

    post_to_mu(di_bytes).await?;

    Ok(data_item.arweave_id())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn facilitate_payment(x_payment: String) -> Result<String, String> {
    RT.block_on(verify_construct_payment(&x_payment)).map_err(|err| err.to_string())
}

rustler::init!("x402");
