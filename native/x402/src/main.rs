use anyhow::{anyhow, Error, Result};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use bundles_rs::ans104::{data_item, tags::Tag};
use bundles_rs::bundler::BundlerClient;
use bundles_rs::crypto::arweave::ArweaveSigner;
use reqwest::header::{ACCEPT, CONTENT_TYPE};

const MU_ENDPOINT: &str = "https://mu.ao-testnet.xyz";
const PROCESS_ID: &str = "SAR3pyWRX7dbIcCRgbJsoCQ1i0jPh67b0SUlAM1XhVg";

pub mod constants;
pub mod bundler;

fn arweave_b64_to_32(s: &str) -> Result<[u8; 32], Error> {
    let decoded = URL_SAFE_NO_PAD
        .decode(s.trim())
        .map_err(|e| anyhow!("invalid base64url Arweave string: {e}"))?;
    decoded
        .as_slice()
        .try_into()
        .map_err(|_| anyhow!("decoded length is {}, expected 32", decoded.len()))
}

async fn post_to_mu(bytes: Vec<u8>) -> Result<()> {
    let client = reqwest::Client::new();
    let response = client
        .post(MU_ENDPOINT)
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
        println!("messenger accepted message: {body}");
        Ok(())
    } else {
        Err(anyhow!("messenger rejected message ({status}): {body}"))
    }
}

#[tokio::main]
pub async fn main() -> Result<()> {
    let signer = ArweaveSigner::from_jwk_file("./wallet.json")?;
    println!("SIGNER: {:?}", signer.address());
    let target = "A".repeat(43);

    let tags = vec![
        Tag::new("Action", "Transfer"),
        Tag::new("Recipient", target),
        Tag::new("Quantity", "1"),
        Tag::new("Client", "x402"),
        Tag::new("Data-Protocol", "ao"),
        Tag::new("Variant", "ao.TN.1"),
        Tag::new("Type", "Message"),
        Tag::new("Content-Type", "text/plain"),
        Tag::new("SDK", "x402-facilitator"),
    ];

    let target = arweave_b64_to_32(PROCESS_ID)?;
    let di = data_item::DataItem::build_and_sign(
        &signer,
        Some(target),
        None,
        tags,
        "hello from the x402 nif side".as_bytes().to_vec(),
    )
    .map_err(|err| anyhow!("failed to build data item: {err}"))?;

    println!("DATAITEM CREATED: {:?}", di.arweave_id());

    let bundler = BundlerClient::turbo().build()?;
    let tx = bundler
        .send_transaction(di.clone())
        .await
        .map_err(|err| anyhow!("bundler publish failed: {err}"))?;
    println!("dataitem sent to arweave, txid: {:?}", tx.id);

    let di_bytes = di
        .to_bytes()
        .map_err(|err| anyhow!("failed to serialize data item: {err}"))?;
    post_to_mu(di_bytes).await?;

    Ok(())
}
