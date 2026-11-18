//! Fizzlayer's gateway control pieces: config rendering, client JWTs, and the
//! policy decisions fizz-guard applies. The MCP data plane is unmodified agentgateway.

pub mod config;
pub mod error;
pub mod jwt;
pub mod pin;
pub mod policy;
pub mod sample_defs;
pub mod toolpin;

#[cfg(feature = "guard")]
pub mod admin;
#[cfg(feature = "guard")]
pub mod memory;
#[cfg(feature = "guard")]
pub mod notify;
#[cfg(feature = "guard")]
pub mod store;

#[cfg(feature = "guard")]
pub mod db;

#[cfg(feature = "guard")]
pub mod ext_mcp {
    tonic::include_proto!("agentgateway.dev.ext_mcp");
}
