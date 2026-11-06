create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

-- Provision explicitly using trusted SQL: insert into private.app_owner values ('AUTH_UUID');
-- No browser or application function can choose or replace the owner.
create table private.app_owner (owner_id uuid primary key references auth.users(id), singleton boolean not null default true unique check(singleton));
create function public.is_budget_owner() returns boolean language sql stable security definer set search_path = '' as $$
 select coalesce(auth.jwt()->>'aal' = 'aal2', false) and exists(select 1 from private.app_owner where owner_id = auth.uid())
$$;
revoke all on function public.is_budget_owner() from public;
grant execute on function public.is_budget_owner() to authenticated, service_role;

create table public.profiles (
 owner_id uuid primary key references private.app_owner(owner_id), currency text not null default 'USD' check(currency='USD'),
 reporting_timezone text not null default 'America/Denver' check(reporting_timezone='America/Denver')
);
create table public.accounts (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references private.app_owner(owner_id),
 source text not null check(source in ('manual','stripe')), name text not null check(length(name) between 1 and 120),
 institution text not null default '' check(length(institution)<=120), last_four text check(last_four ~ '^[0-9]{4}$'),
 kind text not null check(kind in ('cash','credit')), currency text not null default 'USD' check(currency='USD'),
 connection_state text not null default 'manual' check(connection_state in ('manual','active','disconnecting','disconnected','error')),
 last_synced_at timestamptz, sync_error text, created_at timestamptz not null default now(), unique(owner_id,id)
);
create table public.categories (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references private.app_owner(owner_id),
 name text not null check(length(name) between 1 and 80), kind text not null default 'expense' check(kind in ('expense','income')), unique(owner_id,id), unique(owner_id,name)
);
create table public.monthly_budgets (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references private.app_owner(owner_id), category_id uuid not null,
 month date not null check(extract(day from month)=1), amount_minor bigint not null check(amount_minor between 0 and 9000000000000),
 foreign key(owner_id,category_id) references public.categories(owner_id,id), unique(owner_id,category_id,month)
);
create table public.import_batches (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references private.app_owner(owner_id), account_id uuid not null,
 fingerprint text not null check(length(fingerprint)=64), mapping jsonb not null, inserted integer not null default 0,
 created_at timestamptz not null default now(), undone_at timestamptz,
 foreign key(owner_id,account_id) references public.accounts(owner_id,id) on delete cascade,
 unique(owner_id,account_id,fingerprint), unique(owner_id,id)
);
create table public.transactions (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references private.app_owner(owner_id), account_id uuid not null,
 source text not null check(source in ('csv','stripe')), source_id text not null check(length(source_id) between 1 and 200),
 amount_minor bigint not null check(abs(amount_minor)<=9000000000000), currency text not null default 'USD' check(currency='USD'),
 description text not null check(length(description)<=500), transaction_date date not null, posted_date date,
 status text not null check(status in ('pending','posted','void')), provider_updated bigint not null default 0,
 import_batch_id uuid, created_at timestamptz not null default now(),
 foreign key(owner_id,account_id) references public.accounts(owner_id,id) on delete cascade,
 foreign key(owner_id,import_batch_id) references public.import_batches(owner_id,id),
 unique(owner_id,account_id,source,source_id), unique(owner_id,id)
);
create index transactions_reporting on public.transactions(owner_id,posted_date,transaction_date);
create table public.transaction_annotations (
 transaction_id uuid primary key, owner_id uuid not null references private.app_owner(owner_id), category_id uuid,
 excluded_from_budget boolean not null default false, is_transfer boolean not null default false, is_card_payment boolean not null default false, note text check(length(note)<=1000), updated_at timestamptz not null default now(),
 foreign key(owner_id,transaction_id) references public.transactions(owner_id,id) on delete cascade,
 foreign key(owner_id,category_id) references public.categories(owner_id,id)
);
create table public.balance_snapshots (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references private.app_owner(owner_id), account_id uuid not null,
 current_minor bigint not null check(abs(current_minor)<=9000000000000), available_minor bigint check(abs(available_minor)<=9000000000000),
 observed_at timestamptz not null, source text not null check(source in ('manual','stripe')),
 foreign key(owner_id,account_id) references public.accounts(owner_id,id) on delete cascade,
 unique(account_id,observed_at,source)
);

