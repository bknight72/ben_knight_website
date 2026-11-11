\set ON_ERROR_STOP on
begin;
create function pg_temp.assert(ok boolean,message text) returns void language plpgsql as $$ begin if not coalesce(ok,false) then raise exception 'assertion: %',message; end if; end $$;
create function pg_temp.mutate(op text,payload jsonb default '{}',month date default '2026-10-01') returns jsonb language sql as $$
 select public.budgeteer_mutate(month,coalesce((public.budgeteer_read(month)->'plan'->>'revision')::bigint,0),op,
  payload||jsonb_build_object('schema_version',4,'expected_groups_revision',public.budgeteer_read(month)->'groups_revision'))
$$;
create function pg_temp.expect_error(op text,payload jsonb,expected text,month date default '2026-10-01',revision bigint default null,marker boolean default true) returns void language plpgsql as $$
begin
 begin perform public.budgeteer_mutate(month,coalesce(revision,(public.budgeteer_read(month)->'plan'->>'revision')::bigint,0),op,
  case when marker then payload||jsonb_build_object('schema_version',4,'expected_groups_revision',public.budgeteer_read(month)->'groups_revision') else payload end);
 exception when others then if sqlerrm=expected or sqlstate=expected then return; end if; raise; end;
 raise exception 'expected % for %',expected,op;
end $$;
select pg_temp.assert(not exists(
 (select kind,value from public.budgeteer_global_upgrade_expected except
  (select 'entries',to_jsonb(e) from public.budgeteer_entries e
   union all select 'archives',to_jsonb(a) from public.budgeteer_legacy_entry_labels a
   union all select 'exclusions',to_jsonb(x) from public.budgeteer_source_exclusions x
   union all select 'groups',to_jsonb(g)-'sort_position' from public.budgeteer_groups g
   union all select 'positions',to_jsonb(p) from public.budgeteer_group_positions p))),
 'upgrade preserves every UUID, assignment, entry field, archive, exclusion and monthly position');
select pg_temp.assert((select count(*)=5 from public.budgeteer_groups),'all duplicate definitions retained');
select pg_temp.assert(not has_table_privilege('authenticated','public.budgeteer_group_state','update') and not has_table_privilege('authenticated','public.budgeteer_group_positions','insert'),'new tables read only');
select pg_temp.assert(not has_function_privilege('authenticated','private.budgeteer_effective_groups(uuid,uuid)','execute'),'effective helper private');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000000001","aal":"aal1"}',true);
select pg_temp.expect_error('initialize','{}','42501');
select set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000000002","aal":"aal2"}',true);
select pg_temp.expect_error('initialize','{}','42501');
select set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000000001","aal":"aal2"}',true);
select public.budgeteer_read('2030-01-01') as absent \gset
select pg_temp.assert(:'absent'::jsonb->>'schema_version'='4' and :'absent'::jsonb->>'owner_id'='00000000-0000-4000-8000-000000000001'
 and :'absent'::jsonb->>'groups_revision'='0' and :'absent'::jsonb->'plan'='null'::jsonb and jsonb_array_length(:'absent'::jsonb->'groups')=5
 and jsonb_array_length(:'absent'::jsonb->'entries')=0 and not(:'absent'::jsonb ? 'group_copy_preview'),'absent plan exposes global v4 state only');
select pg_temp.assert((select array_agg(value->>'id' order by value->>'id') from jsonb_array_elements(public.budgeteer_read('2026-10-01')->'groups'))=
 (select array_agg(value->>'id' order by value->>'id') from jsonb_array_elements(public.budgeteer_read('2030-01-01')->'groups')),'all months share exact group IDs');
select pg_temp.assert((select (value->>'sort_position')::bigint=9 from jsonb_array_elements(public.budgeteer_read('2026-10-01')->'groups') where value->>'id'='40000000-0000-4000-8000-000000000002'),'original monthly priority retained');
select pg_temp.expect_error('initialize','{}','budgeteer_schema_upgrade_required','2030-01-01',0,false);
select pg_temp.expect_error('initialize','{"schema_version":3,"expected_groups_revision":0}','budgeteer_schema_upgrade_required','2030-01-01',0,false);
select pg_temp.expect_error('initialize','{"schema_version":4}','budgeteer_invalid_payload','2030-01-01',0,false);
select pg_temp.expect_error('initialize','{"schema_version":4,"expected_groups_revision":"0"}','budgeteer_invalid_payload','2030-01-01',0,false);
select pg_temp.expect_error('groups_copy','{"confirmed":true}','budgeteer_invalid_operation','2030-01-01');
select pg_temp.assert(public.budgeteer_read('2030-01-01')=:'absent'::jsonb,'old and copy clients cannot create a plan');
select pg_temp.mutate('group_save','{"id":"40000000-0000-4000-8000-000000000003","kind":"withdrawal","name":"Global rename","color_key":"hex_ff00aa","parent_group_id":"40000000-0000-4000-8000-000000000001"}');
select pg_temp.assert((select value->>'name'='Global rename' and value->>'color_key'='hex_ff00aa' and value->>'parent_group_id'='40000000-0000-4000-8000-000000000001'
 from jsonb_array_elements(public.budgeteer_read('2030-01-01')->'groups') where value->>'id'='40000000-0000-4000-8000-000000000003'),'rename/color/reparent visible without plan');
