\set ON_ERROR_STOP on
begin;
insert into auth.users(id) values('00000000-0000-4000-8000-000000000001'),('00000000-0000-4000-8000-000000000002');
insert into private.app_owner(owner_id) values('00000000-0000-4000-8000-000000000001');
insert into public.accounts(id,owner_id,source,name,kind,connection_state) values('10000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000001','stripe','Synthetic','cash','active');
create function pg_temp.assert(ok boolean,message text) returns void language plpgsql as $$ begin if not coalesce(ok,false) then raise exception 'assertion: %',message; end if; end $$;
set local role authenticated;
set local request.jwt.claims='{"sub":"00000000-0000-4000-8000-000000000002","aal":"aal2"}';
do $$ begin
 begin perform public.budget_refresh_usage(); raise exception 'wrong-owner usage accepted'; exception when insufficient_privilege then null; end;
end $$;
set local request.jwt.claims='{"sub":"00000000-0000-4000-8000-000000000001","aal":"aal1"}';
do $$ begin
 begin perform public.budget_refresh_usage(); raise exception 'aal1 usage accepted'; exception when insufficient_privilege then null; end;
end $$;
set local request.jwt.claims='{"sub":"00000000-0000-4000-8000-000000000001","aal":"aal2"}';
select pg_temp.assert(public.budget_refresh_usage()->>'reservedAttempts'='0','initial usage zero');
select pg_temp.assert(public.budget_refresh_usage()->>'remainingAttempts'='50','initial remaining 50');
select pg_temp.assert(public.budget_refresh_usage()->'accounts'->0->>'nextEligibleRefreshAt' is null,'no initial cooldown');
select pg_temp.assert(not has_function_privilege('anon','public.budget_refresh_usage()','execute'),'anonymous usage revoked');
reset role;
select pg_temp.assert(not has_function_privilege('authenticated','private.backend_state_legacy(text,jsonb)','execute'),'legacy gateway revoked');
select pg_temp.assert(not exists(select 1 from pg_tables where schemaname='private' and (has_table_privilege('anon',quote_ident(schemaname)||'.'||quote_ident(tablename),'select') or has_table_privilege('authenticated',quote_ident(schemaname)||'.'||quote_ident(tablename),'select'))),'all private table grants revoked');
select pg_temp.assert(not has_function_privilege('anon','public.is_budget_owner()','execute'),'managed anonymous default function grant revoked');
select public.backend_state('reserve','{"account_id":"10000000-0000-4000-8000-000000000001"}');
set local role authenticated;
select pg_temp.assert(public.budget_refresh_usage()->>'reservedAttempts'='1','reserved usage counted');
select pg_temp.assert(public.budget_refresh_usage()->>'remainingAttempts'='49','remaining reduced');
select pg_temp.assert((public.budget_refresh_usage()->'accounts'->0->>'nextEligibleRefreshAt')::timestamptz=now()+interval '24 hours','24h cooldown');
reset role;
insert into private.refresh_usage(account_id) select '10000000-0000-4000-8000-000000000001' from generate_series(1,49);
set local role authenticated;
select pg_temp.assert(public.budget_refresh_usage()->>'remainingAttempts'='0','cap zero remaining');
select pg_temp.assert((public.budget_refresh_usage()->'accounts'->0->>'nextEligibleRefreshAt')::timestamptz>=((date_trunc('month',now() at time zone 'UTC')+interval '1 month') at time zone 'UTC'),'cap waits until UTC month');
reset role;
-- Historical reservation excluded even when server timezone differs from UTC.
set local timezone='Pacific/Auckland';
insert into private.refresh_usage(account_id,reserved_at) values('10000000-0000-4000-8000-000000000001',((date_trunc('month',now() at time zone 'UTC')) at time zone 'UTC')-interval '1 second');
set local role authenticated;
select pg_temp.assert(public.budget_refresh_usage()->>'reservedAttempts'='50','UTC month excludes older reservation');
reset role;
select public.backend_state('disconnect_request','{"account_id":"10000000-0000-4000-8000-000000000001","kind":"disconnect","dedupe_key":"disconnect:test"}');
select public.backend_state('claim');
select pg_temp.assert((select kind='disconnect' from private.jobs where status='processing'),'disconnect has priority');
do $$ begin
 begin perform public.backend_state('disconnected',jsonb_build_object('id',(select id from private.jobs where status='processing'),'lease_token',gen_random_uuid())); raise exception 'stale disconnect accepted'; exception when raise_exception then if sqlerrm<>'lease_lost' then raise; end if; end;
end $$;
select pg_temp.assert((select connection_state='disconnecting' from public.accounts),'stale disconnect cannot mutate');
select public.backend_state('disconnected',jsonb_build_object('id',(select id from private.jobs where status='processing'),'lease_token',(select lease_token from private.jobs where status='processing')));
select public.backend_state('finish',jsonb_build_object('id',(select id from private.jobs where status='processing'),'lease_token',(select lease_token from private.jobs where status='processing')));
select public.backend_state('claim');
do $$ begin
 begin perform public.backend_state('balance_snapshot',jsonb_build_object('id',(select id from private.jobs where status='processing'),'lease_token',gen_random_uuid(),'current_minor',100,'observed_at',now())); raise exception 'stale balance accepted'; exception when raise_exception then if sqlerrm<>'lease_lost' then raise; end if; end;
end $$;
select pg_temp.assert((select count(*)=0 from public.balance_snapshots),'stale balance cannot mutate');
rollback;