do $$ declare t text; begin
 foreach t in array array['profiles','accounts','categories','monthly_budgets','import_batches','transactions','transaction_annotations','balance_snapshots'] loop
 execute format('alter table public.%I enable row level security',t);
 execute format('create policy owner_read on public.%I for select to authenticated using (owner_id=auth.uid() and public.is_budget_owner())',t);
 execute format('revoke all on public.%I from anon, authenticated',t);
 execute format('grant select on public.%I to authenticated',t);
 execute format('grant all on public.%I to service_role',t);
 end loop;
 foreach t in array array['profiles','categories','monthly_budgets','transaction_annotations'] loop
 execute format('grant insert, update, delete on public.%I to authenticated',t);
 execute format('create policy owner_write on public.%I for all to authenticated using (owner_id=auth.uid() and public.is_budget_owner()) with check (owner_id=auth.uid() and public.is_budget_owner())',t);
 end loop;
end $$;
grant insert,update on public.accounts to authenticated;
create policy manual_account_insert on public.accounts for insert to authenticated with check(owner_id=auth.uid() and public.is_budget_owner() and source='manual' and connection_state='manual' and last_synced_at is null and sync_error is null);
create policy manual_account_update on public.accounts for update to authenticated using(owner_id=auth.uid() and public.is_budget_owner() and source='manual') with check(owner_id=auth.uid() and public.is_budget_owner() and source='manual' and connection_state='manual' and last_synced_at is null and sync_error is null);
grant insert on public.balance_snapshots to authenticated;
create policy manual_balance_insert on public.balance_snapshots for insert to authenticated with check(owner_id=auth.uid() and public.is_budget_owner() and source='manual' and exists(select 1 from public.accounts a where a.id=account_id and a.source='manual'));

create table private.customers (owner_id uuid primary key references private.app_owner(owner_id), customer_id text not null unique, livemode boolean not null);
create table private.link_sessions (id text primary key, owner_id uuid not null references private.app_owner(owner_id), customer_id text not null, completed_at timestamptz, created_at timestamptz not null default now());
create table private.provider_accounts (account_id uuid primary key references public.accounts(id) on delete cascade, provider_id text not null unique, owner_id uuid not null references private.app_owner(owner_id), livemode boolean not null, subscribed boolean not null default false);
create table private.webhook_events (id text primary key, event_type text not null, received_at timestamptz not null default now());
create table private.jobs (
 id uuid primary key default gen_random_uuid(), account_id uuid not null references public.accounts(id) on delete cascade,
 kind text not null check(kind in ('sync','balance','disconnect')), dedupe_key text not null unique,
 status text not null default 'queued' check(status in ('queued','processing','done','failed')), cursor text,
 attempts integer not null default 0, available_at timestamptz not null default now(), lease_until timestamptz, lease_token uuid,
 created_at timestamptz not null default now(), error text, delete_local boolean not null default false
);
create table private.refresh_usage (request_id uuid primary key default gen_random_uuid(), account_id uuid references public.accounts(id) on delete set null, reserved_at timestamptz not null default now());
create table private.metrics (route text not null, method text not null, status integer not null, bucket text not null, count bigint not null default 0, primary key(route,method,status,bucket));

