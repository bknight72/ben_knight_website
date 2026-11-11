-- Promote every definition, including duplicate names, without remapping UUIDs.
create table public.budgeteer_group_state (
 owner_id uuid primary key references private.app_owner(owner_id),
 revision bigint not null default 0 check(revision>=0)
);
insert into public.budgeteer_group_state(owner_id) select owner_id from private.app_owner;
alter table public.budgeteer_groups add constraint budgeteer_groups_owner_id_key unique(owner_id,id);
create table public.budgeteer_group_positions (
 owner_id uuid not null, plan_id uuid not null, group_id uuid not null,
 sort_position bigint not null check(sort_position>=0), primary key(plan_id,group_id),
 foreign key(owner_id,plan_id) references public.budgeteer_plans(owner_id,id) on delete cascade,
 foreign key(owner_id,group_id) references public.budgeteer_groups(owner_id,id) on delete cascade
);
insert into public.budgeteer_group_positions select owner_id,plan_id,id,sort_position from public.budgeteer_groups;
alter table public.budgeteer_entries drop constraint budgeteer_entries_owner_id_plan_id_group_id_fkey;
alter table public.budgeteer_groups drop constraint budgeteer_groups_parent_fk;
drop trigger budgeteer_validate_parent on public.budgeteer_groups;
drop index public.budgeteer_groups_parent;
alter table public.budgeteer_groups drop column plan_id;
alter table public.budgeteer_groups add constraint budgeteer_groups_owner_fk foreign key(owner_id) references private.app_owner(owner_id);
alter table public.budgeteer_groups add constraint budgeteer_groups_parent_fk
 foreign key(owner_id,parent_group_id) references public.budgeteer_groups(owner_id,id);
alter table public.budgeteer_entries add constraint budgeteer_entries_group_fk
 foreign key(owner_id,group_id) references public.budgeteer_groups(owner_id,id) on delete set null (group_id);
create index budgeteer_groups_parent on public.budgeteer_groups(owner_id,parent_group_id,sort_position,id);
-- Stable global defaults; each originating month's explicit positions stay intact.
with ordered as (select id,row_number() over(partition by owner_id order by sort_position,id)-1 as position from public.budgeteer_groups)
 update public.budgeteer_groups g set sort_position=o.position from ordered o where o.id=g.id;
