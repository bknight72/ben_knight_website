-- Flat deposit groups coexist with, but never participate in, withdrawal trees.
alter table public.budgeteer_groups add column kind text not null default 'withdrawal'
 check(kind in ('deposit','withdrawal'));
alter table public.budgeteer_groups add constraint budgeteer_deposit_groups_flat
 check(kind='withdrawal' or parent_group_id is null);
alter table public.budgeteer_entries drop constraint budgeteer_entries_check;

create or replace function private.budgeteer_validate_parent() returns trigger language plpgsql security definer set search_path='' as $$
begin
 perform pg_advisory_xact_lock(hashtextextended('budgeteer:'||new.owner_id::text,0));
 if tg_op='UPDATE' and new.kind is distinct from old.kind then raise exception 'budgeteer_group_kind_immutable'; end if;
 if new.kind='deposit' and new.parent_group_id is not null then raise exception 'budgeteer_invalid_parent'; end if;
 if new.parent_group_id is not null then
  if new.parent_group_id=new.id or not exists(select 1 from public.budgeteer_groups
   where id=new.parent_group_id and owner_id=new.owner_id and plan_id=new.plan_id and kind=new.kind) then
   raise exception 'budgeteer_invalid_parent';
  end if;
  if exists(with recursive ancestors as (
    select id,parent_group_id from public.budgeteer_groups where id=new.parent_group_id and owner_id=new.owner_id and plan_id=new.plan_id
    union select g.id,g.parent_group_id from public.budgeteer_groups g join ancestors a on g.id=a.parent_group_id
    where g.owner_id=new.owner_id and g.plan_id=new.plan_id
   ) select 1 from ancestors where id=new.id) then raise exception 'budgeteer_group_cycle'; end if;
 end if;
 return new;
end $$;
drop trigger budgeteer_validate_parent on public.budgeteer_groups;
create trigger budgeteer_validate_parent before insert or update of parent_group_id,owner_id,plan_id,kind on public.budgeteer_groups
 for each row execute function private.budgeteer_validate_parent();

create function private.budgeteer_validate_entry_group() returns trigger language plpgsql security definer set search_path='' as $$
begin
 perform pg_advisory_xact_lock(hashtextextended('budgeteer:'||new.owner_id::text,0));
 if new.group_id is not null and not exists(select 1 from public.budgeteer_groups
  where id=new.group_id and owner_id=new.owner_id and plan_id=new.plan_id and kind=new.kind) then
  raise exception 'budgeteer_invalid_group';
 end if;
 return new;
end $$;
create trigger budgeteer_validate_entry_group before insert or update of group_id,kind,owner_id,plan_id on public.budgeteer_entries
 for each row execute function private.budgeteer_validate_entry_group();

create or replace function private.budgeteer_copy_groups(own uuid,target uuid,source uuid) returns void
language plpgsql security definer set search_path='' as $$
declare ids jsonb; g public.budgeteer_groups; offsets bigint; position bigint;
begin
 perform pg_advisory_xact_lock(hashtextextended('budgeteer:'||own::text,0));
 if target=source or not exists(select 1 from public.budgeteer_plans where id=target and owner_id=own)
  or not exists(select 1 from public.budgeteer_plans where id=source and owner_id=own) then raise exception 'budgeteer_invalid_copy'; end if;
 select coalesce(jsonb_object_agg(id::text,gen_random_uuid()::text),'{}'::jsonb) into ids from public.budgeteer_groups where plan_id=source and owner_id=own;
 for g in with recursive tree as (
  select x.*,0 as depth from public.budgeteer_groups x where plan_id=source and owner_id=own and parent_group_id is null
  union all select x.*,t.depth+1 from public.budgeteer_groups x join tree t on x.parent_group_id=t.id where x.plan_id=source and x.owner_id=own
 ) select id,owner_id,plan_id,name,color_key,sort_position,parent_group_id,kind from tree order by depth,sort_position,id loop
  select coalesce(max(sort_position)+1,0) into offsets from public.budgeteer_groups where plan_id=target and kind=g.kind and parent_group_id is null;
  select count(*) into position from public.budgeteer_groups x where x.plan_id=source and x.owner_id=own and x.kind=g.kind
   and x.parent_group_id is not distinct from g.parent_group_id and (x.sort_position,x.id)<(g.sort_position,g.id);
  insert into public.budgeteer_groups(id,owner_id,plan_id,name,color_key,sort_position,parent_group_id,kind)
  values((ids->>g.id::text)::uuid,own,target,g.name,g.color_key,
   case when g.parent_group_id is null then offsets else position end,(ids->>g.parent_group_id::text)::uuid,g.kind);
 end loop;
