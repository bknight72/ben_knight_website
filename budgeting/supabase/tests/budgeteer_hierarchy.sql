\set ON_ERROR_STOP on
begin;
create function pg_temp.assert(ok boolean,message text) returns void language plpgsql as $$ begin if not coalesce(ok,false) then raise exception 'assertion: %',message; end if; end $$;
create function pg_temp.mutate(op text,payload jsonb default '{}',month date default '2026-10-01') returns jsonb language sql as $$
 select public.budgeteer_mutate(month,coalesce((public.budgeteer_read(month)->'plan'->>'revision')::bigint,0),op,payload)
$$;
create function pg_temp.expect_error(op text,payload jsonb,expected text,month date default '2026-10-01',revision bigint default null) returns void language plpgsql as $$
begin
 begin perform public.budgeteer_mutate(month,coalesce(revision,(public.budgeteer_read(month)->'plan'->>'revision')::bigint,0),op,payload);
 exception when others then if sqlerrm=expected or sqlstate=expected then return; end if; raise; end;
 raise exception 'expected % for %',expected,op;
end $$;
select pg_temp.assert(not has_function_privilege('authenticated','private.budgeteer_copy_groups(uuid,uuid,uuid)','execute'),'copy helper private');
select pg_temp.assert(not has_function_privilege('authenticated','private.budgeteer_mutate_flat(date,bigint,text,jsonb)','execute'),'flat implementation private');
select pg_temp.assert(not has_table_privilege('authenticated','public.budgeteer_labels','update'),'archived labels readonly');
select pg_temp.assert(not has_table_privilege('authenticated','public.budgeteer_legacy_entry_labels','update'),'archived links readonly');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000000001","aal":"aal1"}',true);
select pg_temp.expect_error('initialize','{}','42501');
select set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000000002","aal":"aal2"}',true);
select pg_temp.expect_error('initialize','{}','42501');
select set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000000001","aal":"aal2"}',true);
select pg_temp.assert(public.budgeteer_read('2026-10-01')->>'schema_version'='2','new contract version');
select pg_temp.assert(not(public.budgeteer_read('2026-10-01') ? 'labels'),'legacy data distinct');
select pg_temp.assert(jsonb_array_length(public.budgeteer_read('2026-10-01')->'legacy_entry_labels')=2,'multilabel history preserved');
select pg_temp.assert((select array_agg(sort_position order by sort_position)=array[7,9]::bigint[] and bool_and(parent_group_id is null) from public.budgeteer_groups),'flat positions unchanged');
select pg_temp.assert((select amount_minor=123 and sort_position=8 and group_id='40000000-0000-4000-8000-000000000001' from public.budgeteer_entries),'entry unchanged');
select pg_temp.assert((select source_transaction_id='20000000-0000-4000-8000-000000000001' and source_snapshot->>'source_id'='upgrade-source' from public.budgeteer_entries),'source link and snapshot unchanged');
select public.budgeteer_read('2026-11-01') as before_read \gset
select pg_temp.assert(:'before_read'::jsonb->'plan'='null'::jsonb,'read side effect free');
select pg_temp.assert((select count(*)=1 from public.budgeteer_plans),'preview creates no month');
select pg_temp.assert(:'before_read'::jsonb->'group_copy_preview'->>'source_revision'='4','copy preview revision');
select pg_temp.expect_error('label_save','{}','budgeteer_schema_upgrade_required');
select pg_temp.expect_error('label_delete','{}','budgeteer_schema_upgrade_required');
select pg_temp.expect_error('entry_save','{"label_ids":[]}','budgeteer_schema_upgrade_required');
select pg_temp.mutate('entry_save','{"id":"50000000-0000-4000-8000-000000000001","kind":"withdrawal","name":"Edited","amount_minor":456,"group_id":"40000000-0000-4000-8000-000000000001"}');
select pg_temp.assert(jsonb_array_length(public.budgeteer_read('2026-10-01')->'legacy_entry_labels')=2,'entry edit preserves both labels');
select pg_temp.assert((select source_transaction_id='20000000-0000-4000-8000-000000000001' and source_snapshot->>'amount_minor'='-123' from public.budgeteer_entries),'independent edit preserves source snapshot');
select pg_temp.expect_error('entry_save','{"id":"50000000-0000-4000-8000-000000000001","kind":"deposit","name":"No","amount_minor":456}','budgeteer_legacy_withdrawal_required');
select pg_temp.expect_error('group_save','{"id":"40000000-0000-4000-8000-000000000001","name":"Bad","color_key":"blue","parent_group_id":"40000000-0000-4000-8000-000000000001"}','budgeteer_invalid_parent');
select pg_temp.expect_error('group_save','{"name":"Bad","color_key":"blue","parent_group_id":"ffffffff-ffff-4fff-8fff-ffffffffffff"}','budgeteer_invalid_parent');
select pg_temp.mutate('group_save','{"id":"40000000-0000-4000-8000-000000000002","name":"Child","color_key":"teal","parent_group_id":"40000000-0000-4000-8000-000000000001"}');
select pg_temp.expect_error('group_save','{"id":"40000000-0000-4000-8000-000000000001","name":"Cycle","color_key":"blue","parent_group_id":"40000000-0000-4000-8000-000000000002"}','budgeteer_group_cycle');
select pg_temp.mutate('group_save','{"name":"Grandchild","color_key":"rose","parent_group_id":"40000000-0000-4000-8000-000000000002"}');
select id as grandchild from public.budgeteer_groups where name='Grandchild' \gset
select pg_temp.mutate('sources_include','{}','2026-11-01');
select pg_temp.assert((select revision=1 from public.budgeteer_plans where month='2026-11-01'),'empty sources initialize revision');
select pg_temp.assert((select count(*)=3 from public.budgeteer_groups g join public.budgeteer_plans p on p.id=g.plan_id where p.month='2026-11-01'),'empty sources copied tree');
select pg_temp.assert((select count(*)=0 from public.budgeteer_entries e join public.budgeteer_plans p on p.id=e.plan_id where p.month='2026-11-01'),'copy definitions only');
select pg_temp.assert((select count(*)=2 from public.budgeteer_groups g join public.budgeteer_plans p on p.id=g.plan_id where p.month='2026-11-01' and g.parent_group_id is not null),'parents remapped');
select pg_temp.assert(not exists(select 1 from public.budgeteer_groups g join public.budgeteer_plans p on p.id=g.plan_id where p.month='2026-11-01' and g.parent_group_id in ('40000000-0000-4000-8000-000000000001','40000000-0000-4000-8000-000000000002')),'new parent ids');
select pg_temp.expect_error('group_save','{"name":"Foreign month","color_key":"blue","parent_group_id":"40000000-0000-4000-8000-000000000001"}','budgeteer_invalid_parent','2026-11-01');
select pg_temp.expect_error('groups_copy','{}','budgeteer_confirmation_required','2026-11-01');
select pg_temp.expect_error('groups_copy','{"confirmed":true,"source_plan_id":"30000000-0000-4000-8000-000000000001","source_revision":0}','budgeteer_conflict','2026-11-01');
select public.budgeteer_read('2026-11-01')->'group_copy_preview' as preview \gset
select pg_temp.mutate('groups_copy',(:'preview'::jsonb-'groups'-'source_month')||'{"confirmed":true}'::jsonb,'2026-11-01');
select pg_temp.assert((select count(*)=6 from public.budgeteer_groups g join public.budgeteer_plans p on p.id=g.plan_id where p.month='2026-11-01'),'explicit copy additive without name dedup');
select pg_temp.mutate('sources_include','{}','2026-11-01');
select pg_temp.assert((select count(*)=6 from public.budgeteer_groups g join public.budgeteer_plans p on p.id=g.plan_id where p.month='2026-11-01'),'existing month never reseeded');
select pg_temp.expect_error('legacy_label_convert','{"label_id":"60000000-0000-4000-8000-000000000001","entry_ids":[]}','budgeteer_confirmation_required');
select pg_temp.expect_error('legacy_label_convert','{"confirmed":true,"label_id":"60000000-0000-4000-8000-000000000001","entry_ids":["ffffffff-ffff-4fff-8fff-ffffffffffff"],"group_id":"40000000-0000-4000-8000-000000000002"}','budgeteer_invalid_entries');
select pg_temp.mutate('legacy_label_convert','{"confirmed":true,"label_id":"60000000-0000-4000-8000-000000000001","entry_ids":["50000000-0000-4000-8000-000000000001"],"group_id":"40000000-0000-4000-8000-000000000002"}');
select pg_temp.assert((select group_id='40000000-0000-4000-8000-000000000002' from public.budgeteer_entries),'conversion explicitly reassigns');
select pg_temp.assert((select count(*)=2 from public.budgeteer_entry_labels),'conversion preserves archive');
select pg_temp.mutate('reorder',jsonb_build_object('groups',jsonb_build_array(:'grandchild','40000000-0000-4000-8000-000000000002','40000000-0000-4000-8000-000000000001'),'entries',jsonb_build_array(jsonb_build_object('id','50000000-0000-4000-8000-000000000001','group_id','40000000-0000-4000-8000-000000000002'))));
select public.budgeteer_read('2026-10-01') as before_bad \gset
select pg_temp.expect_error('reorder','{"groups":[],"entries":[]}','budgeteer_invalid_order');
select pg_temp.assert(public.budgeteer_read('2026-10-01')=:'before_bad'::jsonb,'bad reorder fully atomic');
select pg_temp.mutate('group_delete','{"id":"40000000-0000-4000-8000-000000000002"}');
select pg_temp.assert((select group_id is null and amount_minor=456 from public.budgeteer_entries),'delete ungroups direct entry only');
select pg_temp.assert((select parent_group_id='40000000-0000-4000-8000-000000000001' from public.budgeteer_groups where id=:'grandchild'),'delete promotes immediate child');
select pg_temp.assert((select count(*)=2 from public.budgeteer_entry_labels),'delete group preserves archive');
select pg_temp.mutate('source_unlink','{"id":"50000000-0000-4000-8000-000000000001"}');
select pg_temp.mutate('sources_include');
select pg_temp.assert((select count(*)=1 from public.budgeteer_entries),'v2 unlink exclusion prevents duplicate');
select pg_temp.assert(public.budgeteer_read('2026-10-01')->>'excluded_source_count'='1','v2 exclusion remains visible');
select pg_temp.mutate('sources_restore');
select pg_temp.assert((select count(*)=2 from public.budgeteer_entries),'v2 restore retains manual and adds source');
select pg_temp.assert((select count(*)=2 from public.budgeteer_entry_labels),'v2 restore preserves archived links');
select pg_temp.mutate('entry_delete','{"id":"50000000-0000-4000-8000-000000000001"}');
select pg_temp.assert(jsonb_array_length(public.budgeteer_read('2026-10-01')->'legacy_entry_labels')=2,'entry deletion preserves archived associations');
select pg_temp.assert(public.budgeteer_read('2026-10-01')->'legacy_entry_labels'->0->'entry_snapshot'->>'amount_minor'='123','archive retains original entry snapshot');
select pg_temp.expect_error('initialize','{}','budgeteer_conflict','2026-10-01',4);
-- An intentionally emptied existing month remains empty under initialization.
select pg_temp.mutate('initialize','{}','2026-09-01');
select pg_temp.assert(jsonb_array_length(public.budgeteer_read('2026-09-01')->'groups')=0,'future definitions never copied');
select pg_temp.mutate('initialize','{}','2026-09-01');
select pg_temp.assert(jsonb_array_length(public.budgeteer_read('2026-09-01')->'groups')=0,'existing empty stays empty');
reset role;
-- Exercise the private existing implementation independently of the public wrapper.
select set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000000001","aal":"aal2"}',true);
select private.budgeteer_mutate_existing('2027-01-01',0,'initialize','{}');
select pg_temp.assert((select count(*)=6 from public.budgeteer_groups g join public.budgeteer_plans p on p.id=g.plan_id where p.month='2027-01-01'),'private creation copies latest earlier month');
-- A failed source batch rolls back first initialization and all copied definitions.
insert into public.transactions(owner_id,account_id,source,source_id,amount_minor,description,transaction_date,status)
 select '00000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','csv','overflow-'||i,9000000000000,'Limit','2027-02-01','posted' from generate_series(1,2) i;
set local role authenticated;
select pg_temp.expect_error('sources_include','{}','budgeteer_total_overflow','2027-02-01');
select pg_temp.assert(public.budgeteer_read('2027-02-01')->'plan'='null'::jsonb,'failed source batch rolls back copied plan');
reset role;
rollback;
delete from public.budgeteer_plans;
delete from public.budgeteer_labels;
delete from public.budgeteer_legacy_entry_labels;
delete from public.accounts;
delete from public.categories;
delete from public.profiles;
delete from private.app_owner;
delete from auth.users;
