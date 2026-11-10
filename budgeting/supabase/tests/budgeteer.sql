\set ON_ERROR_STOP on
begin;
insert into auth.users(id) values('00000000-0000-4000-8000-000000000001'),('00000000-0000-4000-8000-000000000002');
insert into private.app_owner(owner_id) values('00000000-0000-4000-8000-000000000001');
insert into public.accounts(id,owner_id,source,name,kind) values('10000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000001','manual','Synthetic','cash');
insert into public.transactions(id,owner_id,account_id,source,source_id,amount_minor,description,transaction_date,posted_date,status) values
 ('20000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','csv','out',-1234,'Original groceries','2026-11-01','2026-11-01','posted'),
 ('20000000-0000-4000-8000-000000000002','00000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','csv','income',5000,'Pay','2026-11-01','2026-11-01','posted'),
 ('20000000-0000-4000-8000-000000000003','00000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','csv','refund',100,'Refund','2026-11-01','2026-11-01','posted'),
 ('20000000-0000-4000-8000-000000000004','00000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','csv','pending',-10,'Pending','2026-11-01',null,'pending');
insert into public.transaction_annotations(transaction_id,owner_id,category_id)
 select '20000000-0000-4000-8000-000000000002',owner_id,id from public.categories where name='Income';
insert into public.transaction_annotations(transaction_id,owner_id,category_id)
 select '20000000-0000-4000-8000-000000000003',owner_id,id from public.categories where name='Food';
create function pg_temp.assert(ok boolean,message text) returns void language plpgsql as $$ begin if not coalesce(ok,false) then raise exception 'assertion: %',message; end if; end $$;
create function pg_temp.expect_error(operation text,payload jsonb,expected text,month date default '2026-11-01',revision bigint default null) returns void language plpgsql as $$
declare rev bigint;
begin
 select coalesce((public.budgeteer_read(month)->'plan'->>'revision')::bigint,0) into rev;
 begin perform public.budgeteer_mutate(month,coalesce(revision,rev),operation,payload);
 exception when others then if sqlerrm=expected or sqlstate=expected then return; end if; raise; end;
 raise exception 'expected % for %',expected,operation;
