//! `GET /api/status`. Shared by the Vercel function and the self-host server.

use serde_json::json;
use vercel_runtime::{Request, Response, ResponseBody};

use crate::{
    customer::{error, reply},
    store::{ConnectionError, Supabase},
};

pub async fn handle(request: Request) -> Response<ResponseBody> {
    if request.method() != "GET" {
        return error(405, "method_not_allowed", "Use GET.");
    }
    let database = match Supabase::from_env() {
        Ok(supabase) => match supabase.check_connection().await {
            Ok(()) => "connected",
            Err(_) => "unavailable",
        },
        Err(ConnectionError::MissingConfiguration) => "unconfigured",
        Err(_) => "unavailable",
    };
    reply(
        200,
        json!({
            "service": "fizz",
            "status": if database == "connected" { "ok" } else { "degraded" },
            "database": database,
            "description": "The physical layer for AI agents"
        }),
        None,
    )
}
