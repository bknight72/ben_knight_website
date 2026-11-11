\set ON_ERROR_STOP on
create extension if not exists dblink;
insert into auth.users(id) values('00000000-0000-4000-8000-000000000001');
insert into private.app_owner(owner_id) values('00000000-0000-4000-8000-000000000001');
create function public.budgeteer_global_test_write(month date,revision bigint,groups_revision bigint,op text,payload jsonb) returns text language plpgsql as $$
begin
 perform set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000000001","aal":"aal2"}',true);
 perform public.budgeteer_mutate(month,revision,op,payload||jsonb_build_object('schema_version',4,'expected_groups_revision',groups_revision));
 perform pg_sleep(0.1);
 return 'saved';
exception when others then return sqlerrm;
end $$;
select dblink_connect('global_a','dbname='||current_database()||' user=postgres');
select dblink_connect('global_b','dbname='||current_database()||' user=postgres');
create temporary table global_results(result text);
-- Distinct month revisions cannot hide a stale shared-catalog edit.
select dblink_send_query('global_a',$q$select public.budgeteer_global_test_write('2026-10-01',0,0,'group_save','{"kind":"withdrawal","name":"Bills","color_key":"blue","parent_group_id":null}')$q$);
select dblink_send_query('global_b',$q$select public.budgeteer_global_test_write('2026-11-01',0,0,'group_save','{"kind":"deposit","name":"Salary","color_key":"teal","parent_group_id":null}')$q$);
insert into global_results select * from dblink_get_result('global_a') as t(result text);
insert into global_results select * from dblink_get_result('global_b') as t(result text);
do $$ begin
 if (select count(*) from global_results where result='saved')<>1 or (select count(*) from global_results where result='budgeteer_conflict')<>1 then raise exception 'cross-month global race not atomic'; end if;
 if (select count(*) from public.budgeteer_groups)<>1 or (select revision from public.budgeteer_group_state)<>1 then raise exception 'global race duplicated definitions or revision'; end if;
 if (select count(*) from public.budgeteer_plans)<>1 then raise exception 'failed global edit initialized month'; end if;
end $$;
select * from dblink_get_result('global_a') as t(result text);
select * from dblink_get_result('global_b') as t(result text);
-- Separate-month initialization is allowed with the same current global revision.
select public.budgeteer_global_test_write('2030-01-01',0,1,'initialize','{}');
select public.budgeteer_global_test_write('2030-02-01',0,1,'initialize','{}');
truncate global_results;
select id as target,kind as kind from public.budgeteer_groups \gset
select dblink_send_query('global_a',format('select public.budgeteer_global_test_write(%L,1,1,%L,%L::jsonb)','2030-01-01','group_save',jsonb_build_object('id',:'target','kind',:'kind','name','Changed','color_key','rose','parent_group_id',null)));
select dblink_send_query('global_b',format('select public.budgeteer_global_test_write(%L,1,1,%L,%L::jsonb)','2030-02-01','entry_save',jsonb_build_object('kind',:'kind','name','Race assignment','amount_minor',10,'group_id',:'target')));
insert into global_results select * from dblink_get_result('global_a') as t(result text);
insert into global_results select * from dblink_get_result('global_b') as t(result text);
do $$ begin
 if (select count(*) from global_results where result='saved')<1 or exists(select 1 from global_results where result not in ('saved','budgeteer_conflict')) then raise exception 'catalog/assignment race invalid'; end if;
 if (select revision from public.budgeteer_group_state)<>2 then raise exception 'global edit failed'; end if;
end $$;
select * from dblink_get_result('global_a') as t(result text);
select * from dblink_get_result('global_b') as t(result text);
-- Deletion serializes with a concurrent assignment; either assignment precedes
-- deletion and is cleared, or the stale global token rejects it.
select revision as feb_revision from public.budgeteer_plans where month='2030-02-01' \gset
truncate global_results;
select dblink_send_query('global_a',format('select public.budgeteer_global_test_write(%L,2,2,%L,%L::jsonb)','2030-01-01','group_delete',jsonb_build_object('id',:'target')));
select dblink_send_query('global_b',format('select public.budgeteer_global_test_write(%L,%s,2,%L,%L::jsonb)','2030-02-01',:'feb_revision','entry_save',jsonb_build_object('kind',:'kind','name','Delete race','amount_minor',10,'group_id',:'target')));
insert into global_results select * from dblink_get_result('global_a') as t(result text);
insert into global_results select * from dblink_get_result('global_b') as t(result text);
do $$ begin
 if exists(select 1 from global_results where result not in ('saved','budgeteer_conflict')) then raise exception 'delete/assignment race invalid'; end if;
 if exists(select 1 from public.budgeteer_groups) or exists(select 1 from public.budgeteer_entries where group_id is not null) then raise exception 'delete race retained assignment'; end if;
 if (select revision from public.budgeteer_group_state)<>3 then raise exception 'delete revision missing'; end if;
end $$;
select dblink_disconnect('global_a');
select dblink_disconnect('global_b');
drop function public.budgeteer_global_test_write(date,bigint,bigint,text,jsonb);
delete from public.budgeteer_plans;
delete from public.budgeteer_groups;
delete from public.budgeteer_group_state;
delete from public.categories;
delete from public.profiles;
delete from private.app_owner;
delete from auth.users;
