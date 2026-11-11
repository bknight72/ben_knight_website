-- Keep the original revisioned editing implementation behind the public RPC.
-- The wrapper shares its owner lock so exclusions and edits commit atomically.
create table public.budgeteer_source_exclusions (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null, month date not null,
 source_transaction_id uuid not null,
 foreign key(owner_id,month) references public.budgeteer_plans(owner_id,month) on delete cascade,
 foreign key(owner_id,source_transaction_id) references public.transactions(owner_id,id) on delete cascade,
 unique(owner_id,month,source_transaction_id)
);
create index budgeteer_source_exclusions_source on public.budgeteer_source_exclusions(source_transaction_id);
alter table public.budgeteer_source_exclusions enable row level security;
create policy owner_read on public.budgeteer_source_exclusions for select to authenticated
 using(owner_id=auth.uid() and public.is_budget_owner());
revoke all on public.budgeteer_source_exclusions from public,anon,authenticated;
grant select on public.budgeteer_source_exclusions to authenticated;
grant all on public.budgeteer_source_exclusions to service_role;

create or replace function private.budgeteer_source_deleted() returns trigger language plpgsql security definer set search_path='' as $$
begin
 update public.budgeteer_plans set revision=revision+1,updated_at=clock_timestamp()
 where id in (select plan_id from public.budgeteer_entries where source_transaction_id=old.id)
 or (owner_id,month) in (select owner_id,month from public.budgeteer_source_exclusions where source_transaction_id=old.id);
 return old;
end $$;

