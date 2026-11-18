//! In-memory stand-in for `public.fizz_gateway`. The handler tests drive this
//! through the same actions the SQL function implements.

use std::collections::HashMap;
use std::sync::Mutex;

use serde_json::{Value, json};
use uuid::Uuid;

use crate::customer::ApiError;
use crate::gateway::limits::{self, plan};
use crate::gateway::store::Backend;

struct Workspace {
    plan: String,
}

struct GatewayRow {
    workspace: Uuid,
    name: String,
    mode: String,
    region: Option<String>,
    public_url: String,
    listen_port: u16,
    status: String,
    unreviewed_tools: String,
    revision: i64,
    order: u64,
}

struct ServerRow {
    gateway: Uuid,
    name: String,
    transport: String,
    url: String,
    args: Vec<String>,
    auth_kind: String,
    ciphertext: Option<String>,
    enabled: bool,
    order: u64,
}

struct PolicyRow {
    gateway: Uuid,
    server: Option<Uuid>,
    tool: String,
    effect: String,
    notify_channel: String,
}

struct PinRow {
    gateway: Uuid,
    server_name: String,
    tool: String,
    pin_sha256: String,
    observed_sha256: String,
    status: String,
}

struct AlertRow {
    gateway: Uuid,
    server_name: String,
    tool: String,
    observed_sha256: String,
    description_preview: String,
    acknowledged: bool,
}

struct ApprovalRow {
    gateway: Uuid,
    server_name: String,
    tool: String,
    args_preview: String,
    status: String,
    notify_channel: String,
    expires_at: u64,
}

struct TokenRow {
    gateway: Uuid,
    name: String,
    jti: String,
    expires_at: u64,
    revoked: bool,
}

struct Member {
    workspace: Uuid,
    user: Uuid,
    role: String,
}

struct State {
    users: HashMap<String, Uuid>,
    plans: HashMap<Uuid, String>,
    owned: HashMap<Uuid, Uuid>,
    workspaces: HashMap<Uuid, Workspace>,
    gateways: HashMap<Uuid, GatewayRow>,
    servers: HashMap<Uuid, ServerRow>,
    policies: HashMap<Uuid, PolicyRow>,
    pins: HashMap<Uuid, PinRow>,
    alerts: HashMap<Uuid, AlertRow>,
    approvals: HashMap<Uuid, ApprovalRow>,
    tokens: HashMap<Uuid, TokenRow>,
    registrations: Vec<(Uuid, String, bool)>,
    members: Vec<Member>,
    order: u64,
    pem: Vec<u8>,
    secret: [u8; 32],
}

pub struct Memory {
    state: Mutex<State>,
}

impl Memory {
    pub fn new(pem: Vec<u8>, secret: [u8; 32]) -> Self {
        let mut users = HashMap::new();
        let mut plans = HashMap::new();
        for (token, plan_id) in [
            ("user-a", "hobbyist"),
            ("user-b", "hobbyist"),
            ("user-c", "hobbyist"),
            ("user-pro", "pro"),
        ] {
            let id = Uuid::new_v4();
            users.insert(token.to_string(), id);
            plans.insert(id, plan_id.to_string());
        }
        Self {
            state: Mutex::new(State {
                users,
                plans,
                owned: HashMap::new(),
                workspaces: HashMap::new(),
                gateways: HashMap::new(),
                servers: HashMap::new(),
                policies: HashMap::new(),
                pins: HashMap::new(),
                alerts: HashMap::new(),
                approvals: HashMap::new(),
                tokens: HashMap::new(),
                registrations: Vec::new(),
                members: Vec::new(),
                order: 0,
                pem,
                secret,
            }),
        }
    }

    pub fn add_member(&self, owner_token: &str, member_token: &str, role: &str) {
        let mut state = self.state.lock().expect("memory");
        let owner = state.users[owner_token];
        let member = state.users[member_token];
        state.ensure(owner);
        let workspace = state.owned[&owner];
        state.members.push(Member {
            workspace,
            user: member,
            role: role.to_string(),
        });
    }

    pub fn seed_pin(&self, gateway: &str, server: &str, tool: &str) {
        let mut state = self.state.lock().expect("memory");
        let gateway = Uuid::parse_str(gateway).expect("gateway id");
        state.pins.insert(
            Uuid::new_v4(),
            PinRow {
                gateway,
                server_name: server.to_string(),
                tool: tool.to_string(),
                pin_sha256: "ab".repeat(32),
                observed_sha256: "ab".repeat(32),
                status: "unreviewed".to_string(),
            },
        );
    }

