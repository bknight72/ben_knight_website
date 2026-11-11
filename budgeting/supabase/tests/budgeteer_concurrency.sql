\set ON_ERROR_STOP on
create extension if not exists dblink;
insert into auth.users(id) values('00000000-0000-4000-8000-000000000001');
insert into private.app_owner(owner_id) values('00000000-0000-4000-8000-000000000001');
-- Test-only wrapper returns errors so both asynchronous results can be asserted.
create function public.budgeteer_test_write(month date,revision bigint,op text,payload jsonb,hold boolean default false) returns text language plpgsql as $$
declare result jsonb;
begin
 perform set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000000001","aal":"aal2"}',true);
 result:=public.budgeteer_mutate(month,revision,op,payload);
 if hold then perform pg_sleep(0.2); end if;
 return 'saved';
exception when others then return sqlerrm;
end $$;
select dblink_connect('budgeteer_a','dbname='||current_database()||' user=postgres');
select dblink_connect('budgeteer_b','dbname='||current_database()||' user=postgres');
select dblink_send_query('budgeteer_a',$q$select public.budgeteer_test_write('2026-11-01',0,'group_save','{"name":"A","color_key":"teal"}',true)$q$);
select dblink_send_query('budgeteer_b',$q$select public.budgeteer_test_write('2026-11-01',0,'group_save','{"name":"B","color_key":"blue"}',true)$q$);
create temporary table budgeteer_results(result text);
insert into budgeteer_results select * from dblink_get_result('budgeteer_a') as t(result text);
insert into budgeteer_results select * from dblink_get_result('budgeteer_b') as t(result text);
do $$ begin
 if (select count(*) from budgeteer_results where result='saved')<>1 or (select count(*) from budgeteer_results where result='budgeteer_conflict')<>1 then raise exception 'concurrent absent plan creation did not conflict atomically'; end if;
 if (select count(*) from public.budgeteer_plans)<>1 or (select count(*) from public.budgeteer_groups)<>1 or (select revision from public.budgeteer_plans)<>1 then raise exception 'concurrent create partially persisted'; end if;
end $$;
select dblink_disconnect('budgeteer_a');
select dblink_disconnect('budgeteer_b');
select public.budgeteer_test_write('2026-11-01',1,'label_save','{"name":"Needs","color_key":"blue"}');
select public.budgeteer_test_write('2026-12-01',0,'group_save','{"name":"December","color_key":"blue"}');
select id as lid,updated_at::text as token from public.budgeteer_labels \gset
select dblink_connect('budgeteer_a','dbname='||current_database()||' user=postgres');
select dblink_connect('budgeteer_b','dbname='||current_database()||' user=postgres');
select dblink_send_query('budgeteer_a',format('select public.budgeteer_test_write(%L,2,%L,%L::jsonb,true)','2026-11-01','label_save',jsonb_build_object('id',:'lid','name','First','color_key','teal','expected_updated_at',:'token')));
select dblink_send_query('budgeteer_b',format('select public.budgeteer_test_write(%L,1,%L,%L::jsonb,true)','2026-12-01','label_delete',jsonb_build_object('id',:'lid','expected_updated_at',:'token')));
truncate budgeteer_results;
insert into budgeteer_results select * from dblink_get_result('budgeteer_a') as t(result text);
insert into budgeteer_results select * from dblink_get_result('budgeteer_b') as t(result text);
do $$ begin
 if (select count(*) from budgeteer_results where result='saved')<>1 or (select count(*) from budgeteer_results where result='budgeteer_conflict')<>1 then raise exception 'owner-global concurrent label writes were not serialized'; end if;
 if (select revision from public.budgeteer_plans where month='2026-11-01')<>3 or (select revision from public.budgeteer_plans where month='2026-12-01')<>2 then raise exception 'label revisions not advanced on both plans'; end if;
