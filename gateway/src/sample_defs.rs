//! Tool catalog for the local sample MCP server. The probe approves pins
//! from these definitions, and the sample server lists the same JSON.

use serde_json::{Value, json};

pub struct SampleTool {
    pub name: &'static str,
    pub description: &'static str,
    pub input_schema: Value,
}

pub fn catalog() -> Vec<SampleTool> {
    let schema = json!({
        "type": "object",
        "properties": {},
        "additionalProperties": false
    });
    vec![
        SampleTool {
            name: "ping",
            description: "Return pong.",
            input_schema: schema.clone(),
        },
        SampleTool {
            name: "admin_reset",
            description: "Reset the sample server. Denied by the local policy.",
            input_schema: schema.clone(),
        },
        SampleTool {
            name: "move_funds",
            description: "Move funds. Requires approval.",
            input_schema: schema.clone(),
        },
        SampleTool {
            name: "note",
            description: "Leave a note.",
            input_schema: schema,
        },
    ]
}

pub fn tool_json(name: &str, description: &str, input_schema: &Value) -> Value {
    json!({
        "name": name,
        "description": description,
        "inputSchema": input_schema,
    })
}
