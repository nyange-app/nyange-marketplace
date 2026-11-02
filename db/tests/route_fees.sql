-- Tests for compute_route_fees / route_batch_ok.
-- Run against a THROWAWAY database that has db/schema.sql loaded:
--   psql -v ON_ERROR_STOP=1 -d <scratch_db> -f db/tests/route_fees.sql
-- Everything runs in one transaction that is rolled back, so config changes do not persist.
-- Any failed assertion aborts with an error.
\set ON_ERROR_STOP on
begin;

-- Fixture: shipment A (8 km standalone), shipment B (9 km standalone), combined route 12 km.
create temp table fx as select
    '00000000-0000-0000-0000-00000000000a'::uuid as a,
    '00000000-0000-0000-0000-00000000000b'::uuid as b;

create function pg_temp.fee(p_who text, p_route_m int, p_route_s int, p_m int[], p_s int[], p_area uuid default null)
returns table (fee bigint, factor numeric, solo bigint, capped boolean) language sql as $$
    select f.fee_ugx, f.factor, f.standalone_fee_ugx, f.capped
    from fx, compute_route_fees(p_route_m, p_route_s, array[fx.a, fx.b], p_m, p_s, p_area) f
    where f.shipment_id = case p_who when 'a' then fx.a else fx.b end
$$;

-- T1 distance-weighted (default), distance term only: 12 km * 1500 = 18000 split 8:9, rounded up to 500
do $$
declare a record; b record;
begin
    select * into a from pg_temp.fee('a', 12000, 1800, array[8000,9000], array[1320,1500]);
    select * into b from pg_temp.fee('b', 12000, 1800, array[8000,9000], array[1320,1500]);
    assert a.fee = 8500,  format('T1 A fee %s', a.fee);
    assert b.fee = 10000, format('T1 B fee %s', b.fee);
    assert round(a.factor, 6) = 0.470588, format('T1 A factor %s', a.factor);
    assert abs(a.factor + b.factor - 1) < 1e-9, 'T1 factors must sum to 1';
    assert a.solo = 12000 and b.solo = 13500, 'T1 standalone fees';
    assert not a.capped and not b.capped, 'T1 not capped';
end $$;

-- T2 equal shares: 18000 / 2 = 9000 each
update config set value = '"equal"' where key = 'route.factor_mode';
do $$
declare a record; b record;
begin
    select * into a from pg_temp.fee('a', 12000, 1800, array[8000,9000], array[1320,1500]);
    select * into b from pg_temp.fee('b', 12000, 1800, array[8000,9000], array[1320,1500]);
    assert a.fee = 9000 and b.fee = 9000, format('T2 equal %s/%s', a.fee, b.fee);
end $$;
update config set value = '"distance"' where key = 'route.factor_mode';

-- T3 duration term: 100 UGX/min. route cost = 12*1500 + 30*100 = 21000 -> A 10000, B 11500;
--    standalone A = 8*1500 + 22*100 = 14200 -> 14500; B = 13500 + 2500 = 16000
update config set value = '100' where key = 'route.rate_per_min_ugx';
do $$
declare a record; b record;
begin
    select * into a from pg_temp.fee('a', 12000, 1800, array[8000,9000], array[1320,1500]);
    select * into b from pg_temp.fee('b', 12000, 1800, array[8000,9000], array[1320,1500]);
    assert a.fee = 10000 and b.fee = 11500, format('T3 time %s/%s', a.fee, b.fee);
    assert a.solo = 14500 and b.solo = 16000, format('T3 standalone %s/%s', a.solo, b.solo);
end $$;

-- T3b dwell: 300 s per stop, 3 stops on the route (2 pickups + drop) adds 15 min * 100 = 1500
--     route cost 22500 -> A 11000, B 12000
update config set value = '300' where key = 'route.dwell_s_per_stop';
do $$
declare a record; b record;
begin
    select * into a from pg_temp.fee('a', 12000, 1800, array[8000,9000], array[1320,1500]);
    select * into b from pg_temp.fee('b', 12000, 1800, array[8000,9000], array[1320,1500]);
    assert a.fee = 11000 and b.fee = 12000, format('T3b dwell %s/%s', a.fee, b.fee);
end $$;
update config set value = '0' where key in ('route.dwell_s_per_stop', 'route.rate_per_min_ugx');

