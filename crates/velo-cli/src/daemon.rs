use anyhow::{Context, Result};
use std::path::Path;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use velo_ipc::{VeloRequest, VeloResponse};

pub async fn check_status() -> Result<()> {
    let socket_path = "/tmp/velo.sock";
    
    // 1. Connect
    let mut stream = UnixStream::connect(socket_path)
        .await
        .with_context(|| format!("Failed to connect to daemon at {}", socket_path))?;

    // 2. Handshake
    let req = VeloRequest::Handshake {
        client_version: env!("CARGO_PKG_VERSION").to_string(),
    };
    send_request(&mut stream, req).await?;
    let resp = read_response(&mut stream).await?;

    match resp {
        VeloResponse::HandshakeAck { server_version } => {
            println!("Daemon Connected. Server v{}", server_version);
        }
        _ => anyhow::bail!("Unexpected handshake response: {:?}", resp),
    }

    // 3. Status
    let req = VeloRequest::Status;
    send_request(&mut stream, req).await?;
    let resp = read_response(&mut stream).await?;

    match resp {
        VeloResponse::StatusAck { status } => {
            println!("Daemon Status: {}", status);
        }
        _ => anyhow::bail!("Unexpected status response: {:?}", resp),
    }

    Ok(())
}

async fn send_request(stream: &mut UnixStream, req: VeloRequest) -> Result<()> {
    let bytes = bincode::serialize(&req)?;
    let len = (bytes.len() as u32).to_le_bytes();
    stream.write_all(&len).await?;
    stream.write_all(&bytes).await?;
    Ok(())
}

async fn read_response(stream: &mut UnixStream) -> Result<VeloResponse> {
    let mut len_buf = [0u8; 4];
    stream.read_exact(&mut len_buf).await?;
    let len = u32::from_le_bytes(len_buf) as usize;

    let mut buf = vec![0u8; len];
    stream.read_exact(&mut buf).await?;

    let resp = bincode::deserialize(&buf)?;
    Ok(resp)
}
