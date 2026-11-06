-- Forward-only correction: preserve the original migration for existing installations.
alter function public.backend_state(text,jsonb) set schema private;
alter function private.backend_state(text,jsonb) rename to backend_state_legacy;
revoke all on all tables in schema private from public, anon, authenticated, service_role;
revoke all on all functions in schema private from public, anon, authenticated, service_role;
alter default privileges in schema private revoke all on tables from public, anon, authenticated, service_role;
alter default privileges in schema private revoke execute on functions from public, anon, authenticated, service_role;
-- Managed Supabase default ACLs can grant anon directly, not just through PUBLIC.
revoke all on function public.is_budget_owner() from public, anon;
grant execute on function public.is_budget_owner() to authenticated, service_role;
alter table private.jobs add column paid_started boolean not null default false;

create function public.budget_refresh_usage() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare month_start timestamptz:=date_trunc('month',now() at time zone 'UTC') at time zone 'UTC'; used integer; account_usage jsonb;
begin
 if not public.is_budget_owner() then raise insufficient_privilege using message='owner_mfa_required'; end if;
 select count(*) into used from private.refresh_usage where reserved_at>=month_start;
 select coalesce(jsonb_agg(jsonb_build_object('accountId',a.id,'nextEligibleRefreshAt',
 case when used>=50 then greatest((month_start at time zone 'UTC'+interval '1 month') at time zone 'UTC',a.last_reserved+interval '24 hours')
 when a.last_reserved+interval '24 hours'>now() then a.last_reserved+interval '24 hours' else null end) order by a.id),'[]'::jsonb)
 into account_usage from (select a.id,max(u.reserved_at) last_reserved from public.accounts a left join private.refresh_usage u on u.account_id=a.id where a.owner_id=auth.uid() and a.source='stripe' group by a.id) a;
 return jsonb_build_object('month',to_char(month_start at time zone 'UTC','YYYY-MM'), 'reservedAttempts',used,'limit',50,'remainingAttempts',greatest(0,50-used),'accounts',account_usage);
end $$;
revoke all on function public.budget_refresh_usage() from public,anon,service_role;
grant execute on function public.budget_refresh_usage() to authenticated;

create function public.backend_state(op text,payload jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare jid uuid; aid uuid; job private.jobs; result jsonb;
begin
 if op='claim' then
 perform pg_advisory_xact_lock(1793830637);
 update public.accounts a set sync_error='retry_exhausted' where exists(select 1 from private.jobs j where j.account_id=a.id and j.status='processing' and j.lease_until<clock_timestamp() and j.attempts>=8);
 update private.jobs set status=case when attempts>=8 then 'failed' else 'queued' end,lease_token=null,lease_until=null where status='processing' and lease_until<clock_timestamp();
 select j.id into jid from private.jobs j where j.status='queued' and j.available_at<=clock_timestamp() and j.attempts<8 and not exists(select 1 from private.jobs x where x.account_id=j.account_id and x.status='processing') order by (j.kind='disconnect') desc,j.created_at,j.id for update skip locked limit 1;
 if jid is null then return '{}'; end if;
 update private.jobs set status='processing',lease_until=clock_timestamp()+interval '90 seconds',lease_token=gen_random_uuid(),attempts=attempts+1 where id=jid returning to_jsonb(private.jobs.*) into result;
 return result;
 elsif op in ('disconnected','balance_started','balance_snapshot','finish') then
 select * into job from private.jobs where id=(payload->>'id')::uuid and lease_token=(payload->>'lease_token')::uuid and status='processing' and lease_until>clock_timestamp() for update;
 if not found then raise exception 'lease_lost'; end if;
 aid:=job.account_id;
 if op='balance_started' then
 if job.kind<>'balance' or job.dedupe_key not like 'refresh:%' then raise exception 'invalid_job'; end if;
 update private.jobs set paid_started=true where id=job.id;
 elsif op='disconnected' then
 if job.kind<>'disconnect' then raise exception 'invalid_job'; end if;
 update public.accounts set connection_state='disconnected' where id=aid;
 update private.provider_accounts set subscribed=false where account_id=aid;
 elsif op='balance_snapshot' then
 if job.kind<>'balance' then raise exception 'invalid_job'; end if;
 insert into public.balance_snapshots(owner_id,account_id,source,current_minor,available_minor,observed_at)
 select owner_id,id,'stripe',(payload->>'current_minor')::bigint,(payload->>'available_minor')::bigint,(payload->>'observed_at')::timestamptz from public.accounts where id=aid and connection_state='active'
 on conflict(account_id,observed_at,source) do update set current_minor=excluded.current_minor,available_minor=excluded.available_minor;
 else
 if job.kind='disconnect' and job.delete_local then delete from public.accounts where id=aid;
 else
 update private.jobs set status='done',lease_until=null,lease_token=null,error=null where id=job.id;
 -- A skipped sync after disconnect must not claim a successful refresh or erase its error.
 update public.accounts set last_synced_at=case when job.kind='sync' then clock_timestamp() else last_synced_at end,sync_error=null where id=aid and connection_state='active';
 end if;
 end if; return '{}';
 else return private.backend_state_legacy(op,payload);
 end if;
end $$;
revoke all on function public.backend_state(text,jsonb) from public,anon,authenticated;
grant execute on function public.backend_state(text,jsonb) to service_role;
