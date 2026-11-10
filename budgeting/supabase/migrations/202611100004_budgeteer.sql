-- Budgeteer is a separate planning ledger. Browser writes go through the revisioned RPC only.
create table public.budgeteer_plans (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references private.app_owner(owner_id),
 month date not null check(extract(day from month)=1), revision bigint not null default 0 check(revision>=0),
 created_at timestamptz not null default clock_timestamp(), updated_at timestamptz not null default clock_timestamp(),
 unique(owner_id,month), unique(owner_id,id)
);
create table public.budgeteer_groups (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null, plan_id uuid not null,
 name text not null check(name=btrim(name) and length(name) between 1 and 80),
 color_key text not null check(color_key ~ '^[a-z][a-z0-9_-]{0,31}$'), sort_position bigint not null check(sort_position>=0),
 foreign key(owner_id,plan_id) references public.budgeteer_plans(owner_id,id) on delete cascade,
 unique(owner_id,plan_id,id)
);
create table public.budgeteer_entries (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null, plan_id uuid not null,
 kind text not null check(kind in ('deposit','withdrawal')),
 name text not null check(name=btrim(name) and length(name) between 1 and 120),
 amount_minor bigint not null check(amount_minor between 1 and 9000000000000), group_id uuid,
 sort_position bigint not null check(sort_position>=0), source_transaction_id uuid, source_snapshot jsonb,
 check(kind='withdrawal' or group_id is null),
 check(source_snapshot is null or jsonb_typeof(source_snapshot)='object'),
 check(source_transaction_id is null or source_snapshot is not null),
 foreign key(owner_id,plan_id) references public.budgeteer_plans(owner_id,id) on delete cascade,
 foreign key(owner_id,plan_id,group_id) references public.budgeteer_groups(owner_id,plan_id,id) on delete set null (group_id),
 foreign key(owner_id,source_transaction_id) references public.transactions(owner_id,id) on delete set null (source_transaction_id),
 unique(owner_id,id), unique(plan_id,source_transaction_id)
);
create table public.budgeteer_labels (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references private.app_owner(owner_id),
 name text not null check(name=btrim(name) and length(name) between 1 and 80),
 color_key text not null check(color_key ~ '^[a-z][a-z0-9_-]{0,31}$'),
 updated_at timestamptz not null default clock_timestamp(), unique(owner_id,id), unique(owner_id,name)
);
create table public.budgeteer_entry_labels (
 owner_id uuid not null, entry_id uuid not null, label_id uuid not null, primary key(entry_id,label_id),
 foreign key(owner_id,entry_id) references public.budgeteer_entries(owner_id,id) on delete cascade,
 foreign key(owner_id,label_id) references public.budgeteer_labels(owner_id,id) on delete cascade
);
create index budgeteer_entries_source on public.budgeteer_entries(source_transaction_id) where source_transaction_id is not null;
create index budgeteer_entries_plan on public.budgeteer_entries(plan_id);
create index budgeteer_entry_labels_label on public.budgeteer_entry_labels(label_id);
do $$ declare t text; begin
 foreach t in array array['budgeteer_plans','budgeteer_groups','budgeteer_entries','budgeteer_labels','budgeteer_entry_labels'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('create policy owner_read on public.%I for select to authenticated using(owner_id=auth.uid() and public.is_budget_owner())',t);
  execute format('revoke all on public.%I from public,anon,authenticated',t);
  execute format('grant select on public.%I to authenticated',t);
  execute format('grant all on public.%I to service_role',t);
 end loop;
end $$;

-- Lock before DELETE takes source row locks, matching the RPC lock order. Account cascades
-- and import undo run these triggers too. No bank row is changed by Budgeteer.
create function private.budgeteer_delete_lock() returns trigger language plpgsql security definer set search_path='' as $$
begin
 perform pg_advisory_xact_lock(hashtextextended('budgeteer:'||owner_id::text,0)) from private.app_owner;
 return null;
end $$;
create trigger budgeteer_delete_lock before delete on public.transactions for each statement execute function private.budgeteer_delete_lock();
create function private.budgeteer_source_deleted() returns trigger language plpgsql security definer set search_path='' as $$
begin
 update public.budgeteer_plans set revision=revision+1,updated_at=clock_timestamp()
 where id in (select plan_id from public.budgeteer_entries where source_transaction_id=old.id);
 return old;
end $$;
create trigger budgeteer_source_deleted before delete on public.transactions for each row execute function private.budgeteer_source_deleted();

create function public.budgeteer_read(p_month date) returns jsonb language plpgsql stable security definer set search_path='' as $$
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
    join public.budgeteer_entries e on e.id=el.entry_id where e.plan_id=pid),'[]'::jsonb)) into result;
 return result;
