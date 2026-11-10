-- Preserve the lifecycle wrappers and deployed migrations; replace only reservation policy.
alter function private.backend_state_legacy(text,jsonb) rename to backend_state_before_refresh_cooldown_removal;
revoke all on function private.backend_state_before_refresh_cooldown_removal(text,jsonb) from public,anon,authenticated,service_role;

create function private.backend_state_legacy(op text,payload jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare aid uuid; jid uuid;
begin
 if op='reserve' then
  aid:=(payload->>'account_id')::uuid;
  perform pg_advisory_xact_lock(1793830636);
  if exists(select 1 from private.jobs where account_id=aid and status in ('queued','processing') and kind='disconnect') then raise exception 'disconnecting'; end if;
  if (select count(*) from private.refresh_usage where reserved_at>=date_trunc('month',now() at time zone 'UTC') at time zone 'UTC')>=50 then raise exception 'monthly_cap'; end if;
  insert into private.refresh_usage(account_id) values(aid) returning request_id into jid;
  insert into private.jobs(account_id,kind,dedupe_key) values(aid,'balance','refresh:'||jid::text);
  return jsonb_build_object('requestId',jid,'status','queued');
 end if;
 return private.backend_state_before_refresh_cooldown_removal(op,payload);
end $$;
revoke all on function private.backend_state_legacy(text,jsonb) from public,anon,authenticated,service_role;

create or replace function public.budget_refresh_usage() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare month_start timestamptz:=date_trunc('month',now() at time zone 'UTC') at time zone 'UTC'; used integer; account_usage jsonb;
begin
 if not public.is_budget_owner() then raise insufficient_privilege using message='owner_mfa_required'; end if;
 select count(*) into used from private.refresh_usage where reserved_at>=month_start;
 select coalesce(jsonb_agg(jsonb_build_object('accountId',a.id,'nextEligibleRefreshAt',
  case when used>=50 then (month_start at time zone 'UTC'+interval '1 month') at time zone 'UTC' else null end) order by a.id),'[]'::jsonb)
  into account_usage from public.accounts a where a.owner_id=auth.uid() and a.source='stripe';
 return jsonb_build_object('month',to_char(month_start at time zone 'UTC','YYYY-MM'), 'reservedAttempts',used,'limit',50,'remainingAttempts',greatest(0,50-used),'accounts',account_usage);
end $$;
revoke all on function public.budget_refresh_usage() from public,anon,service_role;
grant execute on function public.budget_refresh_usage() to authenticated;
