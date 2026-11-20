-- A server added from now on trusts its tools when they are first seen.
--
-- fizz-guard pins every tool it lists. Before this column, a tool seen for the
-- first time was pinned as unreviewed: hidden (unless the gateway shows
-- unreviewed tools) and refused until someone approved the pin. With
-- trust_new_tools, the first sighting is pinned as approved instead. A
-- description that changes after that is still held and alerted.
--
-- Rows that exist when this runs keep the strict behaviour. Only servers added
-- afterwards get the new default.

alter table gateway.servers
  add column trust_new_tools boolean not null default false;

alter table gateway.servers
  alter column trust_new_tools set default true;

comment on column gateway.servers.trust_new_tools is
  'When true, fizz-guard pins a tool as approved the first time it is listed. Changed descriptions are still held.';
