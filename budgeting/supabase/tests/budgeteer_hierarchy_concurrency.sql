\set ON_ERROR_STOP on
create extension if not exists dblink;
insert into auth.users(id) values('00000000-0000-4000-8000-000000000001');
insert into private.app_owner(owner_id) values('00000000-0000-4000-8000-000000000001');
create function public.budgeteer_hierarchy_test_write(month date,revision bigint,op text,payload jsonb) returns text language plpgsql as $$
begin
 perform set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000000001","aal":"aal2"}',true);
 perform public.budgeteer_mutate(month,revision,op,payload);
 perform pg_sleep(0.1);
 return 'saved';
exception when others then return sqlerrm;
end $$;
select public.budgeteer_hierarchy_test_write('2026-10-01',0,'group_save','{"name":"Root","color_key":"teal","parent_group_id":null}');
select id as root from public.budgeteer_groups \gset
select public.budgeteer_hierarchy_test_write('2026-10-01',1,'group_save',jsonb_build_object('name','Child','color_key','blue','parent_group_id',:'root'));
select dblink_connect('hierarchy_a','dbname='||current_database()||' user=postgres');
select dblink_connect('hierarchy_b','dbname='||current_database()||' user=postgres');
create temporary table hierarchy_results(result text);
-- Two empty source batches must create/copy only once, even without transactions.
select dblink_send_query('hierarchy_a',$q$select public.budgeteer_hierarchy_test_write('2026-11-01',0,'sources_include','{}')$q$);
select dblink_send_query('hierarchy_b',$q$select public.budgeteer_hierarchy_test_write('2026-11-01',0,'initialize','{}')$q$);
insert into hierarchy_results select * from dblink_get_result('hierarchy_a') as t(result text);
insert into hierarchy_results select * from dblink_get_result('hierarchy_b') as t(result text);
do $$ begin
 if (select count(*) from hierarchy_results where result='saved')<>1 or (select count(*) from hierarchy_results where result='budgeteer_conflict')<>1 then raise exception 'empty initialization race not atomic'; end if;
 if (select count(*) from public.budgeteer_groups g join public.budgeteer_plans p on p.id=g.plan_id where p.month='2026-11-01')<>2 then raise exception 'tree copied more than once'; end if;
 if (select revision from public.budgeteer_plans where month='2026-11-01')<>1 then raise exception 'wrong empty initialization revision'; end if;
end $$;
-- Drain libpq's trailing result before reusing async connections.
select * from dblink_get_result('hierarchy_a') as t(result text);
select * from dblink_get_result('hierarchy_b') as t(result text);
select id as source from public.budgeteer_plans where month='2026-10-01' \gset
truncate hierarchy_results;
select dblink_send_query('hierarchy_a',format('select public.budgeteer_hierarchy_test_write(%L,1,%L,%L::jsonb)','2026-11-01','groups_copy',jsonb_build_object('confirmed',true,'source_plan_id',:'source','source_revision',2)));
select dblink_send_query('hierarchy_b',format('select public.budgeteer_hierarchy_test_write(%L,1,%L,%L::jsonb)','2026-11-01','groups_copy',jsonb_build_object('confirmed',true,'source_plan_id',:'source','source_revision',2)));
insert into hierarchy_results select * from dblink_get_result('hierarchy_a') as t(result text);
insert into hierarchy_results select * from dblink_get_result('hierarchy_b') as t(result text);
do $$ begin
 if (select count(*) from hierarchy_results where result='saved')<>1 or (select count(*) from hierarchy_results where result='budgeteer_conflict')<>1 then raise exception 'confirmed copy race not atomic'; end if;
 if (select count(*) from public.budgeteer_groups g join public.budgeteer_plans p on p.id=g.plan_id where p.month='2026-11-01')<>4 then raise exception 'confirmed copy duplicated or replaced groups'; end if;
end $$;
select dblink_disconnect('hierarchy_a');
select dblink_disconnect('hierarchy_b');
drop function public.budgeteer_hierarchy_test_write(date,bigint,text,jsonb);
delete from public.budgeteer_plans;
delete from public.categories;
delete from public.profiles;
delete from private.app_owner;
delete from auth.users;
