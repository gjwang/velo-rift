use anyhow::Result;
use clap::{Parser, Subcommand};

use tokio::signal;

#[derive(Parser)]
#[command(name = "velod")]
#[command(version, about = "Velo Rift Daemon", long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand)]
enum Commands {
    /// Start the daemon (default)
    Start,
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    match cli.command.unwrap_or(Commands::Start) {
        Commands::Start => start_daemon().await?,
    }

    Ok(())
}

use std::path::Path;
use tokio::net::{UnixListener, UnixStream};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use velo_ipc::{VeloRequest, VeloResponse};

async fn start_daemon() -> Result<()> {
    println!("velod: Starting daemon...");

    let socket_path = "/tmp/velo.sock";
    let path = Path::new(socket_path);

    // Clean up existing socket file if it exists
    if path.exists() {
        // In a real scenario, we might want to check if it's actually live
        // For now, assume we can overwrite it
        tokio::fs::remove_file(path).await?;
    }

    let listener = UnixListener::bind(path)?;
    println!("velod: Listening on {}", socket_path);

    // Wait for shutdown signal
    loop {
        tokio::select! {
            accept_result = listener.accept() => {
                match accept_result {
                    Ok((stream, _addr)) => {
                        tokio::spawn(handle_connection(stream));
                    }
                    Err(err) => {
                        eprintln!("velod: Accept error: {}", err);
                        // Continue loop despite error
                    }
                }
            }
            _ = signal::ctrl_c() => {
                println!("velod: Shutdown signal received");
                break;
            }
        }
    }

    println!("velod: Shutting down");
    // Cleanup
    if path.exists() {
        tokio::fs::remove_file(path).await?;
    }

    Ok(())
}

async fn handle_connection(mut stream: UnixStream) {
    // Basic framing: Length-prefixed (u32) + Bincode
    loop {
        // 1. Read length (4 bytes)
        let mut len_buf = [0u8; 4];
        if let Err(_) = stream.read_exact(&mut len_buf).await {
            // Connection closed or error
            return;
        }
        let len = u32::from_le_bytes(len_buf) as usize;

        // 2. Read payload
        let mut buf = vec![0u8; len];
        if let Err(_) = stream.read_exact(&mut buf).await {
            return;
        }

        // 3. Deserialize
        let response = match bincode::deserialize::<VeloRequest>(&buf) {
            Ok(req) => handle_request(req).await,
            Err(e) => VeloResponse::Error(format!("Invalid request: {}", e)),
        };

        // 4. Serialize response
        let resp_bytes = match bincode::serialize(&response) {
            Ok(b) => b,
            Err(e) => {
                eprintln!("Failed to serialize response: {}", e);
                return;
            }
        };

        // 5. Write length
        let resp_len = (resp_bytes.len() as u32).to_le_bytes();
        if let Err(_) = stream.write_all(&resp_len).await {
            return;
        }

        // 6. Write payload
        if let Err(_) = stream.write_all(&resp_bytes).await {
            return;
        }
    }
}

async fn handle_request(req: VeloRequest) -> VeloResponse {
    println!("Received request: {:?}", req);
    match req {
        VeloRequest::Handshake { client_version } => {
            println!("Handshake from client: {}", client_version);
            VeloResponse::HandshakeAck {
                server_version: env!("CARGO_PKG_VERSION").to_string(),
            }
        }
        VeloRequest::Status => {
            VeloResponse::StatusAck {
                status: "Operational".to_string(),
            }
        }
    }
}