create or replace function public.budgeteer_read(p_month date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare own uuid:=auth.uid(); pid uuid; result jsonb;
begin
 if not public.is_budget_owner() then raise exception 'owner_mfa_required' using errcode='42501'; end if;
 if p_month is null or extract(day from p_month)<>1 then raise exception 'budgeteer_invalid_month'; end if;
 select id into pid from public.budgeteer_plans where owner_id=own and month=p_month;
 select jsonb_build_object(
  'plan',(select to_jsonb(p) from public.budgeteer_plans p where p.id=pid),
  'groups',coalesce((select jsonb_agg(to_jsonb(g) order by sort_position,id) from public.budgeteer_groups g where plan_id=pid),'[]'::jsonb),
  'entries',coalesce((select jsonb_agg(to_jsonb(e)||jsonb_build_object('source_current',to_jsonb(t),'source_state',
    case when e.source_transaction_id is null then case when e.source_snapshot is null then 'manual' else 'unavailable' end
    when to_jsonb(t)=e.source_snapshot then 'linked' else 'changed' end)
    order by case when e.kind='deposit' then 0 else 1 end,coalesce(g.sort_position,9223372036854775807),e.sort_position,e.id)
    from public.budgeteer_entries e left join public.transactions t on t.id=e.source_transaction_id and t.owner_id=own
    left join public.budgeteer_groups g on g.id=e.group_id where e.plan_id=pid),'[]'::jsonb),
  'labels',coalesce((select jsonb_agg(to_jsonb(l) order by name,id) from public.budgeteer_labels l where owner_id=own),'[]'::jsonb),
  'entry_labels',coalesce((select jsonb_agg(to_jsonb(el) order by entry_id,label_id) from public.budgeteer_entry_labels el
    join public.budgeteer_entries e on e.id=el.entry_id where e.plan_id=pid),'[]'::jsonb),
  'excluded_source_count',(select count(*) from public.budgeteer_source_exclusions where owner_id=own and month=p_month)) into result;
 return result;
end $$;

alter function public.budgeteer_mutate(date,bigint,text,jsonb) set schema private;
alter function private.budgeteer_mutate(date,bigint,text,jsonb) rename to budgeteer_mutate_existing;
revoke all on function private.budgeteer_mutate_existing(date,bigint,text,jsonb) from public,anon,authenticated;

create function public.budgeteer_mutate(p_month date,p_revision bigint,p_operation text,p_payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare own uuid:=auth.uid(); p public.budgeteer_plans; sid uuid; source_row public.transactions;
 pos bigint; changed boolean:=false; n integer; result jsonb;
begin
 if not public.is_budget_owner() then raise exception 'owner_mfa_required' using errcode='42501'; end if;
 if p_month is null or extract(day from p_month)<>1 then raise exception 'budgeteer_invalid_month'; end if;
 if p_revision is null or p_revision<0 or jsonb_typeof(p_payload) is distinct from 'object' then raise exception 'budgeteer_invalid_payload'; end if;
 perform pg_advisory_xact_lock(hashtextextended('budgeteer:'||own::text,0));
 select * into p from public.budgeteer_plans where owner_id=own and month=p_month for update;
 if coalesce(p.revision,0)<>p_revision then raise exception 'budgeteer_conflict' using errcode='P0001'; end if;
 if p_operation in ('sources_include','sources_restore') then
  if p_payload<>'{}'::jsonb then raise exception 'budgeteer_invalid_payload'; end if;
  if p_operation='sources_restore' then
   delete from public.budgeteer_source_exclusions where owner_id=own and month=p_month;
   get diagnostics n=row_count;
   changed:=n>0;
  end if;
  select coalesce(max(sort_position)+1,0) into pos from public.budgeteer_entries where plan_id=p.id;
  for source_row in
   select t.* from public.transactions t
   where t.owner_id=own and t.status='posted' and t.amount_minor<>0
    and coalesce(t.posted_date,t.transaction_date)>=p_month
    and coalesce(t.posted_date,t.transaction_date)<(p_month+interval '1 month')::date
    and not exists(select 1 from public.budgeteer_entries e where e.plan_id=p.id and e.source_transaction_id=t.id)
    and not exists(select 1 from public.budgeteer_source_exclusions x where x.owner_id=own and x.month=p_month and x.source_transaction_id=t.id)
    and not exists(select 1 from public.transaction_annotations a left join public.categories c on c.id=a.category_id
     where a.transaction_id=t.id and (a.excluded_from_budget or a.is_transfer or a.is_card_payment
      or (t.amount_minor>0 and c.kind='expense') or (t.amount_minor<0 and c.kind='income')))
   order by coalesce(t.posted_date,t.transaction_date),t.id
  loop
   if p.id is null then
    insert into public.budgeteer_plans(owner_id,month) values(own,p_month) returning * into p;
   end if;
   insert into public.budgeteer_entries(owner_id,plan_id,kind,name,amount_minor,sort_position,source_transaction_id,source_snapshot)
   values(own,p.id,case when source_row.amount_minor>0 then 'deposit' else 'withdrawal' end,
     btrim(left(coalesce(nullif(btrim(source_row.description),''),'Bank transaction'),120)),abs(source_row.amount_minor),pos,source_row.id,to_jsonb(source_row));
   pos:=pos+1; changed:=true;
  end loop;
  if exists(select 1 from public.budgeteer_entries where plan_id=p.id group by kind having sum(amount_minor)>9000000000000) then raise exception 'budgeteer_total_overflow'; end if;
  if changed then update public.budgeteer_plans set revision=revision+1,updated_at=clock_timestamp() where id=p.id; end if;
  return public.budgeteer_read(p_month);
 end if;
 if p_operation in ('entry_delete','source_unlink') then
  select source_transaction_id into sid from public.budgeteer_entries where id=(p_payload->>'id')::uuid and owner_id=own and plan_id=p.id;
  if sid is not null then
   insert into public.budgeteer_source_exclusions(owner_id,month,source_transaction_id) values(own,p_month,sid) on conflict do nothing;
  end if;
 end if;
 result:=private.budgeteer_mutate_existing(p_month,p_revision,p_operation,p_payload);
 if p_operation='entry_save' and (p_payload->>'source_transaction_id') is not null then
  delete from public.budgeteer_source_exclusions where owner_id=own and month=p_month and source_transaction_id=(p_payload->>'source_transaction_id')::uuid;
  return public.budgeteer_read(p_month);
 end if;
 return result;
end $$;
revoke all on function public.budgeteer_mutate(date,bigint,text,jsonb) from public,anon;
grant execute on function public.budgeteer_mutate(date,bigint,text,jsonb) to authenticated;