-- T4 batching worse than going alone (20 km vs 8 + 9): fees are capped at standalone, batching refused
do $$
declare a record; b record;
begin
    select * into a from pg_temp.fee('a', 20000, 2400, array[8000,9000], array[1320,1500]);
    select * into b from pg_temp.fee('b', 20000, 2400, array[8000,9000], array[1320,1500]);
    assert a.fee = 12000 and b.fee = 13500, format('T4 capped %s/%s', a.fee, b.fee);
    assert a.capped and b.capped, 'T4 capped flags';
    assert not route_batch_ok(20000, array[8000,9000]), 'T4 batch should be refused';
    assert route_batch_ok(12000, array[8000,9000]), 'T4 12 km batch should be allowed';
end $$;
update config set value = 'null' where key = 'route.max_detour_ratio';
do $$ begin assert route_batch_ok(20000, array[8000,9000]), 'T4 waived ratio always allows'; end $$;
update config set value = '1.0' where key = 'route.max_detour_ratio';

-- T5 minimum fee: a 500 m hop still pays the floor
update config set value = '3000' where key = 'route.min_fee_ugx';
do $$
declare a record; b record;
begin
    select * into a from pg_temp.fee('a', 9500, 1200, array[500,9000], array[120,1500]);
    select * into b from pg_temp.fee('b', 9500, 1200, array[500,9000], array[120,1500]);
    assert a.fee = 3000, format('T5 floor %s', a.fee);
    assert b.fee = 13500 and not b.capped, format('T5 B %s', b.fee);
end $$;
update config set value = '0' where key = 'route.min_fee_ugx';

-- T6 degenerate input (all-zero standalone distances) falls back to equal shares.
--    With the cap off the route cost is split evenly; with the cap on, a zero-length standalone
--    trip caps the fee at the (zero) standalone fee, which is the documented behaviour.
update config set value = 'false' where key = 'route.cap_at_standalone';
do $$
declare a record;
begin
    select * into a from pg_temp.fee('a', 4000, 600, array[0,0], array[0,0]);
    assert a.factor = 0.5, format('T6 factor %s', a.factor);
    assert a.fee = 3000, format('T6 fee %s', a.fee);   -- 4 km * 1500 = 6000 / 2
end $$;
update config set value = 'true' where key = 'route.cap_at_standalone';
do $$
declare a record;
begin
    select * into a from pg_temp.fee('a', 4000, 600, array[0,0], array[0,0]);
    assert a.fee = 0 and a.capped, format('T6 capped %s', a.fee);
end $$;

-- T7 invalid input
do $$
begin
    begin
        perform * from compute_route_fees(1000, 100, array['00000000-0000-0000-0000-00000000000a'::uuid], array[1,2], array[1]);
        assert false, 'T7 mismatched arrays should raise';
    exception when raise_exception then
        assert sqlerrm like '%equal length%', format('T7 unexpected error: %s', sqlerrm);
    end;
    update config set value = '"bogus"' where key = 'route.factor_mode';
    begin
        perform * from compute_route_fees(1000, 100, array['00000000-0000-0000-0000-00000000000a'::uuid], array[1], array[1]);
        assert false, 'T7 unknown mode should raise';
    exception when raise_exception then
        assert sqlerrm like '%unknown route.factor_mode%', format('T7 unexpected error: %s', sqlerrm);
    end;
    update config set value = '"distance"' where key = 'route.factor_mode';
end $$;

-- T8 area-scoped rate overrides global (Nyange-set, per area); global stays untouched
insert into config(key, scope, scope_id, value)
    values ('route.rate_per_km_ugx', 'area', '99999999-0000-0000-0000-000000000001', '2000');
do $$
declare a_area record; a_global record;
begin
    select * into a_area from pg_temp.fee('a', 12000, 1800, array[8000,9000], array[1320,1500],
                                          '99999999-0000-0000-0000-000000000001');
    select * into a_global from pg_temp.fee('a', 12000, 1800, array[8000,9000], array[1320,1500]);
    assert a_area.fee = 11500, format('T8 area fee %s', a_area.fee);     -- 24000 * 8/17 = 11294 -> 11500
    assert a_global.fee = 8500, format('T8 global fee %s', a_global.fee);
end $$;

\echo route fee tests: all assertions passed
rollback;