    pub fn seed_approval(&self, gateway: &str, tool: &str) -> String {
        let mut state = self.state.lock().expect("memory");
        let gateway = Uuid::parse_str(gateway).expect("gateway id");
        let id = Uuid::new_v4();
        state.approvals.insert(
            id,
            ApprovalRow {
                gateway,
                server_name: "github".to_string(),
                tool: tool.to_string(),
                args_preview: "amount".to_string(),
                status: "pending".to_string(),
                notify_channel: "log".to_string(),
                expires_at: unix_now().saturating_add(600),
            },
        );
        id.to_string()
    }
}

impl Backend for Memory {
    async fn authenticate(&self, token: &str) -> Result<Uuid, ApiError> {
        self.state
            .lock()
            .expect("memory")
            .users
            .get(token)
            .copied()
            .ok_or_else(|| ApiError::new(401, "unauthorized", "Sign in to continue."))
    }

    async fn call(
        &self,
        user: Option<Uuid>,
        action: &str,
        payload: Value,
    ) -> Result<Value, ApiError> {
        let mut state = self.state.lock().expect("memory");
        Ok(state.dispatch(user, action, &payload))
    }

    fn signing_pem(&self) -> Result<Vec<u8>, ApiError> {
        Ok(self.state.lock().expect("memory").pem.clone())
    }

    fn secret_key(&self) -> Result<[u8; 32], ApiError> {
        Ok(self.state.lock().expect("memory").secret)
    }

    fn guard_host(&self) -> Result<String, ApiError> {
        Ok("fizz-guard:9001".to_string())
    }

    fn jwks_url(&self, _origin: &str) -> String {
        "https://fizzlayer.com/api/gateway/jwks".to_string()
    }
}

impl State {
    fn next_order(&mut self) -> u64 {
        self.order += 1;
        self.order
    }

    fn ensure(&mut self, user: Uuid) -> Option<Uuid> {
        if let Some(workspace) = self.owned.get(&user).copied() {
            return Some(workspace);
        }
        let plan_id = self.plans.get(&user)?.clone();
        let workspace = Uuid::new_v4();
        self.workspaces
            .insert(workspace, Workspace { plan: plan_id });
        self.owned.insert(user, workspace);
        self.members.push(Member {
            workspace,
            user,
            role: "owner".to_string(),
        });
        Some(workspace)
    }

    fn role(&self, user: Uuid, workspace: Uuid) -> Option<&str> {
        self.members
            .iter()
            .find(|member| member.user == user && member.workspace == workspace)
            .map(|member| member.role.as_str())
    }

    fn dispatch(&mut self, user: Option<Uuid>, action: &str, payload: &Value) -> Value {
        match action {
            "context" => self.context(user),
            "create_gateway" => self.create_gateway(user, payload),
            "delete_gateway" => self.delete_gateway(user, payload),
            "list_servers" => self.list_servers(user, payload),
            "add_server" => self.add_server(user, payload),
            "remove_server" => self.remove_server(user, payload),
            "list_policies" => self.list_policies(user, payload),
            "set_policy" => self.set_policy(user, payload),
            "delete_policy" => self.delete_policy(user, payload),
            "set_unreviewed" => self.set_unreviewed(user, payload),
            "list_pins" => self.list_pins(user, payload),
            "approve_pin" => self.approve_pin(user, payload),
            "list_pin_alerts" => self.list_alerts(user, payload),
            "ack_pin_alert" => self.ack_alert(user, payload),
            "list_approvals" => self.list_approvals(user, payload),
            "decide_approval" => self.decide_approval(user, payload),
            "render_source" => self.render_source(user, payload, false),
            "agent_config" => self.agent_config(payload),
            "insert_token" => self.insert_token(user, payload),
            "list_tokens" => self.list_tokens(user, payload),
            "revoke_token" => self.revoke_token(user, payload),
            "rotate_registration" => self.rotate(user, payload),
            _ => json!({"error": "invalid_request"}),
        }
    }

    fn context(&mut self, user: Option<Uuid>) -> Value {
        let Some(user) = user else {
            return json!({"error": "not_found"});
        };
        let Some(workspace) = self.ensure(user) else {
            return json!({"error": "not_found"});
        };
        let workspaces: Vec<Uuid> = self
            .members
            .iter()
            .filter(|member| member.user == user)
            .map(|member| member.workspace)
            .collect();
        for workspace in workspaces {
            self.apply_caps(workspace);
        }
        let gateways = self.gateway_list(user);
        let role = self.role(user, workspace).unwrap_or("owner");
        let plan_id = self.workspaces[&workspace].plan.clone();
        json!({
            "workspace_id": workspace,
            "role": role,
            "plan": plan_json(&plan_id),
            "gateways": gateways,
        })
    }

