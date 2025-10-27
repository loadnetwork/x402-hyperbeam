use anyhow::{Result, anyhow};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use bundles_rs::ans104::data_item::DataItem;

pub mod ao;
pub mod bundler;
pub mod constants;

use ao::post_to_mu;
use constants::{AO_TAGS, DEFAULT_SUPPORTED_TOKENS, RT, SUPPORTED_TOKENS};

async fn verify_construct_payment(x_payment: &str) -> Result<String> {
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

    post_to_mu(di_bytes).await?;

    Ok(data_item.arweave_id())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn facilitate_payment(x_payment: String) -> Result<String, String> {
    RT.block_on(verify_construct_payment(&x_payment)).map_err(|err| err.to_string())
}

#[rustler::nif]
fn set_supported_tokens(tokens: Vec<String>) -> Result<(), String> {
    let mut guard =
        SUPPORTED_TOKENS.lock().map_err(|_| "failed to lock supported tokens".to_string())?;

    let filtered: Vec<String> = tokens
        .into_iter()
        .map(|token| token.trim().to_string())
        .filter(|token| !token.is_empty())
        .collect();

    if filtered.is_empty() {
        *guard = DEFAULT_SUPPORTED_TOKENS.iter().map(|token| token.to_string()).collect();
    } else {
        let mut unique = filtered;
        unique.sort();
        unique.dedup();
        *guard = unique;
    }

    Ok(())
}

#[rustler::nif]
fn supported_tokens() -> Result<Vec<String>, String> {
    SUPPORTED_TOKENS
        .lock()
        .map(|guard| guard.clone())
        .map_err(|_| "failed to lock supported tokens".to_string())
}

rustler::init!("x402");

#[cfg(test)]
mod tests {
    use super::{AO_TAGS, SUPPORTED_TOKENS};
    use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
    use bundles_rs::{
        ans104::{data_item::DataItem, tags::Tag},
        crypto::arweave::ArweaveSigner,
    };

    use crate::{ao::arweave_b64_to_32, constants::DEFAULT_SUPPORTED_TOKENS};

    #[tokio::test]
    #[ignore = "requires a local HyperBEAM node listening on http://localhost:8734 and a wallet in './wallet.json' location"]
    async fn premium_route_accepts_signed_payment() {
        let signer = ArweaveSigner::from_jwk_file("./wallet.json")
            .expect("wallet.json should contain a valid Arweave JWK");
        let mut current_tokens = SUPPORTED_TOKENS.lock().expect("supported tokens mutex poisoned");
        if current_tokens.is_empty() {
            *current_tokens =
                DEFAULT_SUPPORTED_TOKENS.iter().map(|token| token.to_string()).collect();
        }
        let active_token = current_tokens[1].clone();
        drop(current_tokens);

        let target =
            arweave_b64_to_32(&active_token).expect("decode configured payment target");

        let mut tags = AO_TAGS.lock().expect("AO_TAGS mutex poisoned").clone();
        tags.push(Tag::new("Recipient", "i4gRwtgSJumEv5-m16VTnsK4uZiVzA__pnVDdYsqQww"));
        tags.push(Tag::new("Quantity", "1"));

        let data_item = DataItem::build_and_sign(
            &signer,
            Some(target),
            None,
            tags,
            b"premium access test".to_vec(),
        )
        .expect("failed to sign data item");

        let di_bytes = data_item.to_bytes().expect("failed to serialize data item for transport");
        let x_payment = URL_SAFE_NO_PAD.encode(&di_bytes);

        let client = reqwest::Client::new();
        let response = client
            .get("http://localhost:8734/~x402@1.0/premium")
            .header("X-Payment", &x_payment)
            .send()
            .await
            .expect("failed to reach local HyperBEAM node");

        let status = response.status();
        let body = response
            .text()
            .await
            .expect("failed to read premium response body");

        assert!(status.is_success(), "expected success status, got {}", status);
        println!("unlocked x402 content: {:?}", body);
        assert!(
            body.contains("hello world from the x402 nif sid"),
            "unexpected premium body: {body}"
        );
    }
}
