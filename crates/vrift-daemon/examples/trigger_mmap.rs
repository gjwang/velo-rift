use std::time::{SystemTime, UNIX_EPOCH};
use vrift_ipc::client::DaemonClient;
use vrift_ipc::VeloRequest;
use vrift_manifest::VnodeEntry;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let mut client = DaemonClient::connect().await?;
    client.handshake().await?;

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();

    let entry = VnodeEntry::new_file(
        [0u8; 32], // dummy hash
        1024, now, 0o644,
    );

    println!("Sending 10,000 ManifestUpserts to daemon...");

    for i in 0..10000 {
        let path = format!("/vrift/test_{}.txt", i);
        let req = VeloRequest::ManifestUpsert {
            path,
            entry: entry.clone(),
        };
        client.send(req).await?;
    }

    println!("Done. Check daemon logs and /tmp/vrift-manifest.mmap");
    Ok(())
}