select pg_temp.assert(not exists(select 1 from public.budgeteer_plans plans
 cross join lateral jsonb_array_elements(public.budgeteer_read(plans.month)->'groups') moved
 cross join lateral jsonb_array_elements(public.budgeteer_read(plans.month)->'groups') sibling
 where moved->>'id'='40000000-0000-4000-8000-000000000003' and sibling->>'id'='40000000-0000-4000-8000-000000000002'
 and (moved->>'sort_position')::bigint<=(sibling->>'sort_position')::bigint),'reparent appends after existing destination siblings in every month');
select pg_temp.expect_error('initialize','{"schema_version":4,"expected_groups_revision":0}','budgeteer_conflict','2030-01-01',0,false);
select pg_temp.expect_error('initialize','{}','budgeteer_conflict','2026-10-01',4);
select pg_temp.expect_error('group_save','{"id":"40000000-0000-4000-8000-000000000001","kind":"withdrawal","name":"Cycle","color_key":"blue","parent_group_id":"40000000-0000-4000-8000-000000000004"}','budgeteer_group_cycle');
select pg_temp.expect_error('group_save','{"kind":"deposit","name":"Bad","color_key":"blue","parent_group_id":"40000000-0000-4000-8000-000000000005"}','budgeteer_invalid_parent');
select pg_temp.expect_error('group_save','{"id":"40000000-0000-4000-8000-000000000005","kind":"withdrawal","name":"Bad","color_key":"blue","parent_group_id":null}','budgeteer_group_kind_immutable');
select pg_temp.mutate('group_save','{"kind":"deposit","name":"Same name","color_key":"teal","parent_group_id":null}','2030-01-01');
select pg_temp.assert((select count(*)=6 from public.budgeteer_groups),'create in absent month creates one global definition, no copies');
select public.budgeteer_read('2026-11-01') as november \gset
select public.budgeteer_read('2026-10-01')->'groups_revision' as before_order_revision \gset
select pg_temp.mutate('reorder',jsonb_build_object('groups',(select jsonb_agg(value->>'id' order by value->>'id' desc) from jsonb_array_elements(public.budgeteer_read('2026-10-01')->'groups')),
 'entries',jsonb_build_array(jsonb_build_object('id','50000000-0000-4000-8000-000000000001','group_id','40000000-0000-4000-8000-000000000004'))));
select pg_temp.assert(public.budgeteer_read('2026-11-01')=:'november'::jsonb,'reorder changes no other month or global definitions');
select pg_temp.assert(public.budgeteer_read('2026-10-01')->'groups_revision'=:'before_order_revision'::jsonb,'monthly reorder leaves global revision');
select public.budgeteer_read('2026-10-01') as before_bad \gset
select pg_temp.expect_error('reorder','{"groups":[],"entries":[]}','budgeteer_invalid_order');
select pg_temp.expect_error('entry_save','{"kind":"withdrawal","name":"Bad","amount_minor":1,"group_id":"40000000-0000-4000-8000-000000000005"}','budgeteer_invalid_group');
select pg_temp.expect_error('entry_save','{"id":"50000000-0000-4000-8000-000000000001","kind":"deposit","name":"Bad","amount_minor":1}','budgeteer_legacy_withdrawal_required');
select pg_temp.assert(public.budgeteer_read('2026-10-01')=:'before_bad'::jsonb,'invalid mutations atomic');
-- The same global deposit group can be assigned in arbitrary months.
select pg_temp.mutate('entry_save','{"kind":"deposit","name":"October income","amount_minor":2000,"group_id":"40000000-0000-4000-8000-000000000005"}');
select pg_temp.mutate('entry_save','{"kind":"withdrawal","name":"Direct October","amount_minor":77,"group_id":"40000000-0000-4000-8000-000000000003"}');
select public.budgeteer_read('2026-11-01')->'plan'->'revision' as nov_revision \gset
select public.budgeteer_read('2026-10-01')->'plan'->'revision' as oct_revision \gset
select pg_temp.mutate('group_delete','{"id":"40000000-0000-4000-8000-000000000003"}');
select pg_temp.assert((public.budgeteer_read('2026-11-01')->'plan'->>'revision')::bigint=(:'nov_revision')::bigint+1
 and (public.budgeteer_read('2026-10-01')->'plan'->>'revision')::bigint=(:'oct_revision')::bigint+1,'delete increments affected months once');
