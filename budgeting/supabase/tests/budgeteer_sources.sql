\set ON_ERROR_STOP on
begin;
insert into auth.users(id) values('00000000-0000-4000-8000-000000000001'),('00000000-0000-4000-8000-000000000002');
insert into private.app_owner(owner_id) values('00000000-0000-4000-8000-000000000001');
insert into public.accounts(id,owner_id,source,name,kind) values
 ('10000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000001','manual','First','cash'),
 ('10000000-0000-4000-8000-000000000002','00000000-0000-4000-8000-000000000001','manual','Second','cash');
insert into public.transactions(id,owner_id,account_id,source,source_id,amount_minor,description,transaction_date,posted_date,status)
select ('20000000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,'00000000-0000-4000-8000-000000000001',
 case when i%2=0 then '10000000-0000-4000-8000-000000000002'::uuid else '10000000-0000-4000-8000-000000000001'::uuid end,
 'csv','source-'||i,case when i=4 then 0 when i in (1,6) then 100 else -100 end,
  case when i=1 then ' ' when i=10 then repeat('x',119)||' trailing text' else 'Transaction '||i end,
 case when i=13 then '2026-10-31'::date else '2026-11-01'::date end,
 case when i=2 then null when i=11 then '2026-10-31'::date when i=12 then '2026-12-01'::date else '2026-11-01'::date end,
 case when i=3 then 'pending' else 'posted' end
from generate_series(1,13) i;
insert into public.transaction_annotations(transaction_id,owner_id,is_transfer,is_card_payment,excluded_from_budget)
select id,owner_id,source_id='source-5',source_id='source-8',source_id='source-9' from public.transactions where source_id in ('source-5','source-8','source-9');
insert into public.transaction_annotations(transaction_id,owner_id,category_id)
select t.id,t.owner_id,c.id from public.transactions t join public.categories c on c.owner_id=t.owner_id
where (t.source_id='source-6' and c.name='Food') or (t.source_id='source-7' and c.name='Income');
create function pg_temp.assert(ok boolean,message text) returns void language plpgsql as $$ begin if not coalesce(ok,false) then raise exception 'assertion: %',message; end if; end $$;
create function pg_temp.mutate(op text,payload jsonb default '{}',month date default '2026-11-01') returns jsonb language sql as $$
 select public.budgeteer_mutate(month,coalesce((public.budgeteer_read(month)->'plan'->>'revision')::bigint,0),op,payload)
$$;
create function pg_temp.expect_error(op text,payload jsonb,expected text,month date default '2026-11-01',revision bigint default null) returns void language plpgsql as $$
begin
 begin perform public.budgeteer_mutate(month,coalesce(revision,(public.budgeteer_read(month)->'plan'->>'revision')::bigint,0),op,payload);
 exception when others then if sqlerrm=expected or sqlstate=expected then return; end if; raise; end;
 raise exception 'expected % for %',expected,op;
end $$;
create temporary table raw_before as select to_jsonb(t) as row from public.transactions t;
select pg_temp.assert(not has_table_privilege('authenticated','public.budgeteer_source_exclusions','insert'),'exclusion writes revoked');
select pg_temp.assert(not has_function_privilege('authenticated','private.budgeteer_mutate_existing(date,bigint,text,jsonb)','execute'),'original implementation inaccessible');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000000001","aal":"aal1"}',true);
do $$ begin begin perform public.budgeteer_mutate('2026-11-01',0,'sources_include','{}'); raise exception 'MFA bypass'; exception when insufficient_privilege then null; end; end $$;
select pg_temp.assert((select count(*)=0 from public.budgeteer_source_exclusions),'MFA exclusion RLS denial');
select set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000000002","aal":"aal2"}',true);
do $$ begin begin perform public.budgeteer_mutate('2026-11-01',0,'sources_restore','{}'); raise exception 'owner bypass'; exception when insufficient_privilege then null; end; end $$;
select set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000000001","aal":"aal2"}',true);
select pg_temp.assert(public.budgeteer_read('2026-11-01')->'plan'='null'::jsonb,'read remains side-effect-free despite eligible sources');
select pg_temp.assert(pg_temp.mutate('sources_include','{}','2027-01-01')->'plan'='null'::jsonb,'empty include creates no plan');
select pg_temp.assert(pg_temp.mutate('sources_restore','{}','2027-01-01')->'plan'='null'::jsonb,'empty restore creates no plan');
select pg_temp.expect_error('sources_include','{"id":null}','budgeteer_invalid_payload');
select pg_temp.mutate('sources_include');
select pg_temp.assert((select revision=1 from public.budgeteer_plans where month='2026-11-01'),'one revision for batch');
select pg_temp.assert((select count(*)=4 from public.budgeteer_entries),'all accounts, fallback and posted date eligibility');
select pg_temp.assert((select array_agg(source_snapshot->>'source_id' order by sort_position)=array['source-1','source-2','source-10','source-13'] from public.budgeteer_entries),'deterministic append order');
select pg_temp.assert((select name='Bank transaction' and kind='deposit' from public.budgeteer_entries where source_snapshot->>'source_id'='source-1'),'blank description fallback');
select pg_temp.assert((select name=repeat('x',119) from public.budgeteer_entries where source_snapshot->>'source_id'='source-10'),'truncated source name remains trimmed');
select pg_temp.assert((select count(*)=3 from public.budgeteer_entries where kind='withdrawal' and group_id is null),'new withdrawals ungrouped');
select pg_temp.assert(pg_temp.mutate('sources_include')->'plan'->>'revision'='1','retry is no-op');
select pg_temp.expect_error('sources_include','{}','budgeteer_conflict','2026-11-01',0);
select id as eid from public.budgeteer_entries where source_snapshot->>'source_id'='source-2' \gset
select pg_temp.mutate('group_save','{"name":"Custom","color_key":"blue"}');
select id as gid from public.budgeteer_groups \gset
select pg_temp.mutate('label_save','{"name":"Custom","color_key":"blue"}');
select id as lid from public.budgeteer_labels \gset
select pg_temp.mutate('entry_save',jsonb_build_object('id',:'eid','kind','withdrawal','name','Edited','amount_minor',333,'group_id',:'gid','label_ids',jsonb_build_array(:'lid')));
select pg_temp.mutate('entry_save','{"kind":"deposit","name":"Manual","amount_minor":777,"label_ids":[]}');
reset role;
create temporary table preserved as select to_jsonb(e) as row from public.budgeteer_entries e;
update public.transactions set amount_minor=-222,description='Synced' where source_id='source-2';
insert into public.transactions(owner_id,account_id,source,source_id,amount_minor,description,transaction_date,status)
values('00000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000002','csv','new',-444,'New import','2026-11-10','posted');
set local role authenticated;
select pg_temp.mutate('sources_include');
select pg_temp.assert((select count(*)=6 from public.budgeteer_entries),'new imports appended with manual retained');
select pg_temp.assert((select count(*)=1 from public.budgeteer_entry_labels),'labels retained');
reset role;
select pg_temp.assert(not exists(select row from preserved except select to_jsonb(e) from public.budgeteer_entries e),'inclusion preserves all saved entry fields and snapshots');
set local role authenticated;
select pg_temp.mutate('source_unlink',jsonb_build_object('id',:'eid'));
select pg_temp.assert(public.budgeteer_read('2026-11-01')->>'excluded_source_count'='1','unlink exclusion canonical count');
select pg_temp.mutate('sources_include');
select pg_temp.assert((select count(*)=6 from public.budgeteer_entries),'unlink never duplicates independent item');
select pg_temp.mutate('entry_save',jsonb_build_object('id',:'eid','kind','withdrawal','name','Relinked','amount_minor',333,'group_id',:'gid','source_transaction_id','20000000-0000-4000-8000-000000000002','label_ids',jsonb_build_array(:'lid')));
select pg_temp.assert(public.budgeteer_read('2026-11-01')->>'excluded_source_count'='0','explicit relink clears exclusion');
select pg_temp.mutate('entry_delete',jsonb_build_object('id',:'eid'));
select pg_temp.mutate('sources_include');
select pg_temp.assert((select count(*)=5 from public.budgeteer_entries),'linked deletion survives reload inclusion');
select pg_temp.assert(public.budgeteer_read('2026-11-01')->>'excluded_source_count'='1','delete exclusion visible');
select set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000000002","aal":"aal2"}',true);
select pg_temp.assert((select count(*)=0 from public.budgeteer_source_exclusions),'nonowner exclusion RLS denial');
select set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000000001","aal":"aal2"}',true);
select pg_temp.mutate('sources_include','{}','2026-10-01');
select pg_temp.assert((select count(*)=1 from public.budgeteer_entries e join public.budgeteer_plans p on p.id=e.plan_id where p.month='2026-10-01'),'month isolation');
select pg_temp.mutate('sources_include','{}','2026-12-01');
select id as december_eid from public.budgeteer_entries where source_snapshot->>'source_id'='source-12' \gset
select pg_temp.mutate('source_unlink',jsonb_build_object('id',:'december_eid'),'2026-12-01');
select pg_temp.assert(public.budgeteer_read('2026-11-01')->>'excluded_source_count'='1','other month unlink preserves November exclusion');
select pg_temp.mutate('sources_restore','{}','2026-12-01');
select pg_temp.assert((select count(*)=2 from public.budgeteer_entries e join public.budgeteer_plans p on p.id=e.plan_id where p.month='2026-12-01'),'restoring unlink retains independent item and explicitly restores source');
select pg_temp.mutate('entry_delete',jsonb_build_object('id',:'december_eid'),'2026-12-01');
select pg_temp.assert(public.budgeteer_read('2026-12-01')->>'excluded_source_count'='0','manual deletion adds no source exclusion');
select pg_temp.mutate('sources_restore');
select pg_temp.assert(public.budgeteer_read('2026-11-01')->>'excluded_source_count'='0','restore clears exclusions');
select pg_temp.assert((select amount_minor=222 and group_id is null from public.budgeteer_entries where source_transaction_id='20000000-0000-4000-8000-000000000002'),'restore includes current source snapshot ungrouped');
select id as eid from public.budgeteer_entries where source_transaction_id='20000000-0000-4000-8000-000000000002' \gset
select pg_temp.mutate('entry_delete',jsonb_build_object('id',:'eid'));
select pg_temp.mutate('entry_save','{"kind":"withdrawal","name":"Limit","amount_minor":8999999999256,"label_ids":[]}');
select public.budgeteer_read('2026-11-01') as before_restore \gset
select pg_temp.expect_error('sources_restore','{}','budgeteer_total_overflow');
select pg_temp.assert(public.budgeteer_read('2026-11-01')=:'before_restore'::jsonb,'restore overflow rolls back exclusions entries revision');
reset role;
update public.transactions set status='pending' where source_id='source-2';
set local role authenticated;
select pg_temp.mutate('sources_restore');
select pg_temp.assert(public.budgeteer_read('2026-11-01')->>'excluded_source_count'='0','restore clears currently ineligible exclusions too');
reset role;
-- A new oversized monthly batch must leave no partially created plan or entries.
insert into public.transactions(owner_id,account_id,source,source_id,amount_minor,description,transaction_date,status)
select '00000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000002','csv','overflow-'||i,9000000000000,'Limit','2027-02-01','posted' from generate_series(1,2) i;
set local role authenticated;
select pg_temp.expect_error('sources_include','{}','budgeteer_total_overflow','2027-02-01');
select pg_temp.assert(public.budgeteer_read('2027-02-01')->'plan'='null'::jsonb,'initial overflow rolls back plan');
-- Removing a source exclusion via account cascade must advance the plan revision.
select id as eid from public.budgeteer_entries where source_transaction_id='20000000-0000-4000-8000-000000000001' \gset
select pg_temp.mutate('entry_delete',jsonb_build_object('id',:'eid'));
select (public.budgeteer_read('2026-11-01')->'plan'->>'revision')::bigint as before_delete \gset
reset role;
-- Only intentional provider changes above differ from the raw fixture.
select pg_temp.assert((select count(*)=12 from (select row from raw_before intersect select to_jsonb(t) from public.transactions t) unchanged),'Budgeteer never mutates raw transactions');
set local role service_role;
delete from public.accounts where id='10000000-0000-4000-8000-000000000001';
reset role;
set local role authenticated;
select pg_temp.assert(public.budgeteer_read('2026-11-01')->>'excluded_source_count'='0','account deletion cascades exclusions');
select pg_temp.assert((public.budgeteer_read('2026-11-01')->'plan'->>'revision')::bigint>:'before_delete'::bigint,'exclusion deletion advances revision');
select pg_temp.assert((select count(*)>0 from public.budgeteer_entries where source_snapshot is not null and source_transaction_id is null),'account deletion retains independent snapshots');
select id as eid from public.budgeteer_entries where source_snapshot->>'source_id'='source-10' \gset
select pg_temp.mutate('entry_delete',jsonb_build_object('id',:'eid'));
reset role;
delete from public.budgeteer_plans;
select pg_temp.assert((select count(*)=0 from public.budgeteer_source_exclusions),'plan deletion cascades exclusions');
rollback;
