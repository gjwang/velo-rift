use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize)]
pub enum VeloRequest {
    Handshake { client_version: String },
    Status,
}

#[derive(Debug, Serialize, Deserialize)]
pub enum VeloResponse {
    HandshakeAck { server_version: String },
    StatusAck { status: String },
    Error(String),
}