select pg_temp.assert((select group_id is null and amount_minor=456 from public.budgeteer_entries where id='50000000-0000-4000-8000-000000000002'),'delete ungroups direct November assignment');
select pg_temp.assert((select group_id='40000000-0000-4000-8000-000000000004' and source_snapshot is not null and amount_minor=123 from public.budgeteer_entries where id='50000000-0000-4000-8000-000000000001'),'descendant assignment and source snapshot survive');
select pg_temp.assert((select parent_group_id='40000000-0000-4000-8000-000000000001' from public.budgeteer_groups where id='40000000-0000-4000-8000-000000000004'),'immediate children promoted to deleted parent');
select pg_temp.assert((select (child->>'sort_position')::bigint<(sibling->>'sort_position')::bigint
 from jsonb_array_elements(public.budgeteer_read('2026-10-01')->'groups') child,
 jsonb_array_elements(public.budgeteer_read('2026-10-01')->'groups') sibling
 where child->>'id'='40000000-0000-4000-8000-000000000004' and sibling->>'id'='40000000-0000-4000-8000-000000000002')
 and (select (child->>'sort_position')::bigint>(sibling->>'sort_position')::bigint
 from jsonb_array_elements(public.budgeteer_read('2026-11-01')->'groups') child,
 jsonb_array_elements(public.budgeteer_read('2026-11-01')->'groups') sibling
 where child->>'id'='40000000-0000-4000-8000-000000000004' and sibling->>'id'='40000000-0000-4000-8000-000000000002'),
 'child promotion inherits opposite per-month positions, not one global sibling order');
select pg_temp.assert((select count(*)=1 from public.budgeteer_source_exclusions) and jsonb_array_length(public.budgeteer_read('2026-10-01')->'legacy_entry_labels')=2,'delete retains exclusions and archive');
select pg_temp.mutate('group_delete','{"id":"40000000-0000-4000-8000-000000000005"}');
select pg_temp.assert((select count(*)=2 and bool_and(group_id is null) from public.budgeteer_entries where kind='deposit'),'deposit deletion ungroups all months');
select pg_temp.mutate('legacy_label_convert','{"confirmed":true,"label_id":"60000000-0000-4000-8000-000000000001","entry_ids":["50000000-0000-4000-8000-000000000001"],"name":"Converted","color_key":"hex_abcdef","parent_group_id":null}');
select pg_temp.assert(jsonb_array_length(public.budgeteer_read('2026-10-01')->'legacy_entry_labels')=2,'global conversion keeps archived labels');
-- Refresh, exclusion and restore retain their deployed semantics.
reset role;
update public.transactions set amount_minor=-999,description='Changed bank source' where id='20000000-0000-4000-8000-000000000001';
set local role authenticated;
select pg_temp.mutate('source_refresh','{"id":"50000000-0000-4000-8000-000000000001"}');
select pg_temp.assert((select amount_minor=999 and group_id is not null from public.budgeteer_entries where id='50000000-0000-4000-8000-000000000001'),'refresh keeps manual global assignment');
select pg_temp.mutate('entry_delete','{"id":"50000000-0000-4000-8000-000000000001"}');
select pg_temp.mutate('sources_include');
select pg_temp.assert(not exists(select 1 from public.budgeteer_entries where source_transaction_id='20000000-0000-4000-8000-000000000001'),'deleted source stays excluded');
select pg_temp.mutate('sources_restore');
select pg_temp.assert((select group_id is null and amount_minor=999 from public.budgeteer_entries where source_transaction_id='20000000-0000-4000-8000-000000000001'),'restore ungrouped');
select pg_temp.expect_error('entry_save','{"kind":"deposit","name":"Overflow","amount_minor":9000000000000}','budgeteer_total_overflow');
select public.budgeteer_read('2026-10-01')->'plan'->'revision' as before_source_delete \gset
select public.budgeteer_read('2026-11-01')->'plan'->'revision' as before_exclusion_delete \gset
reset role;
delete from public.transactions where id='20000000-0000-4000-8000-000000000001';
set local role authenticated;
select pg_temp.assert((public.budgeteer_read('2026-10-01')->'plan'->>'revision')::bigint=(:'before_source_delete')::bigint+1
 and (public.budgeteer_read('2026-11-01')->'plan'->>'revision')::bigint=(:'before_exclusion_delete')::bigint+1,'source deletion revisions include exclusion-only month');
select pg_temp.assert((select value->>'source_state'='unavailable' and value->'source_snapshot' is not null from jsonb_array_elements(public.budgeteer_read('2026-10-01')->'entries') where value->>'name'='Changed bank source'),'source deletion retains unavailable snapshot');
reset role;
do $$ begin
 begin update public.budgeteer_groups set kind='deposit' where id='40000000-0000-4000-8000-000000000001'; raise exception 'missing immutable check';
 exception when raise_exception then if sqlerrm<>'budgeteer_group_kind_immutable' then raise; end if; end;
end $$;
rollback;
drop table public.budgeteer_global_upgrade_expected;
delete from public.budgeteer_plans;
delete from public.budgeteer_groups where parent_group_id is not null;
delete from public.budgeteer_groups;
delete from public.budgeteer_group_state;
delete from public.budgeteer_labels;
delete from public.budgeteer_legacy_entry_labels;
delete from public.accounts;
delete from public.categories;
delete from public.profiles;
delete from private.app_owner;
delete from auth.users;