    fn gateway_list(&self, user: Uuid) -> Vec<Value> {
        let mut rows = Vec::new();
        for member in &self.members {
            if member.user != user {
                continue;
            }
            for (id, gateway) in &self.gateways {
                if gateway.workspace == member.workspace {
                    rows.push((gateway.order, gateway_json(id, gateway, &member.role)));
                }
            }
        }
        rows.sort_by_key(|(order, _)| *order);
        rows.into_iter().map(|(_, row)| row).collect()
    }

    fn create_gateway(&mut self, user: Option<Uuid>, payload: &Value) -> Value {
        let Some(user) = user else {
            return json!({"error": "not_found"});
        };
        let Some(workspace) = self.ensure(user) else {
            return json!({"error": "not_found"});
        };
        let role = self.role(user, workspace).unwrap_or("").to_string();
        if !matches!(role.as_str(), "owner" | "admin") {
            return json!({"error": "forbidden"});
        }
        self.apply_caps(workspace);
        let name = payload["name"].as_str().unwrap_or("");
        if !limits::gateway_name_ok(name) {
            return json!({"error": "invalid_request"});
        }
        let limits = plan(&self.workspaces[&workspace].plan);
        let mode = payload["mode"]
            .as_str()
            .filter(|mode| !mode.is_empty())
            .unwrap_or_else(|| limits::default_mode(limits.dedicated));
        if !matches!(mode, "shared" | "dedicated" | "selfhost") {
            return json!({"error": "invalid_request"});
        }
        if mode == "dedicated" && !limits.dedicated {
            return json!({"error": "dedicated_not_included"});
        }
        let count = self
            .gateways
            .values()
            .filter(|gateway| gateway.workspace == workspace)
            .count() as i64;
        if limits.gateway_limit.is_some_and(|limit| count >= limit) {
            return json!({"error": "gateway_limit"});
        }
        let id = payload["id"]
            .as_str()
            .and_then(|value| Uuid::parse_str(value).ok())
            .unwrap_or_else(Uuid::new_v4);
        let public_url = match payload["public_url"].as_str().filter(|url| !url.is_empty()) {
            Some(url) if limits::remote_url_ok(url) && url.len() <= 300 => url.to_string(),
            Some(_) => return json!({"error": "invalid_request"}),
            None if mode == "selfhost" => return json!({"error": "invalid_request"}),
            None if mode == "dedicated" => format!("https://{name}.gw.fizzlayer.com/mcp"),
            None => format!("https://gw.fizzlayer.com/w/{id}/mcp"),
        };
        let hash = payload["registration_hash"].as_str().unwrap_or("");
        if hash.len() != 64 {
            return json!({"error": "invalid_request"});
        }
        if self
            .gateways
            .values()
            .any(|gateway| gateway.workspace == workspace && gateway.name == name)
        {
            return json!({"error": "conflict"});
        }
        let order = self.next_order();
        self.gateways.insert(
            id,
            GatewayRow {
                workspace,
                name: name.to_string(),
                mode: mode.to_string(),
                region: payload["region"].as_str().map(str::to_string),
                public_url: public_url.clone(),
                listen_port: payload["listen_port"].as_u64().unwrap_or(3000) as u16,
                status: "active".to_string(),
                unreviewed_tools: "hide".to_string(),
                revision: 1,
                order,
            },
        );
        self.registrations.push((id, hash.to_string(), false));
        json!({
            "gateway": gateway_json(&id, &self.gateways[&id], &role),
        })
    }

    fn delete_gateway(&mut self, user: Option<Uuid>, payload: &Value) -> Value {
        let Some((id, _)) = self.write_gateway(user, payload) else {
            return self.read_error(user, payload);
        };
        self.gateways.remove(&id);
        self.servers.retain(|_, server| server.gateway != id);
        self.policies.retain(|_, policy| policy.gateway != id);
        self.pins.retain(|_, pin| pin.gateway != id);
        self.alerts.retain(|_, alert| alert.gateway != id);
        self.approvals.retain(|_, approval| approval.gateway != id);
        self.tokens.retain(|_, token| token.gateway != id);
        self.registrations.retain(|(gateway, _, _)| *gateway != id);
        json!({"deleted": true, "id": id})
    }

