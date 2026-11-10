-- Forward-only lifecycle state; provider calls remain outside database transactions.
alter table private.link_sessions add column completion_result jsonb,
 add column claim_token uuid, add column claim_until timestamptz;
-- Old completions did not retain selected IDs; never replay their provider writes.
update private.link_sessions set completion_result='{"accountIds":[],"status":"queued"}' where completed_at is not null;
alter table private.provider_accounts add column subscription_intent boolean not null default false,
 add column disconnect_requested_at timestamptz;
update private.provider_accounts p set subscription_intent=p.subscribed,
 disconnect_requested_at=case when a.connection_state in ('disconnecting','disconnected') then now() end
 from public.accounts a where a.id=p.account_id;
-- Independent of local account history so deletion cannot remove the replay fence.
create table private.disconnected_provider_accounts (
 provider_id text primary key, disconnected_at timestamptz not null default now()
);
revoke all on private.disconnected_provider_accounts from public,anon,authenticated,service_role;
insert into private.disconnected_provider_accounts(provider_id) select provider_id from private.provider_accounts where disconnect_requested_at is not null;
alter table private.jobs drop constraint jobs_kind_check;
alter table private.jobs add constraint jobs_kind_check check(kind in ('sync','balance','disconnect','subscribe','lifecycle'));
alter table private.jobs add column balance_baseline bigint, add column balance_dispatch_at timestamptz;
alter function public.backend_state(text,jsonb) set schema private;
alter function private.backend_state(text,jsonb) rename to backend_state_before_linking;
revoke all on function private.backend_state_before_linking(text,jsonb) from public,anon,authenticated,service_role;