do $$ declare t text; begin
 foreach t in array array['budgeteer_group_state','budgeteer_group_positions'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('create policy owner_read on public.%I for select to authenticated using(owner_id=auth.uid() and public.is_budget_owner())',t);
  execute format('revoke all on public.%I from public,anon,authenticated',t);
  execute format('grant select on public.%I to authenticated',t);
  execute format('grant all on public.%I to service_role',t);
 end loop;
end $$;

create or replace function private.budgeteer_validate_parent() returns trigger language plpgsql security definer set search_path='' as $$
begin
 perform pg_advisory_xact_lock(hashtextextended('budgeteer:'||new.owner_id::text,0));
 if tg_op='UPDATE' and new.kind is distinct from old.kind then raise exception 'budgeteer_group_kind_immutable'; end if;
 if new.kind='deposit' and new.parent_group_id is not null then raise exception 'budgeteer_invalid_parent'; end if;
 if new.parent_group_id is not null then
  if new.parent_group_id=new.id or not exists(select 1 from public.budgeteer_groups
   where id=new.parent_group_id and owner_id=new.owner_id and kind=new.kind) then raise exception 'budgeteer_invalid_parent'; end if;
  if exists(with recursive ancestors as (
   select id,parent_group_id from public.budgeteer_groups where id=new.parent_group_id and owner_id=new.owner_id
   union select g.id,g.parent_group_id from public.budgeteer_groups g join ancestors a on g.id=a.parent_group_id where g.owner_id=new.owner_id
  ) select 1 from ancestors where id=new.id) then raise exception 'budgeteer_group_cycle'; end if;
 end if;
 return new;
end $$;
create trigger budgeteer_validate_parent before insert or update of parent_group_id,owner_id,kind on public.budgeteer_groups
 for each row execute function private.budgeteer_validate_parent();
create or replace function private.budgeteer_validate_entry_group() returns trigger language plpgsql security definer set search_path='' as $$
begin
 perform pg_advisory_xact_lock(hashtextextended('budgeteer:'||new.owner_id::text,0));
 if new.group_id is not null and not exists(select 1 from public.budgeteer_groups
  where id=new.group_id and owner_id=new.owner_id and kind=new.kind) then raise exception 'budgeteer_invalid_group'; end if;
 return new;
end $$;

-- Missing overrides append in global default order after the month's saved order.
create function private.budgeteer_effective_groups(own uuid,pid uuid) returns setof public.budgeteer_groups
language sql stable security definer set search_path='' as $$
 select g.id,g.owner_id,g.name,g.color_key,
  coalesce(p.sort_position,(select coalesce(max(sort_position)+1,0) from public.budgeteer_group_positions where plan_id=pid and owner_id=own)+g.sort_position),
  g.parent_group_id,g.kind
 from public.budgeteer_groups g left join public.budgeteer_group_positions p on p.group_id=g.id and p.plan_id=pid and p.owner_id=own
 where g.owner_id=own
$$;

create or replace function public.budgeteer_read(p_month date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare own uuid:=auth.uid(); pid uuid;
begin
 if not public.is_budget_owner() then raise exception 'owner_mfa_required' using errcode='42501'; end if;
 if p_month is null or extract(day from p_month)<>1 then raise exception 'budgeteer_invalid_month'; end if;
 select id into pid from public.budgeteer_plans where owner_id=own and month=p_month;
 return jsonb_build_object('schema_version',4,'owner_id',own,
  'groups_revision',coalesce((select revision from public.budgeteer_group_state where owner_id=own),0),
  'plan',(select to_jsonb(p) from public.budgeteer_plans p where p.id=pid),
  'groups',coalesce((select jsonb_agg(to_jsonb(g) order by sort_position,id) from private.budgeteer_effective_groups(own,pid) g),'[]'::jsonb),
  'entries',coalesce((select jsonb_agg(to_jsonb(e)||jsonb_build_object('source_current',to_jsonb(t),'source_state',
   case when e.source_transaction_id is null then case when e.source_snapshot is null then 'manual' else 'unavailable' end
    when to_jsonb(t)=e.source_snapshot then 'linked' else 'changed' end)
   order by case when e.kind='deposit' then 0 else 1 end,coalesce(g.sort_position,9223372036854775807),e.sort_position,e.id)
   from public.budgeteer_entries e left join public.transactions t on t.id=e.source_transaction_id and t.owner_id=own
   left join private.budgeteer_effective_groups(own,pid) g on g.id=e.group_id where e.plan_id=pid and e.owner_id=own),'[]'::jsonb),
  'legacy_labels',coalesce((select jsonb_agg(to_jsonb(l) order by name,id) from public.budgeteer_labels l where owner_id=own),'[]'::jsonb),
  'legacy_entry_labels',coalesce((select jsonb_agg(to_jsonb(el) order by entry_id,label_id) from public.budgeteer_legacy_entry_labels el where el.owner_id=own and el.plan_id=pid),'[]'::jsonb),
  'excluded_source_count',(select count(*) from public.budgeteer_source_exclusions where owner_id=own and month=p_month));
end $$;

create or replace function public.budgeteer_mutate(p_month date,p_revision bigint,p_operation text,p_payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare own uuid:=auth.uid(); p public.budgeteer_plans; target public.budgeteer_groups; old_entry public.budgeteer_entries;
 source_row public.transactions; eid uuid; gid uuid; sid uuid; parent uuid; k text; snapshot jsonb; item jsonb;
 pos bigint; n integer; gr bigint; created boolean:=false; changed boolean:=true; global_changed boolean:=false;
begin
 if not public.is_budget_owner() then raise exception 'owner_mfa_required' using errcode='42501'; end if;
 if p_month is null or extract(day from p_month)<>1 then raise exception 'budgeteer_invalid_month'; end if;
 if p_revision is null or p_revision<0 or jsonb_typeof(p_payload) is distinct from 'object' then raise exception 'budgeteer_invalid_payload'; end if;
 if p_payload->'schema_version' is distinct from '4'::jsonb then raise exception 'budgeteer_schema_upgrade_required'; end if;
 if jsonb_typeof(p_payload->'expected_groups_revision') is distinct from 'number'
  or (p_payload->>'expected_groups_revision') !~ '^[0-9]+$' then raise exception 'budgeteer_invalid_payload'; end if;
 if p_operation in ('label_save','label_delete') or (p_operation='entry_save' and p_payload ? 'label_ids') then raise exception 'budgeteer_schema_upgrade_required'; end if;
 if p_operation is null or p_operation not in ('initialize','entry_save','entry_delete','group_save','group_delete','legacy_label_convert',
  'reorder','sources_include','sources_restore','source_refresh','source_unlink') then raise exception 'budgeteer_invalid_operation'; end if;
 perform pg_advisory_xact_lock(hashtextextended('budgeteer:'||own::text,0));
 insert into public.budgeteer_group_state(owner_id) values(own) on conflict do nothing;
 select revision into gr from public.budgeteer_group_state where owner_id=own for update;
 select * into p from public.budgeteer_plans where owner_id=own and month=p_month for update;
 if gr<>(p_payload->>'expected_groups_revision')::bigint or coalesce(p.revision,0)<>p_revision then raise exception 'budgeteer_conflict'; end if;
 p_payload:=p_payload-'schema_version'-'expected_groups_revision';
 if p.id is null then
  insert into public.budgeteer_plans(owner_id,month) values(own,p_month) returning * into p; created:=true;
 end if;
 eid:=(p_payload->>'id')::uuid;
 if p_operation in ('entry_delete','source_refresh','source_unlink') or (p_operation='entry_save' and eid is not null) then
  select * into old_entry from public.budgeteer_entries where id=eid and owner_id=own and plan_id=p.id;
  if not found then raise exception 'budgeteer_entry_not_found'; end if;
 end if;
 if p_operation='entry_save' then
  k:=p_payload->>'kind'; gid:=(p_payload->>'group_id')::uuid;
  if k is null or k not in ('deposit','withdrawal') then raise exception 'budgeteer_invalid_entry'; end if;
  if gid is not null and not exists(select 1 from public.budgeteer_groups where id=gid and owner_id=own and kind=k) then raise exception 'budgeteer_invalid_group'; end if;
  if k<>'withdrawal' and exists(select 1 from public.budgeteer_entry_labels where entry_id=eid and owner_id=own) then raise exception 'budgeteer_legacy_withdrawal_required'; end if;
  sid:=case when p_payload ? 'source_transaction_id' then (p_payload->>'source_transaction_id')::uuid else old_entry.source_transaction_id end;
  snapshot:=old_entry.source_snapshot;
  if old_entry.id is not null and old_entry.source_transaction_id is not null and sid is distinct from old_entry.source_transaction_id then raise exception 'budgeteer_unlink_required'; end if;
  if old_entry.id is not null and old_entry.kind<>k and snapshot is not null then raise exception 'budgeteer_unlink_required'; end if;
  if sid is not null and (old_entry.id is null or sid is distinct from old_entry.source_transaction_id) then
   select * into source_row from public.transactions where id=sid and owner_id=own;
   if not found then raise exception 'budgeteer_invalid_source'; end if;
   if source_row.status<>'posted' or source_row.amount_minor=0 or (k='deposit' and source_row.amount_minor<0) or (k='withdrawal' and source_row.amount_minor>0)
    or exists(select 1 from public.transaction_annotations a left join public.categories c on c.id=a.category_id where a.transaction_id=sid
     and (a.excluded_from_budget or a.is_transfer or a.is_card_payment or (k='deposit' and c.kind='expense') or (k='withdrawal' and c.kind='income')))
    then raise exception 'budgeteer_invalid_source'; end if;
   snapshot:=to_jsonb(source_row);
  end if;
  if eid is null then
   select coalesce(max(sort_position)+1,0) into pos from public.budgeteer_entries where plan_id=p.id;
   insert into public.budgeteer_entries(owner_id,plan_id,kind,name,amount_minor,group_id,sort_position,source_transaction_id,source_snapshot)
    values(own,p.id,k,btrim(p_payload->>'name'),(p_payload->>'amount_minor')::bigint,gid,pos,sid,snapshot);
  else
   update public.budgeteer_entries set kind=k,name=btrim(p_payload->>'name'),amount_minor=(p_payload->>'amount_minor')::bigint,
    group_id=gid,source_transaction_id=sid,source_snapshot=snapshot where id=eid;
  end if;
  if sid is not null then delete from public.budgeteer_source_exclusions where owner_id=own and month=p_month and source_transaction_id=sid; end if;
 elsif p_operation in ('entry_delete','source_unlink') then
  if old_entry.source_transaction_id is not null then
   insert into public.budgeteer_source_exclusions(owner_id,month,source_transaction_id) values(own,p_month,old_entry.source_transaction_id) on conflict do nothing;
  end if;
  if p_operation='entry_delete' then delete from public.budgeteer_entries where id=eid;
  else update public.budgeteer_entries set source_transaction_id=null,source_snapshot=null where id=eid; end if;
 elsif p_operation='source_refresh' then
  select * into source_row from public.transactions where id=old_entry.source_transaction_id and owner_id=own;
  if not found then raise exception 'budgeteer_source_unavailable'; end if;
  if source_row.status<>'posted' or source_row.amount_minor=0 or (old_entry.kind='deposit' and source_row.amount_minor<0) or (old_entry.kind='withdrawal' and source_row.amount_minor>0)
   or exists(select 1 from public.transaction_annotations a left join public.categories c on c.id=a.category_id where a.transaction_id=source_row.id
    and (a.excluded_from_budget or a.is_transfer or a.is_card_payment or (old_entry.kind='deposit' and c.kind='expense') or (old_entry.kind='withdrawal' and c.kind='income')))
   then raise exception 'budgeteer_invalid_source'; end if;
  update public.budgeteer_entries set source_snapshot=to_jsonb(source_row),name=left(coalesce(nullif(btrim(source_row.description),''),'Bank transaction'),120),amount_minor=abs(source_row.amount_minor) where id=eid;
 elsif p_operation in ('sources_include','sources_restore') then
  if p_payload<>'{}'::jsonb then raise exception 'budgeteer_invalid_payload'; end if;
  changed:=created;
  if p_operation='sources_restore' then
   delete from public.budgeteer_source_exclusions where owner_id=own and month=p_month;
   get diagnostics n=row_count; changed:=changed or n>0;
  end if;
  select coalesce(max(sort_position)+1,0) into pos from public.budgeteer_entries where plan_id=p.id;
  for source_row in select t.* from public.transactions t where t.owner_id=own and t.status='posted' and t.amount_minor<>0
   and coalesce(t.posted_date,t.transaction_date)>=p_month and coalesce(t.posted_date,t.transaction_date)<(p_month+interval '1 month')::date
   and not exists(select 1 from public.budgeteer_entries e where e.plan_id=p.id and e.source_transaction_id=t.id)
   and not exists(select 1 from public.budgeteer_source_exclusions x where x.owner_id=own and x.month=p_month and x.source_transaction_id=t.id)
   and not exists(select 1 from public.transaction_annotations a left join public.categories c on c.id=a.category_id where a.transaction_id=t.id
    and (a.excluded_from_budget or a.is_transfer or a.is_card_payment or (t.amount_minor>0 and c.kind='expense') or (t.amount_minor<0 and c.kind='income')))
   order by coalesce(t.posted_date,t.transaction_date),t.id loop
   insert into public.budgeteer_entries(owner_id,plan_id,kind,name,amount_minor,sort_position,source_transaction_id,source_snapshot)
    values(own,p.id,case when source_row.amount_minor>0 then 'deposit' else 'withdrawal' end,
     btrim(left(coalesce(nullif(btrim(source_row.description),''),'Bank transaction'),120)),abs(source_row.amount_minor),pos,source_row.id,to_jsonb(source_row));
   pos:=pos+1; changed:=true;
  end loop;
 elsif p_operation in ('group_save','legacy_label_convert') then
  k:=case when p_payload ? 'kind' then p_payload->>'kind' else 'withdrawal' end;
  if k is null or k not in ('deposit','withdrawal') then raise exception 'budgeteer_invalid_group'; end if;
  if p_operation='legacy_label_convert' then
   if k<>'withdrawal' then raise exception 'budgeteer_invalid_group'; end if;
   if p_payload->'confirmed' is distinct from 'true'::jsonb then raise exception 'budgeteer_confirmation_required'; end if;
   if not exists(select 1 from public.budgeteer_labels where id=(p_payload->>'label_id')::uuid and owner_id=own) then raise exception 'budgeteer_label_not_found'; end if;
   if jsonb_typeof(p_payload->'entry_ids') is distinct from 'array' then raise exception 'budgeteer_invalid_entries'; end if;
   if (select count(*)<>count(distinct value) from jsonb_array_elements_text(p_payload->'entry_ids')) or exists(
    select 1 from jsonb_array_elements_text(p_payload->'entry_ids') x(value) where not exists(select 1 from public.budgeteer_entries e
     join public.budgeteer_entry_labels el on el.entry_id=e.id and el.owner_id=own where e.id=x.value::uuid and e.owner_id=own and e.plan_id=p.id and e.kind='withdrawal' and el.label_id=(p_payload->>'label_id')::uuid)) then raise exception 'budgeteer_invalid_entries'; end if;
   gid:=(p_payload->>'group_id')::uuid;
   if gid is not null and not exists(select 1 from public.budgeteer_groups where id=gid and owner_id=own and kind='withdrawal') then raise exception 'budgeteer_invalid_group'; end if;
  else gid:=eid; end if;
  if p_operation='group_save' or gid is null then
   if not(p_payload ? 'parent_group_id') then raise exception 'budgeteer_invalid_parent'; end if;
   parent:=(p_payload->>'parent_group_id')::uuid;
   if gid is not null then
    select * into target from public.budgeteer_groups where id=gid and owner_id=own;
    if not found then raise exception 'budgeteer_group_not_found'; end if;
    if k<>target.kind then raise exception 'budgeteer_group_kind_immutable'; end if;
   end if;
   if gid is null then
    select coalesce(max(sort_position)+1,0) into pos from public.budgeteer_groups where owner_id=own;
    insert into public.budgeteer_groups(owner_id,name,color_key,sort_position,parent_group_id,kind)
     values(own,btrim(p_payload->>'name'),p_payload->>'color_key',pos,parent,k) returning id into gid;
   else
    if parent is distinct from target.parent_group_id then
     insert into public.budgeteer_group_positions(owner_id,plan_id,group_id,sort_position)
      select own,plans.id,g.id,g.sort_position from public.budgeteer_plans plans
      cross join lateral private.budgeteer_effective_groups(own,plans.id) g where plans.owner_id=own
      on conflict(plan_id,group_id) do nothing;
     insert into public.budgeteer_group_positions(owner_id,plan_id,group_id,sort_position)
      select own,plans.id,gid,coalesce((select max(g.sort_position)+1 from private.budgeteer_effective_groups(own,plans.id) g
       where g.kind=k and g.parent_group_id is not distinct from parent),0)
      from public.budgeteer_plans plans where plans.owner_id=own
      on conflict(plan_id,group_id) do update set sort_position=excluded.sort_position;
     select coalesce(max(sort_position)+1,0) into pos from public.budgeteer_groups where owner_id=own;
    else pos:=target.sort_position; end if;
    update public.budgeteer_groups set name=btrim(p_payload->>'name'),color_key=p_payload->>'color_key',parent_group_id=parent,sort_position=pos where id=gid;
   end if;
   global_changed:=true;
  end if;
  if p_operation='legacy_label_convert' then
   update public.budgeteer_entries set group_id=gid where plan_id=p.id and owner_id=own and id in (select value::uuid from jsonb_array_elements_text(p_payload->'entry_ids'));
  end if;
 elsif p_operation='group_delete' then
  select * into target from public.budgeteer_groups where id=eid and owner_id=own;
  if not found then raise exception 'budgeteer_group_not_found'; end if;
  -- Normalize each month's promoted sibling order using its own priority, not the global default.
  insert into public.budgeteer_group_positions(owner_id,plan_id,group_id,sort_position)
   select own,plans.id,g.id,g.sort_position from public.budgeteer_plans plans
   cross join lateral private.budgeteer_effective_groups(own,plans.id) g where plans.owner_id=own
   on conflict(plan_id,group_id) do nothing;
  insert into public.budgeteer_group_positions(owner_id,plan_id,group_id,sort_position)
   select own,plans.id,g.id,row_number() over(partition by plans.id order by
    case when g.parent_group_id=target.id then t.sort_position else g.sort_position end,
    case when g.parent_group_id=target.id then target.id else g.id end,
    case when g.parent_group_id=target.id then g.sort_position else 0 end,g.id)-1
   from public.budgeteer_plans plans cross join lateral private.budgeteer_effective_groups(own,plans.id) g
   cross join lateral (select sort_position from private.budgeteer_effective_groups(own,plans.id) where id=target.id) t
   where plans.owner_id=own and g.id<>target.id and g.kind=target.kind
    and (g.parent_group_id is not distinct from target.parent_group_id or g.parent_group_id=target.id)
   on conflict(plan_id,group_id) do update set sort_position=excluded.sort_position;
  with siblings as (select g.id,row_number() over(order by
   case when g.parent_group_id=target.id then target.sort_position else g.sort_position end,
   case when g.parent_group_id=target.id then target.id else g.id end,
   case when g.parent_group_id=target.id then g.sort_position else 0 end,g.id)-1 as position
   from public.budgeteer_groups g where g.owner_id=own and g.id<>target.id and g.kind=target.kind
    and (g.parent_group_id is not distinct from target.parent_group_id or g.parent_group_id=target.id))
   update public.budgeteer_groups g set sort_position=s.position from siblings s where g.id=s.id;
  update public.budgeteer_plans set revision=revision+1,updated_at=clock_timestamp() where owner_id=own and id<>p.id
   and id in (select plan_id from public.budgeteer_entries where owner_id=own and group_id=target.id);
  update public.budgeteer_groups set parent_group_id=target.parent_group_id where owner_id=own and parent_group_id=target.id;
  delete from public.budgeteer_groups where id=target.id;
  global_changed:=true;
 elsif p_operation='reorder' then
  if jsonb_typeof(p_payload->'groups') is distinct from 'array' or jsonb_typeof(p_payload->'entries') is distinct from 'array' then raise exception 'budgeteer_invalid_order'; end if;
  select count(*) into n from public.budgeteer_groups where owner_id=own;
  if jsonb_array_length(p_payload->'groups')<>n or (select count(distinct value) from jsonb_array_elements_text(p_payload->'groups'))<>n
   or exists(select 1 from jsonb_array_elements_text(p_payload->'groups') x(value) where not exists(select 1 from public.budgeteer_groups where id=x.value::uuid and owner_id=own)) then raise exception 'budgeteer_invalid_order'; end if;
  select count(*) into n from public.budgeteer_entries where plan_id=p.id and owner_id=own;
  if jsonb_array_length(p_payload->'entries')<>n or (select count(distinct value->>'id') from jsonb_array_elements(p_payload->'entries'))<>n then raise exception 'budgeteer_invalid_order'; end if;
  pos:=0;
  for item in select value from jsonb_array_elements(p_payload->'groups') loop
   insert into public.budgeteer_group_positions values(own,p.id,(item#>>'{}')::uuid,pos)
    on conflict(plan_id,group_id) do update set sort_position=excluded.sort_position; pos:=pos+1;
  end loop;
  pos:=0;
  for item in select value from jsonb_array_elements(p_payload->'entries') loop
   gid:=(item->>'group_id')::uuid;
   if not(item ? 'group_id') then raise exception 'budgeteer_invalid_order'; end if;
   update public.budgeteer_entries e set sort_position=pos,group_id=gid where e.id=(item->>'id')::uuid and e.plan_id=p.id and e.owner_id=own
    and (gid is null or exists(select 1 from public.budgeteer_groups g where g.id=gid and g.owner_id=own and g.kind=e.kind));
   if not found then raise exception 'budgeteer_invalid_order'; end if; pos:=pos+1;
  end loop;
 elsif p_operation='initialize' then
  if p_payload<>'{}'::jsonb then raise exception 'budgeteer_invalid_payload'; end if;
 end if;
 if exists(select 1 from public.budgeteer_entries where plan_id=p.id group by kind having sum(amount_minor)>9000000000000) then raise exception 'budgeteer_total_overflow'; end if;
 if global_changed then update public.budgeteer_group_state set revision=revision+1 where owner_id=own; end if;
 if changed then update public.budgeteer_plans set revision=revision+1,updated_at=clock_timestamp() where id=p.id; end if;
 return public.budgeteer_read(p_month);
end $$;

-- Retire obsolete plan-scoped implementations rather than leave callable broken SQL.
drop function private.budgeteer_copy_groups(uuid,uuid,uuid),private.budgeteer_read_legacy(date),private.budgeteer_read_v2(date),
 private.budgeteer_mutate_v2(date,bigint,text,jsonb),private.budgeteer_mutate_sources(date,bigint,text,jsonb),
 private.budgeteer_mutate_existing(date,bigint,text,jsonb),private.budgeteer_mutate_hierarchy_v2(date,bigint,text,jsonb),
 private.budgeteer_mutate_flat(date,bigint,text,jsonb),private.budgeteer_mutate_flat_v2(date,bigint,text,jsonb);
revoke all on function private.budgeteer_effective_groups(uuid,uuid),private.budgeteer_validate_parent(),private.budgeteer_validate_entry_group() from public,anon,authenticated;
revoke all on function public.budgeteer_read(date),public.budgeteer_mutate(date,bigint,text,jsonb) from public,anon;
grant execute on function public.budgeteer_read(date),public.budgeteer_mutate(date,bigint,text,jsonb) to authenticated;