end $$;

create function public.budgeteer_mutate(p_month date,p_revision bigint,p_operation text,p_payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare own uuid:=auth.uid(); p public.budgeteer_plans; eid uuid; gid uuid; sid uuid; item jsonb; old_entry public.budgeteer_entries;
 source_row public.transactions; label_row public.budgeteer_labels; pos bigint; k text; snapshot jsonb; n integer;
begin
 if not public.is_budget_owner() then raise exception 'owner_mfa_required' using errcode='42501'; end if;
 if p_month is null or extract(day from p_month)<>1 then raise exception 'budgeteer_invalid_month'; end if;
 if p_revision is null or p_revision<0 or jsonb_typeof(p_payload) is distinct from 'object' then raise exception 'budgeteer_invalid_payload'; end if;
 if p_operation is null or p_operation not in ('entry_save','entry_delete','group_save','group_delete','label_save','label_delete','source_refresh','source_unlink','reorder') then raise exception 'budgeteer_invalid_operation'; end if;
 perform pg_advisory_xact_lock(hashtextextended('budgeteer:'||own::text,0));
 select * into p from public.budgeteer_plans where owner_id=own and month=p_month for update;
 if coalesce(p.revision,0)<>p_revision then raise exception 'budgeteer_conflict' using errcode='P0001'; end if;
 if p.id is null then
  insert into public.budgeteer_plans(owner_id,month) values(own,p_month) returning * into p;
 end if;
 eid:=(p_payload->>'id')::uuid;
 if p_operation in ('entry_delete','source_refresh','source_unlink') or (p_operation='entry_save' and eid is not null) then
  select * into old_entry from public.budgeteer_entries where id=eid and owner_id=own and plan_id=p.id;
  if not found then raise exception 'budgeteer_entry_not_found'; end if;
 end if;
 if p_operation='entry_save' then
  k:=p_payload->>'kind'; gid:=(p_payload->>'group_id')::uuid;
  if k is null or k not in ('deposit','withdrawal') or (k='deposit' and gid is not null) then raise exception 'budgeteer_invalid_entry'; end if;
  if gid is not null and not exists(select 1 from public.budgeteer_groups where id=gid and owner_id=own and plan_id=p.id) then raise exception 'budgeteer_invalid_group'; end if;
  sid:=case when p_payload ? 'source_transaction_id' then (p_payload->>'source_transaction_id')::uuid else old_entry.source_transaction_id end;
  snapshot:=old_entry.source_snapshot;
  if old_entry.id is not null and old_entry.source_transaction_id is not null and sid is distinct from old_entry.source_transaction_id then raise exception 'budgeteer_unlink_required'; end if;
  if old_entry.id is not null and old_entry.kind<>k and snapshot is not null then raise exception 'budgeteer_unlink_required'; end if;
  if sid is not null and (old_entry.id is null or sid is distinct from old_entry.source_transaction_id) then
   select * into source_row from public.transactions where id=sid and owner_id=own;
   if not found then raise exception 'budgeteer_invalid_source'; end if;
   snapshot:=to_jsonb(source_row);
  end if;
  if sid is not null and (old_entry.id is null or sid is distinct from old_entry.source_transaction_id) then
   if source_row.status<>'posted' or source_row.amount_minor=0 or
      (k='deposit' and source_row.amount_minor<0) or (k='withdrawal' and source_row.amount_minor>0) or
      exists(select 1 from public.transaction_annotations a where a.transaction_id=sid and (a.excluded_from_budget or a.is_transfer or a.is_card_payment)) or
      (k='deposit' and exists(select 1 from public.transaction_annotations a join public.categories c on c.id=a.category_id where a.transaction_id=sid and c.kind='expense')) or
      (k='withdrawal' and exists(select 1 from public.transaction_annotations a join public.categories c on c.id=a.category_id where a.transaction_id=sid and c.kind='income')) then raise exception 'budgeteer_invalid_source'; end if;
  end if;
  if jsonb_typeof(p_payload->'label_ids') is distinct from 'array' then raise exception 'budgeteer_invalid_labels'; end if;
  if (k='deposit' and jsonb_array_length(p_payload->'label_ids')>0) or
     (select count(*)<>count(distinct value) from jsonb_array_elements_text(p_payload->'label_ids')) or
     exists(select 1 from jsonb_array_elements_text(p_payload->'label_ids') x(value) where not exists(select 1 from public.budgeteer_labels l where l.id=x.value::uuid and l.owner_id=own)) then raise exception 'budgeteer_invalid_labels'; end if;
  if eid is null then
   select coalesce(max(sort_position)+1,0) into pos from public.budgeteer_entries where plan_id=p.id;
   insert into public.budgeteer_entries(owner_id,plan_id,kind,name,amount_minor,group_id,sort_position,source_transaction_id,source_snapshot)
   values(own,p.id,k,btrim(p_payload->>'name'),(p_payload->>'amount_minor')::bigint,gid,pos,sid,snapshot) returning id into eid;
  else
   update public.budgeteer_entries set kind=k,name=btrim(p_payload->>'name'),amount_minor=(p_payload->>'amount_minor')::bigint,group_id=gid,
    source_transaction_id=sid,source_snapshot=snapshot where id=eid;
  end if;
  delete from public.budgeteer_entry_labels where entry_id=eid;
  insert into public.budgeteer_entry_labels select own,eid,value::uuid from jsonb_array_elements_text(p_payload->'label_ids');
 elsif p_operation='entry_delete' then delete from public.budgeteer_entries where id=eid;
 elsif p_operation='group_save' then
  if eid is null then
   select coalesce(max(sort_position)+1,0) into pos from public.budgeteer_groups where plan_id=p.id;
   insert into public.budgeteer_groups(owner_id,plan_id,name,color_key,sort_position) values(own,p.id,btrim(p_payload->>'name'),p_payload->>'color_key',pos);
  else
   update public.budgeteer_groups set name=btrim(p_payload->>'name'),color_key=p_payload->>'color_key' where id=eid and owner_id=own and plan_id=p.id;
   if not found then raise exception 'budgeteer_group_not_found'; end if;
  end if;
 elsif p_operation='group_delete' then
  delete from public.budgeteer_groups where id=eid and owner_id=own and plan_id=p.id;
  if not found then raise exception 'budgeteer_group_not_found'; end if;
 elsif p_operation in ('label_save','label_delete') then
  if eid is null and p_operation='label_save' then
   insert into public.budgeteer_labels(owner_id,name,color_key) values(own,btrim(p_payload->>'name'),p_payload->>'color_key');
  else
   select * into label_row from public.budgeteer_labels where id=eid and owner_id=own;
   if not found then raise exception 'budgeteer_label_not_found'; end if;
   -- Compare the exact returned timestamp text, not a client-rounded Date value.
   if (p_payload->>'expected_updated_at') is null or (p_payload->>'expected_updated_at')::timestamptz<>label_row.updated_at then raise exception 'budgeteer_conflict'; end if;
   if p_operation='label_delete' then delete from public.budgeteer_labels where id=eid;
   else update public.budgeteer_labels set name=btrim(p_payload->>'name'),color_key=p_payload->>'color_key',
    updated_at=greatest(clock_timestamp(),label_row.updated_at+interval '1 microsecond') where id=eid; end if;
  end if;
  -- Global labels affect every existing plan, not only the month used for the RPC.
  update public.budgeteer_plans set revision=revision+1,updated_at=clock_timestamp() where owner_id=own and id<>p.id;
 elsif p_operation='source_unlink' then
  update public.budgeteer_entries set source_transaction_id=null,source_snapshot=null where id=eid;
 elsif p_operation='source_refresh' then
  select * into source_row from public.transactions where id=old_entry.source_transaction_id and owner_id=own;
  if not found then raise exception 'budgeteer_source_unavailable'; end if;
  if source_row.status<>'posted' or source_row.amount_minor=0 or
    (old_entry.kind='deposit' and source_row.amount_minor<0) or (old_entry.kind='withdrawal' and source_row.amount_minor>0) or
    exists(select 1 from public.transaction_annotations a where a.transaction_id=source_row.id and (a.excluded_from_budget or a.is_transfer or a.is_card_payment)) or
    (old_entry.kind='deposit' and exists(select 1 from public.transaction_annotations a join public.categories c on c.id=a.category_id where a.transaction_id=source_row.id and c.kind='expense')) or
    (old_entry.kind='withdrawal' and exists(select 1 from public.transaction_annotations a join public.categories c on c.id=a.category_id where a.transaction_id=source_row.id and c.kind='income')) then raise exception 'budgeteer_invalid_source'; end if;
  update public.budgeteer_entries set source_snapshot=to_jsonb(source_row),name=left(coalesce(nullif(btrim(source_row.description),''),'Bank transaction'),120),amount_minor=abs(source_row.amount_minor) where id=eid;
 elsif p_operation='reorder' then
  if jsonb_typeof(p_payload->'groups') is distinct from 'array' or jsonb_typeof(p_payload->'entries') is distinct from 'array' then raise exception 'budgeteer_invalid_order'; end if;
  select count(*) into n from public.budgeteer_groups where plan_id=p.id;
  if jsonb_array_length(p_payload->'groups')<>n or (select count(distinct value) from jsonb_array_elements_text(p_payload->'groups'))<>n or
   exists(select 1 from jsonb_array_elements_text(p_payload->'groups') x(value) where not exists(select 1 from public.budgeteer_groups where id=x.value::uuid and plan_id=p.id and owner_id=own)) then raise exception 'budgeteer_invalid_order'; end if;
  select count(*) into n from public.budgeteer_entries where plan_id=p.id;
  if jsonb_array_length(p_payload->'entries')<>n or (select count(distinct value->>'id') from jsonb_array_elements(p_payload->'entries'))<>n then raise exception 'budgeteer_invalid_order'; end if;
  pos:=0;
  for item in select value from jsonb_array_elements(p_payload->'groups') loop
   update public.budgeteer_groups set sort_position=pos where id=(item#>>'{}')::uuid and plan_id=p.id; pos:=pos+1;
  end loop;
  pos:=0;
  for item in select value from jsonb_array_elements(p_payload->'entries') loop
   gid:=(item->>'group_id')::uuid;
   if not (item ? 'group_id') or (gid is not null and not exists(select 1 from public.budgeteer_groups where id=gid and plan_id=p.id and owner_id=own)) then raise exception 'budgeteer_invalid_order'; end if;
   update public.budgeteer_entries set sort_position=pos,group_id=gid where id=(item->>'id')::uuid and plan_id=p.id and owner_id=own and (kind='withdrawal' or gid is null);
   if not found then raise exception 'budgeteer_invalid_order'; end if;
   pos:=pos+1;
  end loop;
 end if;
 if exists(select 1 from public.budgeteer_entries where plan_id=p.id group by kind having sum(amount_minor)>9000000000000) then raise exception 'budgeteer_total_overflow'; end if;
 update public.budgeteer_plans set revision=revision+1,updated_at=clock_timestamp() where id=p.id;
 return public.budgeteer_read(p_month);
end $$;
revoke all on function public.budgeteer_read(date),public.budgeteer_mutate(date,bigint,text,jsonb) from public,anon;
grant execute on function public.budgeteer_read(date),public.budgeteer_mutate(date,bigint,text,jsonb) to authenticated;
revoke all on function private.budgeteer_delete_lock(),private.budgeteer_source_deleted() from public,anon,authenticated;