-- Narrow service-only gateway. private schema is never exposed through PostgREST.
create function public.backend_state(op text, payload jsonb default '{}') returns jsonb language plpgsql security definer set search_path = '' as $$
declare result jsonb; aid uuid; own uuid; jid uuid; token uuid; n integer; b public.import_batches; r jsonb; inserted_count integer:=0;
begin
 if op='owner' then return coalesce((select jsonb_build_object('owner_id',owner_id) from private.app_owner),'{}');
 elsif op='customer_get' then return coalesce((select to_jsonb(c) from private.customers c where owner_id=(payload->>'owner_id')::uuid),'{}');
 elsif op='customer_put' then
 insert into private.customers values ((payload->>'owner_id')::uuid,payload->>'customer_id',(payload->>'livemode')::boolean) on conflict(owner_id) do nothing;
 return (select to_jsonb(c) from private.customers c where owner_id=(payload->>'owner_id')::uuid);
 elsif op='session_put' then
 insert into private.link_sessions(id,owner_id,customer_id) values(payload->>'id',(payload->>'owner_id')::uuid,payload->>'customer_id') on conflict do nothing; return '{}';
 elsif op='session_get' then return coalesce((select to_jsonb(s) from private.link_sessions s where id=payload->>'id' and owner_id=(payload->>'owner_id')::uuid),'{}');
 elsif op='session_done' then update private.link_sessions set completed_at=now() where id=payload->>'id'; return '{}';
 elsif op='mapping' then return coalesce((select to_jsonb(p) from private.provider_accounts p where (payload->>'account_id' is not null and account_id=(payload->>'account_id')::uuid) or provider_id=payload->>'provider_id'),'{}');
 elsif op='map_account' then
 own:=(payload->>'owner_id')::uuid;
 perform pg_advisory_xact_lock(hashtextextended(payload->>'provider_id',0));
 select account_id into aid from private.provider_accounts where provider_id=payload->>'provider_id';
 if aid is null then
 insert into public.accounts(owner_id,source,name,institution,last_four,kind,connection_state) values(own,'stripe',payload->>'name',payload->>'institution',payload->>'last_four',payload->>'kind','active') returning id into aid;
 insert into private.provider_accounts values(aid,payload->>'provider_id',own,(payload->>'livemode')::boolean,false);
 end if;
 update public.accounts set connection_state='active' where id=aid;
 return (select to_jsonb(p) from private.provider_accounts p where account_id=aid);
 elsif op='subscribed' then update private.provider_accounts set subscribed=true where account_id=(payload->>'account_id')::uuid; return '{}';
 elsif op in ('enqueue','disconnect_request') then
 if op='disconnect_request' then update public.accounts set connection_state='disconnecting' where id=(payload->>'account_id')::uuid; end if;
 insert into private.jobs(account_id,kind,dedupe_key,delete_local) values((payload->>'account_id')::uuid,payload->>'kind',payload->>'dedupe_key',coalesce((payload->>'delete_local')::boolean,false)) on conflict(dedupe_key) do update set dedupe_key=excluded.dedupe_key returning id into jid;
 return jsonb_build_object('requestId',jid,'status','queued');
 elsif op='webhook' then
 insert into private.webhook_events(id,event_type) values(payload->>'id',payload->>'type') on conflict do nothing;
 get diagnostics n = row_count;
 if n=1 and payload->>'account_id' is not null then
 insert into private.jobs(account_id,kind,dedupe_key) values((payload->>'account_id')::uuid,payload->>'kind','event:'||(payload->>'id')) on conflict do nothing;
 end if; return jsonb_build_object('accepted',true);
 elsif op='reserve' then
 aid:=(payload->>'account_id')::uuid;
 perform pg_advisory_xact_lock(1793830636);
 if exists(select 1 from private.jobs where account_id=aid and status in ('queued','processing') and kind='disconnect') then raise exception 'disconnecting'; end if;
 if (select count(*) from private.refresh_usage where reserved_at>=date_trunc('month',now() at time zone 'UTC') at time zone 'UTC')>=50 then raise exception 'monthly_cap'; end if;
 if exists(select 1 from private.refresh_usage where account_id=aid and reserved_at>now()-interval '24 hours') then raise exception 'cooldown'; end if;
 insert into private.refresh_usage(account_id) values(aid) returning request_id into jid;
 insert into private.jobs(account_id,kind,dedupe_key) values(aid,'balance','refresh:'||jid::text);
 return jsonb_build_object('requestId',jid,'status','queued');
 elsif op='claim' then
 -- A global claim lock prevents simultaneous leases for the same account.
 perform pg_advisory_xact_lock(1793830637);
 update private.jobs set status=case when attempts>=8 then 'failed' else 'queued' end,lease_token=null,lease_until=null where status='processing' and lease_until<now();
 select j.id into jid from private.jobs j where j.status='queued' and available_at<=now() and attempts<8 and not exists(select 1 from private.jobs x where x.account_id=j.account_id and x.status='processing') order by j.created_at for update skip locked limit 1;
 if jid is null then return '{}'; end if;
 update private.jobs set status='processing',lease_until=now()+interval '90 seconds',lease_token=gen_random_uuid(),attempts=attempts+1 where id=jid returning to_jsonb(private.jobs.*) into result;
 return result;
 elsif op in ('page','finish','retry','yield') then
 jid:=(payload->>'id')::uuid; token:=(payload->>'lease_token')::uuid;
 select account_id into aid from private.jobs where id=jid and lease_token=token and status='processing' and lease_until>clock_timestamp() for update;
 if aid is null then raise exception 'lease_lost'; end if;
 if op='page' then
 select owner_id into own from public.accounts where id=aid for update;
 for r in select * from jsonb_array_elements(payload->'rows') loop
 if exists(select 1 from public.transactions where account_id=aid and source='csv' and transaction_date=(r->>'transaction_date')::date) then raise exception 'cross_source_overlap'; end if;
 insert into public.transactions(owner_id,account_id,source,source_id,amount_minor,description,transaction_date,posted_date,status,provider_updated)
 values(own,aid,'stripe',r->>'source_id',(r->>'amount_minor')::bigint,r->>'description',(r->>'transaction_date')::date,(r->>'posted_date')::date,r->>'status',(r->>'provider_updated')::bigint)
 on conflict(owner_id,account_id,source,source_id) do update set amount_minor=excluded.amount_minor,description=excluded.description,transaction_date=excluded.transaction_date,posted_date=excluded.posted_date,status=excluded.status,provider_updated=excluded.provider_updated where excluded.provider_updated>=public.transactions.provider_updated;
 end loop;
 update private.jobs set cursor=payload->>'cursor',lease_until=now()+interval '90 seconds' where id=jid;
 elsif op='yield' then
 update private.jobs set status='queued',available_at=now(),attempts=greatest(0,attempts-1),lease_until=null,lease_token=null where id=jid;
 elsif op='retry' then
 update private.jobs set status=case when attempts>=8 then 'failed' else 'queued' end, available_at=now()+make_interval(secs=>least(3600,30*power(2,attempts)::integer)),error='provider_unavailable',lease_until=null,lease_token=null where id=jid;
 update public.accounts set sync_error='provider_unavailable' where id=aid;
 else
 if exists(select 1 from private.jobs where id=jid and kind='disconnect' and delete_local) then
 delete from public.accounts where id=aid;
 else
 update private.jobs set status='done',lease_until=null,lease_token=null where id=jid;
 update public.accounts set last_synced_at=case when (select kind from private.jobs where id=jid)='sync' then now() else last_synced_at end,sync_error=null where id=aid;
 end if;
 end if; return '{}';
 elsif op='disconnected' then
 update public.accounts set connection_state='disconnected' where id=(payload->>'account_id')::uuid;
 update private.provider_accounts set subscribed=false where account_id=(payload->>'account_id')::uuid; return '{}';
 elsif op='import' then
 aid:=(payload->>'account_id')::uuid; own:=(payload->>'owner_id')::uuid;
 perform 1 from public.accounts where id=aid and owner_id=own for update;
 if not found then raise exception 'account_not_found'; end if;
 if jsonb_array_length(payload->'rows')>10000 then raise exception 'row_limit'; end if;
 if exists(select 1 from public.transactions t join jsonb_array_elements(payload->'rows') as item(value) on t.transaction_date=(item.value->>'transaction_date')::date where t.account_id=aid and t.source='stripe') then raise exception 'cross_source_overlap'; end if;
 select * into b from public.import_batches where account_id=aid and fingerprint=payload->>'fingerprint';
 if found then return jsonb_build_object('batchId',b.id,'inserted',0,'duplicates',jsonb_array_length(payload->'rows'),'undone',b.undone_at is not null); end if;
 insert into public.import_batches(owner_id,account_id,fingerprint,mapping) values(own,aid,payload->>'fingerprint',payload->'mapping') returning * into b;
 for r in select * from jsonb_array_elements(payload->'rows') loop
 insert into public.transactions(owner_id,account_id,source,source_id,amount_minor,description,transaction_date,posted_date,status,import_batch_id)
 values(own,aid,'csv',r->>'source_id',(r->>'amount_minor')::bigint,r->>'description',(r->>'transaction_date')::date,(r->>'transaction_date')::date,'posted',b.id) on conflict do nothing;
 get diagnostics n=row_count; inserted_count:=inserted_count+n;
 end loop;
 update public.import_batches set inserted=inserted_count where id=b.id;
 return jsonb_build_object('batchId',b.id,'inserted',inserted_count,'duplicates',jsonb_array_length(payload->'rows')-inserted_count);
 elsif op='undo' then
 select * into b from public.import_batches where id=(payload->>'id')::uuid and owner_id=(payload->>'owner_id')::uuid for update;
 if not found then raise exception 'batch_not_found'; end if;
 -- Keep annotated rows rather than deleting later user work.
 delete from public.transactions t where import_batch_id=b.id and source='csv' and not exists(select 1 from public.transaction_annotations a where a.transaction_id=t.id);
 get diagnostics n=row_count;
 update public.import_batches set undone_at=coalesce(undone_at,now()) where id=b.id;
 return jsonb_build_object('deleted',n,'retained',(select count(*) from public.transactions where import_batch_id=b.id));
 elsif op='metric' then
 insert into private.metrics values(payload->>'route',payload->>'method',(payload->>'status')::integer,payload->>'bucket',1) on conflict(route,method,status,bucket) do update set count=private.metrics.count+1; return '{}';
 elsif op='metrics' then return coalesce((select jsonb_agg(to_jsonb(m)) from private.metrics m),'[]');
 elsif op='recovery' then
 insert into private.jobs(account_id,kind,dedupe_key)
 select p.account_id,'sync','recovery:'||p.account_id::text||':'||to_char(now() at time zone 'UTC','YYYY-MM-DD') from private.provider_accounts p join public.accounts a on a.id=p.account_id where p.subscribed and a.connection_state='active' on conflict do nothing;
 return '{}';
 else raise exception 'unsupported_operation'; end if;
