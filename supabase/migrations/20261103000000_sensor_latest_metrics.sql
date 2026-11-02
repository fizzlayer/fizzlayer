-- Return the newest value of every metric a sensor reports, not only one reading, so the dashboard can
-- show multi-metric devices (for example a Linux device's CPU temperature, load, memory, and disk use).
-- Only the sensor's 200 most recent readings are considered, which keeps this cheap on the
-- (sensor_id, observed_at desc) index while covering every metric a device sends in a sample.
create or replace function public.fizz_sensor_json(p_sensor public.fizz_sensors)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', p_sensor.id, 'kind', p_sensor.kind, 'name', p_sensor.name,
    'mode', p_sensor.mode, 'status', p_sensor.status,
    'created_at', p_sensor.created_at,
    'latest_reading', (select to_jsonb(r) from public.fizz_sensor_readings r
      where r.sensor_id = p_sensor.id
      order by r.observed_at desc,
        case when r.metric = case p_sensor.kind
          when 'water' then 'flow_l_min' when 'gas' then 'concentration_ppm'
          when 'radio' then 'rssi_dbm' when 'temperature' then 'temperature_c'
          when 'pressure' then 'pressure_kpa' when 'humidity' then 'humidity_pct'
          when 'sound' then 'sound_db' when 'phone' then 'acceleration_ms2'
          else 'value' end then 0 else 1 end,
        r.received_at desc limit 1),
    'latest_metrics', coalesce((
      select jsonb_agg(jsonb_build_object(
          'metric', m.metric, 'numeric_value', m.numeric_value, 'boolean_value', m.boolean_value,
          'text_value', m.text_value, 'unit', m.unit, 'observed_at', m.observed_at
        ) order by m.metric)
      from (
        select distinct on (r.metric) r.metric, r.numeric_value, r.boolean_value, r.text_value, r.unit, r.observed_at
        from (
          select * from public.fizz_sensor_readings r0
          where r0.sensor_id = p_sensor.id
          order by r0.observed_at desc, r0.received_at desc
          limit 200
        ) r
        order by r.metric, r.observed_at desc, r.received_at desc
        limit 24
      ) m
    ), '[]'::jsonb)
  );
$$;