end $$;
select pg_temp.assert(not has_table_privilege('authenticated','public.budgeteer_entries','insert'),'direct entry writes revoked');
select pg_temp.assert(not has_function_privilege('anon','public.budgeteer_read(date)','execute'),'anonymous read revoked');
select pg_temp.assert(not has_function_privilege('anon','public.budgeteer_mutate(date,bigint,text,jsonb)','execute'),'anonymous mutation revoked');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000000001","aal":"aal1"}',true);
do $$ begin begin perform public.budgeteer_read('2026-11-01'); raise exception 'MFA bypass'; exception when insufficient_privilege then null; end; end $$;
select set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000000002","aal":"aal2"}',true);
do $$ begin begin perform public.budgeteer_mutate('2026-11-01',0,'group_save','{"name":"No","color_key":"teal"}'); raise exception 'owner bypass'; exception when insufficient_privilege then null; end; end $$;
select pg_temp.assert((select count(*)=0 from public.budgeteer_plans),'non-owner RLS empty');
select set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000000001","aal":"aal2"}',true);
select pg_temp.assert(public.budgeteer_read('2026-11-01')='{"plan":null,"groups":[],"entries":[],"labels":[],"entry_labels":[]}'::jsonb,'empty read exact contract');
select pg_temp.assert((select count(*)=0 from public.budgeteer_plans),'read did not create plan');
select pg_temp.expect_error('entry_save','{"kind":"deposit","name":"Refund is not income","amount_minor":100,"source_transaction_id":"20000000-0000-4000-8000-000000000003","label_ids":[]}','budgeteer_invalid_source');
select pg_temp.assert((select count(*)=0 from public.budgeteer_plans),'failed mutation did not create plan');
select pg_temp.expect_error('entry_save','{"kind":"withdrawal","name":"Pending","amount_minor":10,"source_transaction_id":"20000000-0000-4000-8000-000000000004","label_ids":[]}','budgeteer_invalid_source');
select pg_temp.expect_error('entry_save','{"kind":"deposit","name":"Wrong sign","amount_minor":10,"source_transaction_id":"20000000-0000-4000-8000-000000000001","label_ids":[]}','budgeteer_invalid_source');
select public.budgeteer_mutate('2026-11-01',0,'group_save','{"name":" Essentials ","color_key":"teal"}') as state \gset
select pg_temp.assert(:'state'::jsonb->'plan'->>'revision'='1','creation revision one');
select public.budgeteer_mutate('2026-11-01',1,'label_save','{"name":"Needs","color_key":"blue"}');
select id as gid from public.budgeteer_groups \gset
select id as lid,updated_at::text as token from public.budgeteer_labels \gset
select public.budgeteer_mutate('2026-11-01',2,'entry_save',jsonb_build_object('kind','withdrawal','name','Independent groceries','amount_minor',1500,'group_id',:'gid','source_transaction_id','20000000-0000-4000-8000-000000000001','label_ids',jsonb_build_array(:'lid')));
select id as eid from public.budgeteer_entries where kind='withdrawal' \gset
select public.budgeteer_mutate('2026-11-01',3,'entry_save','{"kind":"deposit","name":"Independent pay","amount_minor":7000,"source_transaction_id":"20000000-0000-4000-8000-000000000002","label_ids":[]}');
select pg_temp.assert(public.budgeteer_read('2026-11-01')->'entries'->1->>'source_state'='linked','linked raw snapshot available');
select pg_temp.expect_error('entry_save','{"kind":"withdrawal","name":"Duplicate","amount_minor":10,"source_transaction_id":"20000000-0000-4000-8000-000000000001","label_ids":[]}','23505');
select pg_temp.expect_error('group_save','{"name":"Stale","color_key":"blue"}','budgeteer_conflict','2026-11-01',0);
select pg_temp.expect_error('reorder',jsonb_build_object('groups',jsonb_build_array(:'gid',:'gid'),'entries','[]'::jsonb),'budgeteer_invalid_order');
select pg_temp.expect_error('entry_save','{"kind":"withdrawal","name":"Overflow","amount_minor":9000000000000,"label_ids":[]}','budgeteer_total_overflow');
select pg_temp.expect_error('entry_save','{"kind":"withdrawal","name":"Fraction","amount_minor":1.5,"label_ids":[]}','22P02');
select pg_temp.assert((select revision=4 from public.budgeteer_plans),'failed writes preserve revision');
select set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000000002","aal":"aal2"}',true);
select pg_temp.assert((select count(*)=0 from public.budgeteer_entries),'non-owner cannot see populated entries');
select pg_temp.assert((select count(*)=0 from public.budgeteer_labels),'non-owner cannot see global labels');
select set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000000001","aal":"aal2"}',true);
select pg_temp.expect_error('entry_save',jsonb_build_object('id',:'eid','kind','withdrawal','name','Bad label','amount_minor',1,'label_ids',jsonb_build_array('ffffffff-ffff-4fff-8fff-ffffffffffff')),'budgeteer_invalid_labels');
select pg_temp.expect_error('reorder',jsonb_build_object('groups',jsonb_build_array(:'gid'),'entries',(select jsonb_agg(jsonb_build_object('id',id,'group_id',case when kind='deposit' then :'gid'::uuid else null end)) from public.budgeteer_entries)),'budgeteer_invalid_order');
select pg_temp.assert((select revision=4 from public.budgeteer_plans),'invalid reorder is atomic');
select public.budgeteer_mutate('2026-12-01',0,'group_save','{"name":"December","color_key":"rose"}');
select pg_temp.expect_error('entry_save',jsonb_build_object('id',:'eid','kind','withdrawal','name','Cross plan','amount_minor',1,'label_ids','[]'::jsonb),'budgeteer_entry_not_found','2026-12-01');
select pg_temp.expect_error('entry_save',jsonb_build_object('kind','withdrawal','name','Cross group','amount_minor',1,'group_id',:'gid','label_ids','[]'::jsonb),'budgeteer_invalid_group','2026-12-01');
select pg_temp.expect_error('label_save',jsonb_build_object('id',:'lid','name','No token','color_key','blue'),'budgeteer_conflict','2026-12-01');
select public.budgeteer_mutate('2026-12-01',1,'label_save',jsonb_build_object('id',:'lid','name','Required','color_key','violet','expected_updated_at',:'token'));
select pg_temp.assert((select revision=5 from public.budgeteer_plans where month='2026-11-01'),'global label advances other plan');
select pg_temp.expect_error('label_delete',jsonb_build_object('id',:'lid','expected_updated_at',:'token'),'budgeteer_conflict');
reset role;
update public.transactions set amount_minor=-1800,description='Synced groceries',status='pending' where id='20000000-0000-4000-8000-000000000001';
set local role authenticated;
select pg_temp.assert(public.budgeteer_read('2026-11-01')->'entries'->1->>'source_state'='changed','sync changes detected');
select pg_temp.assert((select name='Independent groceries' and amount_minor=1500 from public.budgeteer_entries where id=:'eid'),'sync preserves independent fields');
select pg_temp.expect_error('source_refresh',jsonb_build_object('id',:'eid'),'budgeteer_invalid_source');
reset role;
update public.transactions set status='posted' where id='20000000-0000-4000-8000-000000000001';
insert into public.transaction_annotations(transaction_id,owner_id,is_transfer) values('20000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000001',true);
set local role authenticated;
select pg_temp.expect_error('source_refresh',jsonb_build_object('id',:'eid'),'budgeteer_invalid_source');
reset role;
delete from public.transaction_annotations where transaction_id='20000000-0000-4000-8000-000000000001';
set local role authenticated;
select public.budgeteer_mutate('2026-11-01',5,'source_refresh',jsonb_build_object('id',:'eid'));
select pg_temp.assert((select name='Synced groceries' and amount_minor=1800 from public.budgeteer_entries where id=:'eid'),'explicit refresh resets fields');
select public.budgeteer_mutate('2026-11-01',6,'reorder',jsonb_build_object('groups',jsonb_build_array(:'gid'),'entries',(select jsonb_agg(jsonb_build_object('id',id,'group_id',group_id) order by kind desc) from public.budgeteer_entries where plan_id=(select id from public.budgeteer_plans where month='2026-11-01'))));
select public.budgeteer_mutate('2026-11-01',7,'group_delete',jsonb_build_object('id',:'gid'));
select pg_temp.assert((select group_id is null from public.budgeteer_entries where id=:'eid'),'group delete preserves and ungroups entry');
reset role;
delete from public.transactions where id='20000000-0000-4000-8000-000000000001';
set local role authenticated;
select pg_temp.assert((select revision=9 from public.budgeteer_plans where month='2026-11-01'),'source deletion bumps revision');
select pg_temp.assert(public.budgeteer_read('2026-11-01')->'entries'->1->>'source_state'='unavailable','source unavailable canonical state');
select pg_temp.assert((select source_transaction_id is null and source_snapshot->>'description'='Synced groceries' and amount_minor=1800 from public.budgeteer_entries where id=:'eid'),'source deletion preserves snapshot and amount');
select pg_temp.expect_error('source_unlink',jsonb_build_object('id',:'eid'),'budgeteer_conflict','2026-11-01',8);
select pg_temp.expect_error('source_refresh',jsonb_build_object('id',:'eid'),'budgeteer_source_unavailable');
select public.budgeteer_mutate('2026-11-01',9,'source_unlink',jsonb_build_object('id',:'eid'));
select pg_temp.assert(public.budgeteer_read('2026-11-01')->'entries'->1->>'source_state'='manual','unlink clears unavailable snapshot');
select id as lid,updated_at::text as token from public.budgeteer_labels \gset
select public.budgeteer_mutate('2026-11-01',10,'label_delete',jsonb_build_object('id',:'lid','expected_updated_at',:'token'));
select pg_temp.assert((select count(*)=2 from public.budgeteer_entries),'label deletion retains entries');
select pg_temp.assert((select count(*)=0 from public.budgeteer_entry_labels),'label deletion removes assignments');
reset role;
set local role service_role;
delete from public.accounts where id='10000000-0000-4000-8000-000000000001';
reset role;
select pg_temp.assert((select count(*)=2 from public.budgeteer_entries),'service account deletion preserves plan');
select pg_temp.assert((select revision=12 from public.budgeteer_plans where month='2026-11-01'),'account cascade source deletion advances revision');
delete from public.budgeteer_plans where month='2026-11-01';
select pg_temp.assert((select count(*)=0 from public.budgeteer_entries),'plan deletion cascades entries');
rollback;