end $$;
revoke all on function public.backend_state(text,jsonb) from public,anon,authenticated;
grant execute on function public.backend_state(text,jsonb) to service_role;

create view public.monthly_actuals with (security_invoker=true) as
 select t.owner_id,date_trunc('month',coalesce(t.posted_date,t.transaction_date))::date as month,a.category_id,
 sum(case when c.kind='expense' then -t.amount_minor when c.kind is null and t.amount_minor<0 then -t.amount_minor else 0 end) spending_minor,
 sum(case when c.kind='income' then t.amount_minor when c.kind is null and t.amount_minor>0 then t.amount_minor else 0 end) income_minor,
 -sum(t.amount_minor) net_spending_minor
 from public.transactions t left join public.transaction_annotations a on a.transaction_id=t.id left join public.categories c on c.id=a.category_id
 where t.status='posted' and not (coalesce(a.excluded_from_budget,false) or coalesce(a.is_transfer,false) or coalesce(a.is_card_payment,false))
 group by t.owner_id,date_trunc('month',coalesce(t.posted_date,t.transaction_date))::date,a.category_id;
grant select on public.monthly_actuals to authenticated;

create function private.initialize_owner() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into public.profiles(owner_id) values(new.owner_id);
 insert into public.categories(owner_id,name,kind) values
 (new.owner_id,'Uncategorized','expense'),(new.owner_id,'Food','expense'),(new.owner_id,'Housing','expense'),
 (new.owner_id,'Transport','expense'),(new.owner_id,'Utilities','expense'),(new.owner_id,'Health','expense'),
 (new.owner_id,'Shopping','expense'),(new.owner_id,'Entertainment','expense'),(new.owner_id,'Income','income');
 return new;
end $$;
create trigger initialize_owner after insert on private.app_owner for each row execute function private.initialize_owner();