create function public.backend_state(op text,payload jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; session private.link_sessions; job private.jobs; account public.accounts;
 mapping private.provider_accounts; item jsonb; ids jsonb:='[]'; aid uuid; jid uuid; own uuid;
 code text; state text;
begin
 if op='session_claim' then
  select * into session from private.link_sessions where id=payload->>'id' and owner_id=(payload->>'owner_id')::uuid for update;
  if not found then raise exception 'session_not_found'; end if;
  if session.completion_result is not null then return to_jsonb(session); end if;
  if session.claim_until>clock_timestamp() then raise exception 'session_busy'; end if;
  update private.link_sessions set claim_token=gen_random_uuid(),claim_until=clock_timestamp()+interval '90 seconds'
   where id=session.id returning * into session;
  return to_jsonb(session);
 elsif op in ('session_renew','session_release') then
  select * into session from private.link_sessions where id=payload->>'id' and owner_id=(payload->>'owner_id')::uuid for update;
  if not found then raise exception 'session_not_found'; end if;
  if session.completion_result is not null then return '{}'; end if;
  if session.claim_token is null or session.claim_token is distinct from (payload->>'claim_token')::uuid then raise exception 'lease_lost'; end if;
  if op='session_renew' then
   if session.claim_until<=clock_timestamp() then raise exception 'lease_lost'; end if;
   update private.link_sessions set claim_until=clock_timestamp()+interval '90 seconds' where id=session.id;
  else
   update private.link_sessions set claim_token=null,claim_until=null where id=session.id;
  end if;
  return '{}';
 elsif op='session_pending' then
  return jsonb_build_object('sessions',coalesce((select jsonb_agg(jsonb_build_object('sessionId',s.id,'createdAt',s.created_at,
   'status',case when s.claim_until>clock_timestamp() then 'processing' else 'pending' end) order by s.created_at,s.id)
   from private.link_sessions s where s.owner_id=(payload->>'owner_id')::uuid and s.completion_result is null),'[]'::jsonb));
 elsif op='session_accept' then
  select * into session from private.link_sessions where id=payload->>'id' and owner_id=(payload->>'owner_id')::uuid for update;
  if not found then raise exception 'session_not_found'; end if;
  if session.completion_result is not null then return session.completion_result; end if;
  if session.claim_token is distinct from (payload->>'claim_token')::uuid or session.claim_token is null or session.claim_until<=clock_timestamp() then raise exception 'lease_lost'; end if;
  if jsonb_typeof(payload->'accounts') is distinct from 'array' then raise exception 'no_selected_accounts'; end if;
  if jsonb_array_length(payload->'accounts')=0 then raise exception 'no_selected_accounts'; end if;
  if not exists(select 1 from private.customers c where c.owner_id=session.owner_id and c.customer_id=session.customer_id) then raise exception 'customer_mismatch'; end if;
  -- Deterministic ordering also serializes overlapping sessions with multiple selections.
  for item in select value from jsonb_array_elements(payload->'accounts') order by value->>'provider_id' loop
   if coalesce(item->>'provider_id','')='' or not exists(select 1 from private.customers c where c.owner_id=session.owner_id and c.livemode=(item->>'livemode')::boolean) then raise exception 'account_mismatch'; end if;
   result:=public.backend_state('map_account',item||jsonb_build_object('owner_id',session.owner_id));
   aid:=(result->>'account_id')::uuid;
   if not ids @> jsonb_build_array(aid) then ids:=ids||jsonb_build_array(aid); end if;
   select * into mapping from private.provider_accounts where account_id=aid;
   if mapping.disconnect_requested_at is not null then raise exception 'disconnecting'; end if;
   update private.provider_accounts set subscription_intent=true where account_id=aid;
   update public.accounts set sync_error='subscription_pending' where id=aid and not mapping.subscribed;
   insert into private.jobs(account_id,kind,dedupe_key) values(aid,'subscribe','subscribe:'||aid::text) on conflict do nothing;
  end loop;
  result:=jsonb_build_object('accountIds',ids,'status','queued');
  update private.link_sessions set completed_at=clock_timestamp(),completion_result=result,claim_token=null,claim_until=null where id=session.id;
  return result;
 elsif op='claim' then
  perform pg_advisory_xact_lock(1793830637);
  update public.accounts a set sync_error=case when a.sync_error in ('balance_not_ready','transactions_not_ready','subscription_pending') then a.sync_error else 'retry_exhausted' end
   where exists(select 1 from private.jobs j where j.account_id=a.id and j.status='processing' and j.lease_until<clock_timestamp() and j.attempts>=8);
  update private.jobs set status=case when attempts>=8 then 'failed' else 'queued' end,lease_token=null,lease_until=null where status='processing' and lease_until<clock_timestamp();
  -- Expired provider writes remain serialized until the lease ends, then cleanup wins.
  update private.jobs j set status='done',error='disconnecting' where j.status='queued' and j.kind in ('subscribe','sync','balance')
   and exists(select 1 from public.accounts a left join private.provider_accounts p on p.account_id=a.id where a.id=j.account_id and (p.disconnect_requested_at is not null or a.connection_state in ('disconnecting','disconnected')));
  select j.id into jid from private.jobs j where j.status='queued' and j.available_at<=clock_timestamp() and j.attempts<8
   and not exists(select 1 from private.jobs x where x.account_id=j.account_id and x.status='processing')
   order by (j.kind='disconnect') desc,j.created_at,j.id for update skip locked limit 1;
  if jid is null then return '{}'; end if;
  update private.jobs set status='processing',lease_until=clock_timestamp()+interval '90 seconds',lease_token=gen_random_uuid(),attempts=attempts+1 where id=jid returning to_jsonb(private.jobs.*) into result;
  return result;
 elsif op='mapping' then
  return coalesce((select to_jsonb(p)||jsonb_build_object('customer_id',c.customer_id) from private.provider_accounts p
   join private.customers c on c.owner_id=p.owner_id where
   (payload->>'account_id' is not null and p.account_id=(payload->>'account_id')::uuid) or p.provider_id=payload->>'provider_id'),'{}');
 elsif op='map_account' then
  own:=(payload->>'owner_id')::uuid;
  perform pg_advisory_xact_lock(hashtextextended(payload->>'provider_id',0));
  if exists(select 1 from private.disconnected_provider_accounts where provider_id=payload->>'provider_id') then raise exception 'disconnecting'; end if;
  select * into mapping from private.provider_accounts where provider_id=payload->>'provider_id';
  if found then
   select * into account from public.accounts where id=mapping.account_id for update;
   if not found then raise exception 'disconnecting'; end if;
   if mapping.owner_id<>own or mapping.livemode is distinct from (payload->>'livemode')::boolean then raise exception 'account_mismatch'; end if;
   if mapping.disconnect_requested_at is not null or account.connection_state in ('disconnecting','disconnected') then raise exception 'disconnecting'; end if;
   aid:=mapping.account_id;
   else
    -- Cleanup may commit between the first tombstone read and mapping lookup.
    if exists(select 1 from private.disconnected_provider_accounts where provider_id=payload->>'provider_id') then raise exception 'disconnecting'; end if;
    insert into public.accounts(owner_id,source,name,institution,last_four,kind,connection_state)
    values(own,'stripe',payload->>'name',payload->>'institution',payload->>'last_four',payload->>'kind','active') returning id into aid;
   insert into private.provider_accounts(account_id,provider_id,owner_id,livemode) values(aid,payload->>'provider_id',own,(payload->>'livemode')::boolean);
  end if;
  return public.backend_state('mapping',jsonb_build_object('account_id',aid));
 elsif op='subscription_retry' then
  aid:=(payload->>'account_id')::uuid;
  select * into account from public.accounts where id=aid for update;
  if not found then raise exception 'account_not_found'; end if;
  select * into mapping from private.provider_accounts where account_id=aid;
  if mapping.disconnect_requested_at is not null or account.connection_state in ('disconnecting','disconnected') then raise exception 'disconnecting'; end if;
  if not coalesce(mapping.subscription_intent,false) then raise exception 'subscription_not_retryable'; end if;
  select * into job from private.jobs where account_id=aid and kind='subscribe' and dedupe_key='subscribe:'||aid::text for update;
  if not found or job.status='done' then raise exception 'subscription_not_retryable'; end if;
  if job.status='failed' then
   update private.jobs set status='queued',attempts=0,available_at=clock_timestamp(),error=null,lease_token=null,lease_until=null where id=job.id;
   update public.accounts set sync_error='subscription_pending' where id=aid;
  end if;
  return jsonb_build_object('requestId',job.id,'status','queued');
 elsif op='disconnect_request' then
  aid:=(payload->>'account_id')::uuid;
  select * into account from public.accounts where id=aid for update;
  if not found then raise exception 'account_not_found'; end if;
  update private.provider_accounts set disconnect_requested_at=coalesce(disconnect_requested_at,clock_timestamp()),subscription_intent=false where account_id=aid;
  insert into private.disconnected_provider_accounts(provider_id) select provider_id from private.provider_accounts where account_id=aid on conflict do nothing;
  update public.accounts set connection_state='disconnecting' where id=aid;
  update private.jobs set status='done',error='disconnecting',lease_token=null,lease_until=null
   where account_id=aid and status='queued' and kind in ('subscribe','sync','balance');
  insert into private.jobs(account_id,kind,dedupe_key,delete_local)
   values(aid,'disconnect',payload->>'dedupe_key',coalesce((payload->>'delete_local')::boolean,false))
   on conflict(dedupe_key) do update set delete_local=private.jobs.delete_local or excluded.delete_local returning id into jid;
  return jsonb_build_object('requestId',jid,'status','queued');
 elsif op in ('job_renew','page','balance_started','balance_snapshot','subscribe_started','subscribe_finish','lifecycle','disconnected','finish','retry','yield') then
  -- All worker mutations take the same row lock as disconnect before the job lock.
  select account_id into aid from private.jobs where id=(payload->>'id')::uuid;
  select * into account from public.accounts where id=aid for update;
  select * into job from private.jobs where id=(payload->>'id')::uuid and lease_token=(payload->>'lease_token')::uuid
   and status='processing' and lease_until>clock_timestamp() for update;
  if not found then raise exception 'lease_lost'; end if;
  select * into mapping from private.provider_accounts where account_id=aid;
  if op in ('page','balance_started','balance_snapshot','subscribe_started','subscribe_finish') and
   (mapping.disconnect_requested_at is not null or account.connection_state in ('disconnecting','disconnected')) then raise exception 'disconnecting'; end if;
  if op='page' and job.kind<>'sync' then raise exception 'invalid_job'; end if;
  -- These leased writes follow authoritative provider validation in the worker.
   if op in ('page','balance_snapshot') and account.connection_state='error' then
    update public.accounts set connection_state='active',sync_error=case when sync_error='connection_inactive' then null else sync_error end where id=aid;
  end if;
  if op='job_renew' then
   if job.kind in ('subscribe','sync','balance') and (mapping.disconnect_requested_at is not null or account.connection_state in ('disconnecting','disconnected')) then raise exception 'disconnecting'; end if;
   update private.jobs set lease_until=clock_timestamp()+interval '90 seconds' where id=job.id;
   return '{}';
  elsif op='subscribe_started' then
   if job.kind<>'subscribe' or not coalesce(mapping.subscription_intent,false) then raise exception 'invalid_job'; end if;
   update private.jobs set lease_until=clock_timestamp()+interval '90 seconds' where id=job.id;
   return '{}';
  elsif op='balance_started' then
   if job.kind<>'balance' or job.dedupe_key not like 'refresh:%' then raise exception 'invalid_job'; end if;
   update private.jobs set paid_started=true,lease_until=clock_timestamp()+interval '90 seconds',
    balance_baseline=case when not paid_started then (payload->>'baseline_as_of')::bigint else balance_baseline end,
    balance_dispatch_at=case when not paid_started then clock_timestamp() else balance_dispatch_at end where id=job.id;
   return '{}';
  elsif op='subscribe_finish' then
   if job.kind<>'subscribe' or not coalesce(mapping.subscription_intent,false) then raise exception 'invalid_job'; end if;
   update private.provider_accounts set subscribed=true where account_id=aid;
   update public.accounts set connection_state='active',sync_error='transactions_not_ready' where id=aid;
   insert into private.jobs(account_id,kind,dedupe_key) values(aid,'sync','initial:'||aid::text) on conflict do nothing;
   update private.jobs set status='done',error=null,lease_token=null,lease_until=null where id=job.id;
   return '{}';
  elsif op='lifecycle' then
   if job.kind<>'lifecycle' then raise exception 'invalid_job'; end if;
   state:=payload->>'provider_status';
   if state is null or state not in ('active','inactive','disconnected') then raise exception 'invalid_provider_status'; end if;
   if mapping.disconnect_requested_at is null and account.connection_state not in ('disconnecting','disconnected') then
    update public.accounts set connection_state=case state when 'active' then 'active' when 'inactive' then 'error' else 'disconnected' end,
     sync_error=case when state='inactive' then 'connection_inactive' when state='disconnected' then null
      when sync_error='connection_inactive' then
       case when not mapping.subscribed and mapping.subscription_intent then 'subscription_pending'
        when last_synced_at is null then 'transactions_not_ready' else null end
      else sync_error end where id=aid;
    if state='disconnected' then
     insert into private.disconnected_provider_accounts(provider_id) values(mapping.provider_id) on conflict do nothing;
     update private.provider_accounts set subscribed=false,subscription_intent=false,disconnect_requested_at=clock_timestamp() where account_id=aid;
     update private.jobs set status='done',error='account_disconnected' where account_id=aid and status='queued' and kind in ('sync','subscribe','balance');
    end if;
   end if;
   update private.jobs set status='done',error=null,lease_token=null,lease_until=null where id=job.id;
   return '{}';
  elsif op='retry' then
   code:=coalesce(payload->>'error',payload->>'code','provider_unavailable');
   if code not in ('provider_unavailable','provider_timeout','provider_rate_limited','provider_rejected','provider_pending','account_inactive','account_disconnected','account_mismatch','permissions_missing','unsupported_account','unsupported_currency','balance_unavailable','refresh_failed','disconnecting','lease_lost','cross_source_overlap','subscription_pending','subscription_failed','transactions_not_ready','transactions_failed','balance_not_ready','balance_failed','invalid_balance','connection_inactive','refresh_expired','provider_cooldown','retry_exhausted','mapping_mismatch','invalid_provider_page','transaction_mismatch','mode_mismatch') then code:='provider_unavailable'; end if;
   if mapping.disconnect_requested_at is not null and job.kind in ('sync','subscribe','balance') then
    update private.jobs set status='done',error='disconnecting',lease_token=null,lease_until=null where id=job.id;
   else
    update private.jobs set status=case when attempts>=8 then 'failed' else 'queued' end,
     available_at=clock_timestamp()+make_interval(secs=>least(3600,30*power(2,attempts)::integer)),error=code,lease_token=null,lease_until=null where id=job.id;
    update public.accounts set sync_error=case when job.attempts>=8 and code not in ('balance_not_ready','transactions_not_ready','subscription_pending','balance_unavailable','invalid_balance','balance_failed','transactions_failed') then 'retry_exhausted' else code end,
     connection_state=case when code in ('connection_inactive','permissions_missing','account_inactive') and connection_state='active' then 'error' else connection_state end where id=aid;
   end if;
   return '{}';
  elsif op='finish' and job.kind in ('subscribe','lifecycle') then
   -- A skipped job may finish, but cannot publish subscription or lifecycle success.
   update private.jobs set status='done',lease_token=null,lease_until=null where id=job.id;
   return '{}';
  elsif op='finish' and job.kind='sync' and account.connection_state<>'active' then
   update private.jobs set status='done',lease_token=null,lease_until=null where id=job.id;
   return '{}';
  elsif op='finish' and job.kind in ('sync','balance') then
   update private.jobs set status='done',error=null,lease_token=null,lease_until=null where id=job.id;
   update public.accounts a set last_synced_at=case when job.kind='sync' then clock_timestamp() else a.last_synced_at end,
    sync_error=case
     when job.kind='sync' and (a.sync_error like 'balance_%' or a.sync_error='invalid_balance') then a.sync_error
     when job.kind='balance' and a.sync_error in ('transactions_not_ready','transactions_failed','subscription_pending','subscription_failed') then a.sync_error
     when a.sync_error in ('connection_inactive','subscription_pending','subscription_failed') then a.sync_error
     when exists(select 1 from private.jobs j where j.account_id=aid and j.id<>job.id and j.kind<>job.kind and j.status in ('queued','processing','failed') and (j.error=a.sync_error or a.sync_error='retry_exhausted' and j.attempts>=8)) then a.sync_error
     else null end
    where a.id=aid and a.connection_state='active';
   return '{}';
  elsif op='disconnected' then
   if job.kind<>'disconnect' then raise exception 'invalid_job'; end if;
   insert into private.disconnected_provider_accounts(provider_id) select provider_id from private.provider_accounts where account_id=aid on conflict do nothing;
   update private.provider_accounts set subscription_intent=false,disconnect_requested_at=coalesce(disconnect_requested_at,clock_timestamp()) where account_id=aid;
  end if;
   return private.backend_state_before_linking(op,payload);
 elsif op in ('reserve','enqueue','subscribed') then
  aid:=(payload->>'account_id')::uuid;
  select * into account from public.accounts where id=aid for update;
  select * into mapping from private.provider_accounts where account_id=aid;
  if mapping.disconnect_requested_at is not null or account.connection_state in ('disconnecting','disconnected') then raise exception 'disconnecting'; end if;
  if op='reserve' and account.source='stripe' and account.connection_state<>'active' then raise exception 'account_inactive'; end if;
  if op='subscribed' then raise exception 'lease_required'; end if;
  result:=private.backend_state_before_linking(op,payload);
  if op='reserve' and account.source='stripe' and coalesce(account.sync_error,'') not in ('subscription_pending','subscription_failed','connection_inactive') then
   update public.accounts set sync_error='balance_not_ready' where id=aid;
  end if;
  return result;
 else
  return private.backend_state_before_linking(op,payload);
 end if;
end $$;
revoke all on function public.backend_state(text,jsonb) from public,anon,authenticated;
grant execute on function public.backend_state(text,jsonb) to service_role;
