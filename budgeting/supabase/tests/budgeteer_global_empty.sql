\set ON_ERROR_STOP on
begin;
create function pg_temp.assert(ok boolean,message text) returns void language plpgsql as $$ begin if not coalesce(ok,false) then raise exception 'assertion: %',message; end if; end $$;
insert into auth.users(id) values('00000000-0000-4000-8000-000000000001');
insert into private.app_owner(owner_id) values('00000000-0000-4000-8000-000000000001');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000000001","aal":"aal2"}',true);
select pg_temp.assert(public.budgeteer_read('2026-10-01')->'plan'='null'::jsonb
 and public.budgeteer_read('2026-10-01')->>'groups_revision'='0'
 and public.budgeteer_read('2026-10-01')->'groups'='[]'::jsonb,'new owner reads empty global catalog without state row');
select public.budgeteer_mutate('2026-10-01',0,'group_save','{"schema_version":4,"expected_groups_revision":0,"kind":"withdrawal","name":"First global group","color_key":"hex_a1b2c3","parent_group_id":null}');
select pg_temp.assert(public.budgeteer_read('2026-11-01')->>'groups_revision'='1'
 and jsonb_array_length(public.budgeteer_read('2026-11-01')->'groups')=1
 and public.budgeteer_read('2026-11-01')->'plan'='null'::jsonb,'first mutation bootstraps owner state and shared catalog');
select public.budgeteer_mutate('2026-11-01',0,'sources_include','{"schema_version":4,"expected_groups_revision":1}');
select pg_temp.assert(public.budgeteer_read('2026-11-01')->'plan'->>'revision'='1'
 and (select count(*)=1 from public.budgeteer_groups),'empty source initialization creates plan, never copies groups');
select pg_temp.assert(not exists(select 1 from public.budgeteer_group_positions),'default ordering needs no monthly copies');
rollback;
