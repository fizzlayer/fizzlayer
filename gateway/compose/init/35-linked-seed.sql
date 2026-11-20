-- Linked compose only. The mock control plane adds `extra` to the agent's
-- config during the probe. The real control plane writes this row when a
-- server is added; the guard needs it to attribute `extra_echo` once tool
-- names are prefixed. Standalone compose renders its config from this
-- database, so the row is not in 30-seed.sql.
insert into gateway.servers (id, gateway_id, name, transport, url_or_cmd, auth_kind, trust_new_tools)
values (
  '55555555-5555-4555-8555-555555555558',
  '22222222-2222-4222-8222-222222222222',
  'extra',
  'http',
  'http://sample-extra:8081/mcp',
  'none',
  false
);