    fn list_servers(&self, user: Option<Uuid>, payload: &Value) -> Value {
        let Some(id) = self.read_gateway(user, payload) else {
            return self.read_error(user, payload);
        };
        let mut rows: Vec<_> = self
            .servers
            .iter()
            .filter(|(_, server)| server.gateway == id)
            .map(|(sid, server)| (server.order, server_json(sid, server)))
            .collect();
        rows.sort_by_key(|(order, _)| *order);
        json!({"servers": rows.into_iter().map(|(_, row)| row).collect::<Vec<_>>()})
    }

    fn add_server(&mut self, user: Option<Uuid>, payload: &Value) -> Value {
        let Some((gateway_id, _)) = self.write_gateway(user, payload) else {
            return self.read_error(user, payload);
        };
        let workspace = self.gateways[&gateway_id].workspace;
        let mode = self.gateways[&gateway_id].mode.clone();
        self.apply_caps(workspace);
        let name = payload["name"].as_str().unwrap_or("");
        let transport = payload["transport"].as_str().unwrap_or("http");
        let url = payload["url"].as_str().unwrap_or("");
        let auth_kind = payload["auth_kind"].as_str().unwrap_or("none");
        if !limits::server_name_ok(name)
            || !matches!(transport, "http" | "sse" | "stdio")
            || !matches!(auth_kind, "none" | "key" | "passthrough")
        {
            return json!({"error": "invalid_request"});
        }
        if matches!(transport, "http" | "sse") && !limits::remote_url_ok(url) {
            return json!({"error": "invalid_request"});
        }
        if transport == "stdio" && !limits::command_ok(url) {
            return json!({"error": "invalid_request"});
        }
        let limits = plan(&self.workspaces[&workspace].plan);
        if transport == "stdio" && !limits.stdio {
            return json!({"error": "stdio_not_included"});
        }
        if transport == "stdio" && mode == "shared" {
            return json!({"error": "stdio_shared"});
        }
        let count = self
            .servers
            .values()
            .filter(|server| server.gateway == gateway_id)
            .count() as i64;
        if limits.server_limit.is_some_and(|limit| count >= limit) {
            return json!({"error": "server_limit"});
        }
        if self
            .servers
            .values()
            .any(|server| server.gateway == gateway_id && server.name == name)
        {
            return json!({"error": "conflict"});
        }
        let ciphertext = payload["ciphertext"].as_str().map(str::to_string);
        if auth_kind == "key" && ciphertext.is_none() {
            return json!({"error": "invalid_request"});
        }
        let id = Uuid::new_v4();
        let order = self.next_order();
        let args = payload["args"]
            .as_array()
            .map(|items| {
                items
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::to_string)
                    .collect()
            })
            .unwrap_or_default();
        self.servers.insert(
            id,
            ServerRow {
                gateway: gateway_id,
                name: name.to_string(),
                transport: transport.to_string(),
                url: url.to_string(),
                args,
                auth_kind: auth_kind.to_string(),
                ciphertext,
                enabled: true,
                order,
            },
        );
        self.bump(gateway_id);
        json!({"server": server_json(&id, &self.servers[&id])})
    }

    fn remove_server(&mut self, user: Option<Uuid>, payload: &Value) -> Value {
        let Some((gateway_id, _)) = self.write_gateway(user, payload) else {
            return self.read_error(user, payload);
        };
        let Some(server_id) = uuid_field(payload, "server_id") else {
            return json!({"error": "invalid_request"});
        };
        match self.servers.get(&server_id) {
            Some(server) if server.gateway == gateway_id => {}
            _ => return json!({"error": "not_found"}),
        }
        self.servers.remove(&server_id);
        self.policies
            .retain(|_, policy| policy.server != Some(server_id));
        self.bump(gateway_id);
        json!({"deleted": true, "id": server_id})
    }

    fn list_policies(&self, user: Option<Uuid>, payload: &Value) -> Value {
        let Some(gateway_id) = self.read_gateway(user, payload) else {
            return self.read_error(user, payload);
        };
        let policies: Vec<_> = self
            .policies
            .iter()
            .filter(|(_, policy)| policy.gateway == gateway_id)
            .map(|(id, policy)| policy_json(id, policy))
            .collect();
        json!({"policies": policies})
    }

    fn set_policy(&mut self, user: Option<Uuid>, payload: &Value) -> Value {
        let Some((gateway_id, _)) = self.write_gateway(user, payload) else {
            return self.read_error(user, payload);
        };
        let tool = payload["tool_name"].as_str().unwrap_or("");
        let effect = payload["effect"].as_str().unwrap_or("");
        let channel = payload["notify_channel"].as_str();
        if !limits::tool_name_ok(tool)
            || !limits::effect_ok(effect)
            || channel.is_some_and(|value| !matches!(value, "log" | "webhook" | "phone"))
        {
            return json!({"error": "invalid_request"});
        }
        let server = match payload["server_id"].as_str() {
            None | Some("") => None,
            Some(value) => match Uuid::parse_str(value) {
                Ok(id)
                    if self
                        .servers
                        .get(&id)
                        .is_some_and(|server| server.gateway == gateway_id) =>
                {
                    Some(id)
                }
                _ => return json!({"error": "not_found"}),
            },
        };
        let existing = self
            .policies
            .iter()
            .find(|(_, policy)| {
                policy.gateway == gateway_id && policy.tool == tool && policy.server == server
            })
            .map(|(id, _)| *id);
        if let Some(id) = existing {
            let policy = self.policies.get_mut(&id).expect("policy");
            policy.effect = effect.to_string();
            if let Some(channel) = channel {
                policy.notify_channel = channel.to_string();
            }
            self.bump(gateway_id);
            return json!({"policy": policy_json(&id, &self.policies[&id])});
        }
        let id = Uuid::new_v4();
        self.policies.insert(
            id,
            PolicyRow {
                gateway: gateway_id,
                server,
                tool: tool.to_string(),
                effect: effect.to_string(),
                notify_channel: channel.unwrap_or("log").to_string(),
            },
        );
        self.bump(gateway_id);
        json!({"policy": policy_json(&id, &self.policies[&id])})
    }

    fn delete_policy(&mut self, user: Option<Uuid>, payload: &Value) -> Value {
        let Some((gateway_id, _)) = self.write_gateway(user, payload) else {
            return self.read_error(user, payload);
        };
        let Some(policy_id) = uuid_field(payload, "policy_id") else {
            return json!({"error": "invalid_request"});
        };
        match self.policies.get(&policy_id) {
            Some(policy) if policy.gateway == gateway_id => {}
            _ => return json!({"error": "not_found"}),
        }
        self.policies.remove(&policy_id);
        self.bump(gateway_id);
        json!({"deleted": true, "id": policy_id})
    }

    fn render_source(&mut self, user: Option<Uuid>, payload: &Value, with_secret: bool) -> Value {
        let Some(gateway_id) = self.read_gateway(user, payload) else {
            return self.read_error(user, payload);
        };
        self.source(gateway_id, with_secret)
    }

    fn agent_config(&mut self, payload: &Value) -> Value {
        let hash = payload["token_hash"].as_str().unwrap_or("");
        let Some(gateway_id) = self
            .registrations
            .iter()
            .find(|(_, stored, revoked)| stored == hash && !revoked)
            .map(|(gateway, _, _)| *gateway)
        else {
            return json!({"error": "not_found"});
        };
        let gateway = &self.gateways[&gateway_id];
        if gateway.status != "active" {
            return json!({"error": "disabled", "config_revision": gateway.revision});
        }
        self.source(gateway_id, true)
    }

    fn source(&self, gateway_id: Uuid, with_secret: bool) -> Value {
        let gateway = &self.gateways[&gateway_id];
        let mut servers: Vec<_> = self
            .servers
            .values()
            .filter(|server| server.gateway == gateway_id && server.enabled)
            .collect();
        servers.sort_by(|left, right| left.name.cmp(&right.name));
        let servers: Vec<_> = servers
            .into_iter()
            .map(|server| {
                json!({
                    "name": server.name,
                    "transport": server.transport,
                    "url": server.url,
                    "args": server.args,
                    "auth_kind": server.auth_kind,
                    "ciphertext": if with_secret { server.ciphertext.clone() } else { None },
                    "key_id": if with_secret && server.ciphertext.is_some() { Some(crate::gateway::crypto::KEY_ID) } else { None },
                })
            })
            .collect();
        json!({
            "gateway_id": gateway_id,
            "workspace_id": gateway.workspace,
            "mode": gateway.mode,
            "public_url": gateway.public_url,
            "listen_port": gateway.listen_port,
            "config_revision": gateway.revision,
            "ag_version": Value::Null,
            "status": gateway.status,
            "servers": servers,
        })
    }

    fn insert_token(&mut self, user: Option<Uuid>, payload: &Value) -> Value {
        let Some(user) = user else {
            return json!({"error": "not_found"});
        };
        let Some((gateway_id, _)) = self.write_gateway(Some(user), payload) else {
            return self.read_error(Some(user), payload);
        };
        let gateway = &self.gateways[&gateway_id];
        if gateway.status != "active" {
            return json!({"error": "disabled"});
        }
        let name = payload["name"].as_str().unwrap_or("");
        let jti = payload["jti"].as_str().unwrap_or("");
        let expires_at = payload["expires_at"].as_u64().unwrap_or(0);
        let now = unix_now();
        if name.is_empty()
            || name.len() > 80
            || jti.len() != 36
            || expires_at <= now
            || expires_at > now + 30 * 24 * 60 * 60
        {
            return json!({"error": "invalid_request"});
        }
        let id = Uuid::new_v4();
        let audience = gateway.public_url.clone();
        let workspace = gateway.workspace;
        self.tokens.insert(
            id,
            TokenRow {
                gateway: gateway_id,
                name: name.to_string(),
                jti: jti.to_string(),
                expires_at,
                revoked: false,
            },
        );
        json!({
            "token": {
                "id": id,
                "gateway_id": gateway_id,
                "workspace_id": workspace,
                "name": name,
                "jti": jti,
                "expires_at": expires_at,
                "audience": audience,
                "revoked_at": Value::Null,
            }
        })
    }

    fn list_tokens(&self, user: Option<Uuid>, payload: &Value) -> Value {
        let Some(gateway_id) = self.read_gateway(user, payload) else {
            return self.read_error(user, payload);
        };
        let tokens: Vec<_> = self
            .tokens
            .iter()
            .filter(|(_, token)| token.gateway == gateway_id)
            .map(|(id, token)| {
                json!({
                    "id": id,
                    "name": token.name,
                    "jti": token.jti,
                    "expires_at": token.expires_at,
                    "revoked_at": if token.revoked { json!("revoked") } else { Value::Null },
                })
            })
            .collect();
        json!({"tokens": tokens})
    }

    fn revoke_token(&mut self, user: Option<Uuid>, payload: &Value) -> Value {
        let Some((gateway_id, _)) = self.write_gateway(user, payload) else {
            return self.read_error(user, payload);
        };
        let Some(token_id) = uuid_field(payload, "token_id") else {
            return json!({"error": "invalid_request"});
        };
        match self.tokens.get_mut(&token_id) {
            Some(token) if token.gateway == gateway_id => token.revoked = true,
            _ => return json!({"error": "not_found"}),
        }
        json!({"revoked": true, "id": token_id})
    }

    fn rotate(&mut self, user: Option<Uuid>, payload: &Value) -> Value {
        let Some((gateway_id, _)) = self.write_gateway(user, payload) else {
            return self.read_error(user, payload);
        };
        let hash = payload["registration_hash"].as_str().unwrap_or("");
        if hash.len() != 64 {
            return json!({"error": "invalid_request"});
        }
        for (gateway, _, revoked) in &mut self.registrations {
            if *gateway == gateway_id {
                *revoked = true;
            }
        }
        self.registrations
            .push((gateway_id, hash.to_string(), false));
        json!({"rotated": true, "gateway_id": gateway_id})
    }

    fn set_unreviewed(&mut self, user: Option<Uuid>, payload: &Value) -> Value {
        let Some((gateway_id, role)) = self.write_gateway(user, payload) else {
            return self.read_error(user, payload);
        };
        let mode = payload["unreviewed_tools"].as_str().unwrap_or("");
        if !matches!(mode, "hide" | "show") {
            return json!({"error": "invalid_request"});
        }
        self.gateways
            .get_mut(&gateway_id)
            .expect("gateway")
            .unreviewed_tools = mode.to_string();
        json!({"gateway": gateway_json(&gateway_id, &self.gateways[&gateway_id], &role)})
    }

    fn list_pins(&self, user: Option<Uuid>, payload: &Value) -> Value {
        let Some(gateway_id) = self.read_gateway(user, payload) else {
            return self.read_error(user, payload);
        };
        let pins: Vec<_> = self
            .pins
            .iter()
            .filter(|(_, pin)| pin.gateway == gateway_id)
            .map(|(id, pin)| pin_json(id, pin))
            .collect();
        json!({"pins": pins})
    }

    fn approve_pin(&mut self, user: Option<Uuid>, payload: &Value) -> Value {
        let Some((gateway_id, _)) = self.write_gateway(user, payload) else {
            return self.read_error(user, payload);
        };
        let server = payload["server"].as_str().unwrap_or("");
        let tool = payload["tool"].as_str().unwrap_or("");
        let found = self.pins.iter().find_map(|(id, pin)| {
            (pin.gateway == gateway_id
                && pin.server_name == server
                && pin.tool == tool
                && matches!(pin.status.as_str(), "changed" | "unreviewed"))
            .then_some(*id)
        });
        let Some(id) = found else {
            return json!({"error": "not_found"});
        };
        {
            let pin = self.pins.get_mut(&id).expect("pin");
            pin.pin_sha256.clone_from(&pin.observed_sha256);
            pin.status = "approved".to_string();
        }
        for alert in self.alerts.values_mut() {
            if alert.gateway == gateway_id && alert.server_name == server && alert.tool == tool {
                alert.acknowledged = true;
            }
        }
        json!({"approved": true, "server": server, "tool": tool})
    }

    fn list_alerts(&self, user: Option<Uuid>, payload: &Value) -> Value {
        let Some(gateway_id) = self.read_gateway(user, payload) else {
            return self.read_error(user, payload);
        };
        let alerts: Vec<_> = self
            .alerts
            .iter()
            .filter(|(_, alert)| alert.gateway == gateway_id)
            .map(|(id, alert)| alert_json(id, alert))
            .collect();
        json!({"alerts": alerts})
    }

    fn ack_alert(&mut self, user: Option<Uuid>, payload: &Value) -> Value {
        let Some((gateway_id, _)) = self.write_gateway(user, payload) else {
            return self.read_error(user, payload);
        };
        let Some(alert_id) = uuid_field(payload, "alert_id") else {
            return json!({"error": "invalid_request"});
        };
        match self.alerts.get_mut(&alert_id) {
            Some(alert) if alert.gateway == gateway_id => alert.acknowledged = true,
            _ => return json!({"error": "not_found"}),
        }
        json!({"acknowledged": true, "id": alert_id})
    }

    fn list_approvals(&self, user: Option<Uuid>, payload: &Value) -> Value {
        let Some(gateway_id) = self.read_gateway(user, payload) else {
            return self.read_error(user, payload);
        };
        let approvals: Vec<_> = self
            .approvals
            .iter()
            .filter(|(_, approval)| approval.gateway == gateway_id)
            .map(|(id, approval)| approval_json(id, approval))
            .collect();
        json!({"approvals": approvals})
    }

    fn decide_approval(&mut self, user: Option<Uuid>, payload: &Value) -> Value {
        let Some((gateway_id, _)) = self.write_gateway(user, payload) else {
            return self.read_error(user, payload);
        };
        let status = payload["status"].as_str().unwrap_or("");
        if !matches!(status, "approved" | "denied") {
            return json!({"error": "invalid_request"});
        }
        let Some(approval_id) = uuid_field(payload, "approval_id") else {
            return json!({"error": "invalid_request"});
        };
        let now = unix_now();
        match self.approvals.get_mut(&approval_id) {
            Some(approval)
                if approval.gateway == gateway_id
                    && approval.status == "pending"
                    && approval.expires_at > now =>
            {
                approval.status = status.to_string();
            }
            _ => return json!({"error": "not_found"}),
        }
        json!({"decided": true, "id": approval_id, "status": status})
    }

    fn read_gateway(&self, user: Option<Uuid>, payload: &Value) -> Option<Uuid> {
        let user = user?;
        let id = uuid_field(payload, "gateway_id")?;
        let gateway = self.gateways.get(&id)?;
        self.role(user, gateway.workspace)?;
        Some(id)
    }

    fn write_gateway(&mut self, user: Option<Uuid>, payload: &Value) -> Option<(Uuid, String)> {
        let user = user?;
        let id = uuid_field(payload, "gateway_id")?;
        let workspace = self.gateways.get(&id)?.workspace;
        let role = self.role(user, workspace)?.to_string();
        if !matches!(role.as_str(), "owner" | "admin") {
            return None;
        }
        self.apply_caps(workspace);
        if !self.gateways.contains_key(&id) {
            return None;
        }
        Some((id, role))
    }

    fn read_error(&self, user: Option<Uuid>, payload: &Value) -> Value {
        let Some(user) = user else {
            return json!({"error": "not_found"});
        };
        let Some(id) = uuid_field(payload, "gateway_id") else {
            return json!({"error": "invalid_request"});
        };
        let Some(gateway) = self.gateways.get(&id) else {
            return json!({"error": "not_found"});
        };
        match self.role(user, gateway.workspace) {
            Some(role) if !matches!(role, "owner" | "admin") => json!({"error": "forbidden"}),
            _ => json!({"error": "not_found"}),
        }
    }

    fn apply_caps(&mut self, workspace: Uuid) {
        let Some(limits) = self.workspaces.get(&workspace).map(|ws| plan(&ws.plan)) else {
            return;
        };
        let mut gateways: Vec<(u64, Uuid)> = self
            .gateways
            .iter()
            .filter(|(_, gateway)| gateway.workspace == workspace)
            .map(|(id, gateway)| (gateway.order, *id))
            .collect();
        gateways.sort_by_key(|(order, _)| *order);
        for (index, (_, id)) in gateways.iter().enumerate() {
            let active = limits
                .gateway_limit
                .is_none_or(|limit| (index as i64) < limit);
            let status = if active { "active" } else { "disabled" };
            let gateway = self.gateways.get_mut(id).expect("gateway");
            if gateway.status != status {
                gateway.status = status.to_string();
                gateway.revision += 1;
            }
        }
        let gateway_ids: Vec<Uuid> = gateways.into_iter().map(|(_, id)| id).collect();
        for gateway_id in gateway_ids {
            let mut servers: Vec<(u64, Uuid)> = self
                .servers
                .iter()
                .filter(|(_, server)| server.gateway == gateway_id)
                .map(|(id, server)| (server.order, *id))
                .collect();
            servers.sort_by_key(|(order, _)| *order);
            let mut changed = false;
            for (index, (_, id)) in servers.iter().enumerate() {
                let enabled = limits
                    .server_limit
                    .is_none_or(|limit| (index as i64) < limit);
                let server = self.servers.get_mut(id).expect("server");
                if server.enabled != enabled {
                    server.enabled = enabled;
                    changed = true;
                }
            }
            if changed {
                self.bump(gateway_id);
            }
        }
    }

    fn bump(&mut self, gateway: Uuid) {
        if let Some(row) = self.gateways.get_mut(&gateway) {
            row.revision += 1;
        }
    }
}