end $$;
select dblink_disconnect('budgeteer_a');
select dblink_disconnect('budgeteer_b');
insert into public.accounts(id,owner_id,source,name,kind) values('10000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000001','manual','Synthetic','cash');
insert into public.transactions(id,owner_id,account_id,source,source_id,amount_minor,description,transaction_date,posted_date,status)
 values('20000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','csv','race',-123,'Race','2026-11-01','2026-11-01','posted');
select public.budgeteer_test_write('2026-11-01',3,'entry_save','{"kind":"withdrawal","name":"Independent","amount_minor":321,"source_transaction_id":"20000000-0000-4000-8000-000000000001","label_ids":[]}');
select id as eid from public.budgeteer_entries \gset
select dblink_connect('budgeteer_a','dbname='||current_database()||' user=postgres');
select dblink_connect('budgeteer_b','dbname='||current_database()||' user=postgres');
select dblink_send_query('budgeteer_a',format('select public.budgeteer_test_write(%L,4,%L,%L::jsonb,true)','2026-11-01','entry_save',jsonb_build_object('id',:'eid','kind','withdrawal','name','Concurrent independent','amount_minor',456,'label_ids','[]'::jsonb)));
select dblink_send_query('budgeteer_b',$q$delete from public.transactions where id='20000000-0000-4000-8000-000000000001' returning id$q$);
truncate budgeteer_results;
insert into budgeteer_results select * from dblink_get_result('budgeteer_a') as t(result text);
select * from dblink_get_result('budgeteer_b') as t(id uuid);
do $$ begin
 if (select result from budgeteer_results) not in ('saved','budgeteer_conflict') then raise exception 'delete/write race returned unexpected error'; end if;
 if exists(select 1 from public.budgeteer_entries where source_transaction_id is not null or source_snapshot is null) then raise exception 'delete race lost snapshot or preserved dangling link'; end if;
 if (select revision from public.budgeteer_plans where month='2026-11-01') not in (5,6) then raise exception 'source deletion failed to advance revision'; end if;
end $$;
select dblink_disconnect('budgeteer_a');
select dblink_disconnect('budgeteer_b');
insert into public.transactions(owner_id,account_id,source,source_id,amount_minor,description,transaction_date,status)
 values('00000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','csv','include-race',-123,'Race','2027-01-01','posted');
select dblink_connect('budgeteer_a','dbname='||current_database()||' user=postgres');
select dblink_connect('budgeteer_b','dbname='||current_database()||' user=postgres');
select dblink_send_query('budgeteer_a',$q$select public.budgeteer_test_write('2027-01-01',0,'sources_include','{}',true)$q$);
select dblink_send_query('budgeteer_b',$q$select public.budgeteer_test_write('2027-01-01',0,'sources_include','{}',true)$q$);
truncate budgeteer_results;
insert into budgeteer_results select * from dblink_get_result('budgeteer_a') as t(result text);
insert into budgeteer_results select * from dblink_get_result('budgeteer_b') as t(result text);
do $$ begin
 if (select count(*) from budgeteer_results where result='saved')<>1 or (select count(*) from budgeteer_results where result='budgeteer_conflict')<>1 then raise exception 'concurrent source inclusion did not conflict atomically'; end if;
 if (select count(*) from public.budgeteer_entries e join public.budgeteer_plans p on p.id=e.plan_id where p.month='2027-01-01')<>1 then raise exception 'concurrent inclusion duplicated sources'; end if;
end $$;
select dblink_disconnect('budgeteer_a');
select dblink_disconnect('budgeteer_b');
select public.budgeteer_test_write('2027-01-01',1,'sources_include','{}');
do $$ begin if (select revision from public.budgeteer_plans where month='2027-01-01')<>1 then raise exception 'retry inclusion was not idempotent'; end if; end $$;
drop function public.budgeteer_test_write(date,bigint,text,jsonb,boolean);
delete from public.budgeteer_plans;
delete from public.budgeteer_labels;
delete from public.accounts;
delete from public.categories;
delete from public.profiles;
delete from private.app_owner;
delete from auth.users;