end $$;

alter function public.budgeteer_read(date) set schema private;
alter function private.budgeteer_read(date) rename to budgeteer_read_v2;
create function public.budgeteer_read(p_month date) returns jsonb language sql stable security definer set search_path='' as $$
 select private.budgeteer_read_v2(p_month)||jsonb_build_object('schema_version',3)
$$;

-- Preserve the deployed source/snapshot and archive rules, replacing only the
-- effective entry-save and complete-reorder paths that previously forbade deposits.
alter function private.budgeteer_mutate_flat(date,bigint,text,jsonb) rename to budgeteer_mutate_flat_v2;
create function private.budgeteer_mutate_flat(p_month date,p_revision bigint,p_operation text,p_payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare own uuid:=auth.uid(); p public.budgeteer_plans; eid uuid; gid uuid; sid uuid; item jsonb; old_entry public.budgeteer_entries;
 source_row public.transactions; pos bigint; k text; snapshot jsonb; n integer;
begin
 if p_operation not in ('entry_save','reorder') then
  return private.budgeteer_mutate_flat_v2(p_month,p_revision,p_operation,p_payload);
 end if;
 if not public.is_budget_owner() then raise exception 'owner_mfa_required' using errcode='42501'; end if;
 if p_month is null or extract(day from p_month)<>1 then raise exception 'budgeteer_invalid_month'; end if;
 if p_revision is null or p_revision<0 or jsonb_typeof(p_payload) is distinct from 'object' then raise exception 'budgeteer_invalid_payload'; end if;
 perform pg_advisory_xact_lock(hashtextextended('budgeteer:'||own::text,0));
 select * into p from public.budgeteer_plans where owner_id=own and month=p_month for update;
 if coalesce(p.revision,0)<>p_revision then raise exception 'budgeteer_conflict'; end if;
 if p.id is null then raise exception 'budgeteer_plan_not_found'; end if;
 if p_operation='entry_save' then
  eid:=(p_payload->>'id')::uuid;
  if eid is not null then
   select * into old_entry from public.budgeteer_entries where id=eid and owner_id=own and plan_id=p.id;
   if not found then raise exception 'budgeteer_entry_not_found'; end if;
  end if;
  k:=p_payload->>'kind'; gid:=(p_payload->>'group_id')::uuid;
  if k is null or k not in ('deposit','withdrawal') then raise exception 'budgeteer_invalid_entry'; end if;
  if gid is not null and not exists(select 1 from public.budgeteer_groups where id=gid and owner_id=own and plan_id=p.id and kind=k) then raise exception 'budgeteer_invalid_group'; end if;
  sid:=case when p_payload ? 'source_transaction_id' then (p_payload->>'source_transaction_id')::uuid else old_entry.source_transaction_id end;
  snapshot:=old_entry.source_snapshot;
  if old_entry.id is not null and old_entry.source_transaction_id is not null and sid is distinct from old_entry.source_transaction_id then raise exception 'budgeteer_unlink_required'; end if;
  if old_entry.id is not null and old_entry.kind<>k and snapshot is not null then raise exception 'budgeteer_unlink_required'; end if;
  if sid is not null and (old_entry.id is null or sid is distinct from old_entry.source_transaction_id) then
   select * into source_row from public.transactions where id=sid and owner_id=own;
   if not found then raise exception 'budgeteer_invalid_source'; end if;
   snapshot:=to_jsonb(source_row);
   if source_row.status<>'posted' or source_row.amount_minor=0 or
      (k='deposit' and source_row.amount_minor<0) or (k='withdrawal' and source_row.amount_minor>0) or
      exists(select 1 from public.transaction_annotations a where a.transaction_id=sid and (a.excluded_from_budget or a.is_transfer or a.is_card_payment)) or
      (k='deposit' and exists(select 1 from public.transaction_annotations a join public.categories c on c.id=a.category_id where a.transaction_id=sid and c.kind='expense')) or
      (k='withdrawal' and exists(select 1 from public.transaction_annotations a join public.categories c on c.id=a.category_id where a.transaction_id=sid and c.kind='income')) then raise exception 'budgeteer_invalid_source'; end if;
  end if;
  -- The hierarchy adapter supplies archived links verbatim, never client edits.
  if jsonb_typeof(p_payload->'label_ids') is distinct from 'array' or
   (k='deposit' and jsonb_array_length(p_payload->'label_ids')>0) then raise exception 'budgeteer_invalid_labels'; end if;
  if eid is null then
   select coalesce(max(sort_position)+1,0) into pos from public.budgeteer_entries where plan_id=p.id;
   insert into public.budgeteer_entries(owner_id,plan_id,kind,name,amount_minor,group_id,sort_position,source_transaction_id,source_snapshot)
   values(own,p.id,k,btrim(p_payload->>'name'),(p_payload->>'amount_minor')::bigint,gid,pos,sid,snapshot);
  else
   update public.budgeteer_entries set kind=k,name=btrim(p_payload->>'name'),amount_minor=(p_payload->>'amount_minor')::bigint,group_id=gid,
    source_transaction_id=sid,source_snapshot=snapshot where id=eid;
  end if;
 else
  if jsonb_typeof(p_payload->'groups') is distinct from 'array' or jsonb_typeof(p_payload->'entries') is distinct from 'array' then raise exception 'budgeteer_invalid_order'; end if;
  select count(*) into n from public.budgeteer_groups where plan_id=p.id and owner_id=own;
  if jsonb_array_length(p_payload->'groups')<>n or (select count(distinct value) from jsonb_array_elements_text(p_payload->'groups'))<>n or
   exists(select 1 from jsonb_array_elements_text(p_payload->'groups') x(value) where not exists(select 1 from public.budgeteer_groups where id=x.value::uuid and plan_id=p.id and owner_id=own)) then raise exception 'budgeteer_invalid_order'; end if;
  select count(*) into n from public.budgeteer_entries where plan_id=p.id and owner_id=own;
  if jsonb_array_length(p_payload->'entries')<>n or (select count(distinct value->>'id') from jsonb_array_elements(p_payload->'entries'))<>n then raise exception 'budgeteer_invalid_order'; end if;
  pos:=0;
  for item in select value from jsonb_array_elements(p_payload->'groups') loop
   update public.budgeteer_groups set sort_position=pos where id=(item#>>'{}')::uuid and plan_id=p.id and owner_id=own; pos:=pos+1;
  end loop;
  pos:=0;
  for item in select value from jsonb_array_elements(p_payload->'entries') loop
   gid:=(item->>'group_id')::uuid;
   if not (item ? 'group_id') then raise exception 'budgeteer_invalid_order'; end if;
   update public.budgeteer_entries e set sort_position=pos,group_id=gid where e.id=(item->>'id')::uuid and e.plan_id=p.id and e.owner_id=own
    and (gid is null or exists(select 1 from public.budgeteer_groups g where g.id=gid and g.plan_id=p.id and g.owner_id=own and g.kind=e.kind));
   if not found then raise exception 'budgeteer_invalid_order'; end if;
   pos:=pos+1;
  end loop;
 end if;
 if exists(select 1 from public.budgeteer_entries where plan_id=p.id group by kind having sum(amount_minor)>9000000000000) then raise exception 'budgeteer_total_overflow'; end if;
 update public.budgeteer_plans set revision=revision+1,updated_at=clock_timestamp() where id=p.id;
 return public.budgeteer_read(p_month);
end $$;

alter function private.budgeteer_mutate_existing(date,bigint,text,jsonb) rename to budgeteer_mutate_hierarchy_v2;
create function private.budgeteer_mutate_existing(p_month date,p_revision bigint,p_operation text,p_payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare own uuid:=auth.uid(); p public.budgeteer_plans; target public.budgeteer_groups; gid uuid; parent uuid; k text; pos bigint;
begin
 if not public.is_budget_owner() then raise exception 'owner_mfa_required' using errcode='42501'; end if;
 perform pg_advisory_xact_lock(hashtextextended('budgeteer:'||own::text,0));
 if p_operation='legacy_label_convert' then
  if (p_payload ? 'kind' and p_payload->>'kind' is distinct from 'withdrawal') or exists(
   select 1 from public.budgeteer_groups where id=(p_payload->>'group_id')::uuid and owner_id=own and kind<>'withdrawal') then raise exception 'budgeteer_invalid_group'; end if;
 end if;
 if p_operation is distinct from 'group_save' then
  return private.budgeteer_mutate_hierarchy_v2(p_month,p_revision,p_operation,p_payload);
 end if;
 if p_month is null or extract(day from p_month)<>1 then raise exception 'budgeteer_invalid_month'; end if;
 if p_revision is null or p_revision<0 or jsonb_typeof(p_payload) is distinct from 'object' then raise exception 'budgeteer_invalid_payload'; end if;
 select * into p from public.budgeteer_plans where owner_id=own and month=p_month for update;
 if coalesce(p.revision,0)<>p_revision then raise exception 'budgeteer_conflict'; end if;
 if p.id is null then raise exception 'budgeteer_plan_not_found'; end if;
 k:=case when p_payload ? 'kind' then p_payload->>'kind' else 'withdrawal' end;
 if k is null or k not in ('deposit','withdrawal') then raise exception 'budgeteer_invalid_group'; end if;
 if not(p_payload ? 'parent_group_id') then raise exception 'budgeteer_invalid_parent'; end if;
 parent:=(p_payload->>'parent_group_id')::uuid; gid:=(p_payload->>'id')::uuid;
 if k='deposit' and parent is not null then raise exception 'budgeteer_invalid_parent'; end if;
 if gid is not null then
  select * into target from public.budgeteer_groups where id=gid and owner_id=own and plan_id=p.id;
  if not found then raise exception 'budgeteer_group_not_found'; end if;
  if k<>target.kind then raise exception 'budgeteer_group_kind_immutable'; end if;
 end if;
 pos:=target.sort_position;
 if gid is null or parent is distinct from target.parent_group_id then
  select coalesce(max(sort_position)+1,0) into pos from public.budgeteer_groups where plan_id=p.id and kind=k and parent_group_id is not distinct from parent;
 end if;
 if gid is null then
  insert into public.budgeteer_groups(owner_id,plan_id,name,color_key,sort_position,parent_group_id,kind)
  values(own,p.id,btrim(p_payload->>'name'),p_payload->>'color_key',pos,parent,k);
 else
  update public.budgeteer_groups set name=btrim(p_payload->>'name'),color_key=p_payload->>'color_key',parent_group_id=parent,sort_position=pos where id=gid;
 end if;
 update public.budgeteer_plans set revision=revision+1,updated_at=clock_timestamp() where id=p.id;
 return public.budgeteer_read(p_month);
end $$;

alter function public.budgeteer_mutate(date,bigint,text,jsonb) set schema private;
alter function private.budgeteer_mutate(date,bigint,text,jsonb) rename to budgeteer_mutate_v2;
create function public.budgeteer_mutate(p_month date,p_revision bigint,p_operation text,p_payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if not public.is_budget_owner() then raise exception 'owner_mfa_required' using errcode='42501'; end if;
 if jsonb_typeof(p_payload) is distinct from 'object' then raise exception 'budgeteer_invalid_payload'; end if;
 if p_payload->'schema_version' is distinct from '3'::jsonb then raise exception 'budgeteer_schema_upgrade_required'; end if;
 return private.budgeteer_mutate_v2(p_month,p_revision,p_operation,p_payload-'schema_version');
end $$;
revoke all on function private.budgeteer_validate_entry_group(),private.budgeteer_read_v2(date),
 private.budgeteer_mutate_flat_v2(date,bigint,text,jsonb),private.budgeteer_mutate_flat(date,bigint,text,jsonb),
 private.budgeteer_mutate_hierarchy_v2(date,bigint,text,jsonb),private.budgeteer_mutate_existing(date,bigint,text,jsonb),
 private.budgeteer_mutate_v2(date,bigint,text,jsonb) from public,anon,authenticated;
revoke all on function public.budgeteer_read(date),public.budgeteer_mutate(date,bigint,text,jsonb) from public,anon;
grant execute on function public.budgeteer_read(date),public.budgeteer_mutate(date,bigint,text,jsonb) to authenticated;