fn plan_json(id: &str) -> Value {
    let plan = plan(id);
    json!({
        "id": plan.id,
        "name": plan.name,
        "gateway_limit": plan.gateway_limit,
        "mcp_server_limit": plan.server_limit,
        "stdio": plan.stdio,
        "dedicated": plan.dedicated,
        "seat_limit": plan.seat_limit,
        "tool_calls_per_month": plan.tool_calls_per_month,
        "phone_calls_per_month": plan.phone_calls_per_month,
        "audit_retention_days": plan.audit_retention_days,
    })
}

fn gateway_json(id: &Uuid, gateway: &GatewayRow, role: &str) -> Value {
    json!({
        "id": id,
        "workspace_id": gateway.workspace,
        "name": gateway.name,
        "mode": gateway.mode,
        "region": gateway.region,
        "public_url": gateway.public_url,
        "listen_port": gateway.listen_port,
        "status": gateway.status,
        "unreviewed_tools": gateway.unreviewed_tools,
        "config_revision": gateway.revision,
        "role": role,
    })
}

fn server_json(id: &Uuid, server: &ServerRow) -> Value {
    json!({
        "id": id,
        "gateway_id": server.gateway,
        "name": server.name,
        "transport": server.transport,
        "url": server.url,
        "args": server.args,
        "auth_kind": server.auth_kind,
        "has_secret": server.ciphertext.is_some(),
        "enabled": server.enabled,
    })
}

