\set ON_ERROR_STOP on
create extension if not exists dblink;
insert into auth.users(id) values('00000000-0000-4000-8000-000000000001');
insert into private.app_owner(owner_id) values('00000000-0000-4000-8000-000000000001');
create function public.budgeteer_deposit_test_write(month date,revision bigint,op text,payload jsonb) returns text language plpgsql as $$
begin
 perform set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000000001","aal":"aal2"}',true);
 perform public.budgeteer_mutate(month,revision,op,payload||'{"schema_version":3}'::jsonb);
 perform pg_sleep(0.1);
 return 'saved';
exception when others then return sqlerrm;
end $$;
select public.budgeteer_deposit_test_write('2026-10-01',0,'group_save','{"kind":"deposit","name":"Salary","color_key":"hex_a1b2c3","parent_group_id":null}');
select public.budgeteer_deposit_test_write('2026-10-01',1,'group_save','{"kind":"withdrawal","name":"Bills","color_key":"blue","parent_group_id":null}');
select dblink_connect('deposit_a','dbname='||current_database()||' user=postgres');
select dblink_connect('deposit_b','dbname='||current_database()||' user=postgres');
create temporary table deposit_results(result text);
select dblink_send_query('deposit_a',$q$select public.budgeteer_deposit_test_write('2026-11-01',0,'sources_include','{}')$q$);
select dblink_send_query('deposit_b',$q$select public.budgeteer_deposit_test_write('2026-11-01',0,'initialize','{}')$q$);
insert into deposit_results select * from dblink_get_result('deposit_a') as t(result text);
insert into deposit_results select * from dblink_get_result('deposit_b') as t(result text);
do $$ begin
 if (select count(*) from deposit_results where result='saved')<>1 or (select count(*) from deposit_results where result='budgeteer_conflict')<>1 then raise exception 'v3 initialization race not atomic'; end if;
 if (select count(*) from public.budgeteer_groups g join public.budgeteer_plans p on p.id=g.plan_id where p.month='2026-11-01')<>2 then raise exception 'both kinds copied more than once'; end if;
 if (select count(*) from public.budgeteer_groups g join public.budgeteer_plans p on p.id=g.plan_id where p.month='2026-11-01' and g.kind='deposit')<>1 then raise exception 'deposit kind not copied'; end if;
end $$;
select * from dblink_get_result('deposit_a') as t(result text);
select * from dblink_get_result('deposit_b') as t(result text);
select id as source from public.budgeteer_plans where month='2026-10-01' \gset
truncate deposit_results;
select dblink_send_query('deposit_a',format('select public.budgeteer_deposit_test_write(%L,1,%L,%L::jsonb)','2026-11-01','groups_copy',jsonb_build_object('confirmed',true,'source_plan_id',:'source','source_revision',2)));
select dblink_send_query('deposit_b',format('select public.budgeteer_deposit_test_write(%L,1,%L,%L::jsonb)','2026-11-01','groups_copy',jsonb_build_object('confirmed',true,'source_plan_id',:'source','source_revision',2)));
insert into deposit_results select * from dblink_get_result('deposit_a') as t(result text);
insert into deposit_results select * from dblink_get_result('deposit_b') as t(result text);
do $$ begin
 if (select count(*) from deposit_results where result='saved')<>1 or (select count(*) from deposit_results where result='budgeteer_conflict')<>1 then raise exception 'v3 confirmed copy race not atomic'; end if;
 if (select count(*) from public.budgeteer_groups g join public.budgeteer_plans p on p.id=g.plan_id where p.month='2026-11-01')<>4 then raise exception 'v3 copy duplicated or replaced definitions'; end if;
end $$;
select dblink_disconnect('deposit_a');
select dblink_disconnect('deposit_b');
drop function public.budgeteer_deposit_test_write(date,bigint,text,jsonb);
delete from public.budgeteer_plans;
delete from public.categories;
delete from public.profiles;
delete from private.app_owner;
delete from auth.users;
