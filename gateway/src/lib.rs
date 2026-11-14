//! Fizzlayer's gateway control pieces: config rendering, client JWTs, and the
//! policy decisions fizz-guard applies. The MCP data plane is unmodified agentgateway.

pub mod config;
pub mod db;
pub mod error;
pub mod jwt;
pub mod pin;
pub mod policy;

pub mod ext_mcp {
    tonic::include_proto!("agentgateway.dev.ext_mcp");
}