fn policy_json(id: &Uuid, policy: &PolicyRow) -> Value {
    json!({
        "id": id,
        "gateway_id": policy.gateway,
        "server_id": policy.server,
        "tool_name": policy.tool,
        "effect": policy.effect,
        "notify_channel": policy.notify_channel,
    })
}

fn pin_json(id: &Uuid, pin: &PinRow) -> Value {
    json!({
        "id": id,
        "server_name": pin.server_name,
        "tool_name": pin.tool,
        "pin_sha256": pin.pin_sha256,
        "observed_sha256": pin.observed_sha256,
        "status": pin.status,
    })
}

fn alert_json(id: &Uuid, alert: &AlertRow) -> Value {
    json!({
        "id": id,
        "server_name": alert.server_name,
        "tool_name": alert.tool,
        "observed_sha256": alert.observed_sha256,
        "description_preview": alert.description_preview,
        "acknowledged_at": if alert.acknowledged { json!("acked") } else { Value::Null },
    })
}

fn approval_json(id: &Uuid, approval: &ApprovalRow) -> Value {
    json!({
        "id": id,
        "server_name": approval.server_name,
        "tool_name": approval.tool,
        "args_preview": approval.args_preview,
        "status": approval.status,
        "notify_channel": approval.notify_channel,
        "expires_at": approval.expires_at,
    })
}

fn uuid_field(payload: &Value, key: &str) -> Option<Uuid> {
    payload
        .get(key)
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
}

fn unix_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0)
}
