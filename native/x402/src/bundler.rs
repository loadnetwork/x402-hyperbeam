use bundles_rs::ans104::data_item::DataItem;
use anyhow::{Error, anyhow};

use crate::constants::{BUNDLER_CLIENT};

pub async fn send_to_arweave(di: DataItem) -> Result<Vec<u8>, Error> {
    let bundler = BUNDLER_CLIENT.lock().map_err(|_| anyhow!("error lazy initializing the bundle turbo client"))?;
    
    let tx = bundler.clone()
        .send_transaction(di.clone())
        .await
        .map_err(|err| anyhow!("bundler publish failed: {err}"))?;
    
    println!("dataitem sent to arweave, txid: {:?}", tx.id);

    let di_bytes = di
        .to_bytes()
        .map_err(|err| anyhow!("failed to serialize data item: {err}"));
    di_bytes
}