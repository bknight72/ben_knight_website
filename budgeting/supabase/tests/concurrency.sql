\set ON_ERROR_STOP on
-- Run in the isolated test database after authorization.sql. dblink represents two workers.
create extension if not exists dblink;
insert into auth.users(id) values('00000000-0000-4000-8000-000000000001');
insert into private.app_owner(owner_id) values('00000000-0000-4000-8000-000000000001');
insert into public.accounts(id,owner_id,source,name,kind) values
 ('10000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000001','manual','Synthetic A','cash'),
 ('10000000-0000-4000-8000-000000000002','00000000-0000-4000-8000-000000000001','manual','Synthetic B','cash');
insert into private.refresh_usage(account_id,reserved_at) select '10000000-0000-4000-8000-000000000001',now()-interval '25 hours' from generate_series(1,49);
select dblink_connect('cap_a','dbname='||current_database()||' user=postgres');
select dblink_connect('cap_b','dbname='||current_database()||' user=postgres');
select dblink_send_query('cap_a',$q$select public.backend_state('reserve','{"account_id":"10000000-0000-4000-8000-000000000001"}')$q$);
select dblink_send_query('cap_b',$q$select public.backend_state('reserve','{"account_id":"10000000-0000-4000-8000-000000000002"}')$q$);
create temporary table cap_results(result jsonb);
insert into cap_results select * from dblink_get_result('cap_a',false) as t(result jsonb);
insert into cap_results select * from dblink_get_result('cap_b',false) as t(result jsonb);
do $$ begin
 if (select count(*) from cap_results)<>1 or (select count(*) from private.refresh_usage)<>50 then raise exception 'Concurrent reservations bypassed cap'; end if;
 if (select count(*) from private.jobs where kind='balance')<>1 then raise exception 'Losing cap reservation created a paid job'; end if;
end $$;
select dblink_disconnect('cap_a');
select dblink_disconnect('cap_b');
delete from public.accounts where owner_id='00000000-0000-4000-8000-000000000001';
do $$ begin
 if (select count(*) from private.refresh_usage)<>50 then raise exception 'Account deletion erased monthly usage'; end if;
end $$;
delete from private.refresh_usage;
delete from public.categories;
delete from public.profiles;
delete from private.app_owner;
delete from auth.users;
