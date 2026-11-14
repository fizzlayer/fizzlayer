//! Fizzlayer's gateway control pieces: config rendering, client JWTs, and the
//! policy decisions fizz-guard applies. The MCP data plane is unmodified agentgateway.

pub mod admin;
pub mod config;
pub mod db;
pub mod error;
pub mod jwt;
pub mod memory;
pub mod notify;
pub mod pin;
pub mod policy;
pub mod sample_defs;
pub mod store;
pub mod toolpin;

pub mod ext_mcp {
    tonic::include_proto!("agentgateway.dev.ext_mcp");
}
