-- Forward-only hierarchy upgrade. Existing labels and links remain archived in place.
-- Snapshot associations independently of entry lifetime; deleting a planning item
-- must not erase the owner's historical multi-label review/export data.
create table public.budgeteer_legacy_entry_labels (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references private.app_owner(owner_id),
 plan_id uuid not null, entry_id uuid not null, label_id uuid not null, entry_snapshot jsonb not null,
 unique(owner_id,entry_id,label_id)
);
insert into public.budgeteer_legacy_entry_labels(owner_id,plan_id,entry_id,label_id,entry_snapshot)
 select el.owner_id,e.plan_id,el.entry_id,el.label_id,to_jsonb(e) from public.budgeteer_entry_labels el
 join public.budgeteer_entries e on e.id=el.entry_id and e.owner_id=el.owner_id;
alter table public.budgeteer_legacy_entry_labels enable row level security;
create policy owner_read on public.budgeteer_legacy_entry_labels for select to authenticated
 using(owner_id=auth.uid() and public.is_budget_owner());
revoke all on public.budgeteer_legacy_entry_labels from public,anon,authenticated;
grant select on public.budgeteer_legacy_entry_labels to authenticated;
grant all on public.budgeteer_legacy_entry_labels to service_role;
alter table public.budgeteer_groups add column parent_group_id uuid;
alter table public.budgeteer_groups add constraint budgeteer_groups_parent_fk
 foreign key(owner_id,plan_id,parent_group_id) references public.budgeteer_groups(owner_id,plan_id,id);
create index budgeteer_groups_parent on public.budgeteer_groups(owner_id,plan_id,parent_group_id,sort_position,id);

create function private.budgeteer_validate_parent() returns trigger language plpgsql security definer set search_path='' as $$
begin
 perform pg_advisory_xact_lock(hashtextextended('budgeteer:'||new.owner_id::text,0));
 if new.parent_group_id is not null then
  if new.parent_group_id=new.id then raise exception 'budgeteer_invalid_parent'; end if;
  if not exists(select 1 from public.budgeteer_groups where id=new.parent_group_id and owner_id=new.owner_id and plan_id=new.plan_id) then
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
create trigger budgeteer_validate_parent before insert or update of parent_group_id,owner_id,plan_id on public.budgeteer_groups
 for each row execute function private.budgeteer_validate_parent();

-- A JSON ID map avoids persistent mapping state and permits duplicate names.
create function private.budgeteer_copy_groups(own uuid,target uuid,source uuid) returns void
language plpgsql security definer set search_path='' as $$
declare ids jsonb; g public.budgeteer_groups; offsets bigint; position bigint;
begin
 perform pg_advisory_xact_lock(hashtextextended('budgeteer:'||own::text,0));
 if target=source or not exists(select 1 from public.budgeteer_plans where id=target and owner_id=own)
  or not exists(select 1 from public.budgeteer_plans where id=source and owner_id=own) then raise exception 'budgeteer_invalid_copy'; end if;
 select coalesce(jsonb_object_agg(id::text,gen_random_uuid()::text),'{}'::jsonb) into ids from public.budgeteer_groups where plan_id=source and owner_id=own;
 select coalesce(max(sort_position)+1,0) into offsets from public.budgeteer_groups where plan_id=target and parent_group_id is null;
 -- Insert ancestors before descendants so the immediate composite FK is valid.
 for g in with recursive tree as (
  select x.*,0 as depth from public.budgeteer_groups x where plan_id=source and owner_id=own and parent_group_id is null
  union all select x.*,t.depth+1 from public.budgeteer_groups x join tree t on x.parent_group_id=t.id where x.plan_id=source and x.owner_id=own
 ) select id,owner_id,plan_id,name,color_key,sort_position,parent_group_id from tree order by depth,sort_position,id loop
  select count(*) into position from public.budgeteer_groups x where x.plan_id=source and x.owner_id=own
   and x.parent_group_id is not distinct from g.parent_group_id and (x.sort_position,x.id)<(g.sort_position,g.id);
  insert into public.budgeteer_groups(id,owner_id,plan_id,name,color_key,sort_position,parent_group_id)
  values((ids->>g.id::text)::uuid,own,target,g.name,g.color_key,position+case when g.parent_group_id is null then offsets else 0 end,(ids->>g.parent_group_id::text)::uuid);
 end loop;
end $$;

alter function public.budgeteer_read(date) set schema private;
alter function private.budgeteer_read(date) rename to budgeteer_read_legacy;
create function public.budgeteer_read(p_month date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb; source public.budgeteer_plans;
begin
 result:=private.budgeteer_read_legacy(p_month);
 select * into source from public.budgeteer_plans where owner_id=auth.uid() and month<p_month order by month desc limit 1;
 return (result-'labels'-'entry_labels')||jsonb_build_object('schema_version',2,
  'legacy_labels',result->'labels','legacy_entry_labels',coalesce((select jsonb_agg(to_jsonb(el) order by entry_id,label_id)
   from public.budgeteer_legacy_entry_labels el where el.owner_id=auth.uid() and el.plan_id=(result->'plan'->>'id')::uuid),'[]'::jsonb),
  'group_copy_preview',case when source.id is null then null else jsonb_build_object(
   'source_plan_id',source.id,'source_month',source.month,'source_revision',source.revision,
   'groups',coalesce((select jsonb_agg(to_jsonb(g) order by sort_position,id) from public.budgeteer_groups g where plan_id=source.id and owner_id=auth.uid()),'[]'::jsonb)) end);
end $$;

-- Keep the deployed source validation/refresh implementation, but never allow it
-- to mutate archived label links. The adapter supplies existing links verbatim.
alter function private.budgeteer_mutate_existing(date,bigint,text,jsonb) rename to budgeteer_mutate_flat;
create function private.budgeteer_mutate_existing(p_month date,p_revision bigint,p_operation text,p_payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare own uuid:=auth.uid(); p public.budgeteer_plans; gid uuid; parent uuid; target public.budgeteer_groups;
 source public.budgeteer_plans; item jsonb; pos bigint; n integer; labels jsonb; result jsonb;
begin
 if not public.is_budget_owner() then raise exception 'owner_mfa_required' using errcode='42501'; end if;
 if p_month is null or extract(day from p_month)<>1 then raise exception 'budgeteer_invalid_month'; end if;
 if p_revision is null or p_revision<0 or jsonb_typeof(p_payload) is distinct from 'object' then raise exception 'budgeteer_invalid_payload'; end if;
 if p_operation in ('label_save','label_delete') or (p_operation='entry_save' and p_payload ? 'label_ids') then raise exception 'budgeteer_schema_upgrade_required'; end if;
 perform pg_advisory_xact_lock(hashtextextended('budgeteer:'||own::text,0));
 select * into p from public.budgeteer_plans where owner_id=own and month=p_month for update;
 if coalesce(p.revision,0)<>p_revision then raise exception 'budgeteer_conflict'; end if;
 if p.id is null then
  if p_operation='groups_copy' then raise exception 'budgeteer_plan_not_found'; end if;
  insert into public.budgeteer_plans(owner_id,month) values(own,p_month) returning * into p;
  select * into source from public.budgeteer_plans where owner_id=own and month<p_month order by month desc limit 1;
  if source.id is not null then perform private.budgeteer_copy_groups(own,p.id,source.id); end if;
 end if;
 if p_operation='entry_save' then
  select coalesce(jsonb_agg(label_id order by label_id),'[]'::jsonb) into labels from public.budgeteer_entry_labels
   where owner_id=own and entry_id=(p_payload->>'id')::uuid;
  -- An archived association cannot be silently lost by changing the entry kind.
  if jsonb_array_length(labels)>0 and p_payload->>'kind'<>'withdrawal' then raise exception 'budgeteer_legacy_withdrawal_required'; end if;
  return private.budgeteer_mutate_flat(p_month,p_revision,p_operation,p_payload||jsonb_build_object('label_ids',labels));
 elsif p_operation in ('entry_delete','source_refresh','source_unlink') then
  return private.budgeteer_mutate_flat(p_month,p_revision,p_operation,p_payload);
 elsif p_operation in ('group_save','legacy_label_convert') then
  if p_operation='legacy_label_convert' then
   if p_payload->'confirmed' is distinct from 'true'::jsonb then raise exception 'budgeteer_confirmation_required'; end if;
   if not exists(select 1 from public.budgeteer_labels where id=(p_payload->>'label_id')::uuid and owner_id=own) then raise exception 'budgeteer_label_not_found'; end if;
   if jsonb_typeof(p_payload->'entry_ids') is distinct from 'array' then raise exception 'budgeteer_invalid_entries'; end if;
   if (select count(*)<>count(distinct value) from jsonb_array_elements_text(p_payload->'entry_ids')) or exists(
    select 1 from jsonb_array_elements_text(p_payload->'entry_ids') x(value) where not exists(
     select 1 from public.budgeteer_entries e join public.budgeteer_entry_labels el on el.entry_id=e.id and el.owner_id=own
     where e.id=x.value::uuid and e.owner_id=own and e.plan_id=p.id and e.kind='withdrawal' and el.label_id=(p_payload->>'label_id')::uuid)) then raise exception 'budgeteer_invalid_entries'; end if;
   gid:=(p_payload->>'group_id')::uuid;
   if gid is not null and not exists(select 1 from public.budgeteer_groups where id=gid and owner_id=own and plan_id=p.id) then raise exception 'budgeteer_invalid_group'; end if;
  else gid:=(p_payload->>'id')::uuid;
  end if;
  if p_operation='group_save' or gid is null then
   if not (p_payload ? 'parent_group_id') then raise exception 'budgeteer_invalid_parent'; end if;
   parent:=(p_payload->>'parent_group_id')::uuid;
   if gid is null then
    select coalesce(max(sort_position)+1,0) into pos from public.budgeteer_groups where plan_id=p.id and parent_group_id is not distinct from parent;
    insert into public.budgeteer_groups(owner_id,plan_id,name,color_key,sort_position,parent_group_id)
    values(own,p.id,btrim(p_payload->>'name'),p_payload->>'color_key',pos,parent) returning id into gid;
   else
    select * into target from public.budgeteer_groups where id=gid and owner_id=own and plan_id=p.id;
    if not found then raise exception 'budgeteer_group_not_found'; end if;
    pos:=target.sort_position;
    if parent is distinct from target.parent_group_id then
     select coalesce(max(sort_position)+1,0) into pos from public.budgeteer_groups where plan_id=p.id and parent_group_id is not distinct from parent;
    end if;
    update public.budgeteer_groups set name=btrim(p_payload->>'name'),color_key=p_payload->>'color_key',parent_group_id=parent,sort_position=pos where id=gid;
   end if;
  end if;
  if p_operation='legacy_label_convert' then
   update public.budgeteer_entries set group_id=gid where plan_id=p.id and owner_id=own and id in (select value::uuid from jsonb_array_elements_text(p_payload->'entry_ids'));
  end if;
 elsif p_operation='group_delete' then
  select * into target from public.budgeteer_groups where id=(p_payload->>'id')::uuid and owner_id=own and plan_id=p.id;
  if not found then raise exception 'budgeteer_group_not_found'; end if;
  -- Promoted children occupy the removed group's place, keeping stable sibling order.
  with siblings as (select g.id,row_number() over(order by
   case when g.parent_group_id=target.id then target.sort_position else g.sort_position end,
   case when g.parent_group_id=target.id then target.id else g.id end,
   case when g.parent_group_id=target.id then g.sort_position else 0 end,g.id)-1 as position
   from public.budgeteer_groups g where g.plan_id=p.id and g.id<>target.id and
    (g.parent_group_id is not distinct from target.parent_group_id or g.parent_group_id=target.id))
  update public.budgeteer_groups g set sort_position=s.position from siblings s where g.id=s.id;
  update public.budgeteer_groups set parent_group_id=target.parent_group_id where plan_id=p.id and parent_group_id=target.id;
  delete from public.budgeteer_groups where id=target.id;
 elsif p_operation='reorder' then
  -- The flat implementation checks complete membership and entry ownership. A
  -- global sequence induces deterministic relative order within every sibling set.
  return private.budgeteer_mutate_flat(p_month,p_revision,p_operation,p_payload);
 elsif p_operation='groups_copy' then
  if p_payload->'confirmed' is distinct from 'true'::jsonb then raise exception 'budgeteer_confirmation_required'; end if;
  select * into source from public.budgeteer_plans where owner_id=own and month<p_month order by month desc limit 1;
  if source.id is null or source.id is distinct from (p_payload->>'source_plan_id')::uuid
   or source.revision is distinct from (p_payload->>'source_revision')::bigint then raise exception 'budgeteer_conflict'; end if;
  perform private.budgeteer_copy_groups(own,p.id,source.id);
 elsif p_operation='initialize' then
  if p_payload<>'{}'::jsonb then raise exception 'budgeteer_invalid_payload'; end if;
 else raise exception 'budgeteer_invalid_operation';
 end if;
 update public.budgeteer_plans set revision=revision+1,updated_at=clock_timestamp() where id=p.id;
 return public.budgeteer_read(p_month);
end $$;

alter function public.budgeteer_mutate(date,bigint,text,jsonb) set schema private;
alter function private.budgeteer_mutate(date,bigint,text,jsonb) rename to budgeteer_mutate_sources;
create function public.budgeteer_mutate(p_month date,p_revision bigint,p_operation text,p_payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare own uuid:=auth.uid(); p public.budgeteer_plans; source public.budgeteer_plans; created boolean:=false; result jsonb;
begin
 if not public.is_budget_owner() then raise exception 'owner_mfa_required' using errcode='42501'; end if;
 if p_month is null or extract(day from p_month)<>1 then raise exception 'budgeteer_invalid_month'; end if;
 if p_revision is null or p_revision<0 or jsonb_typeof(p_payload) is distinct from 'object' then raise exception 'budgeteer_invalid_payload'; end if;
 if p_operation in ('label_save','label_delete') or (p_operation='entry_save' and p_payload ? 'label_ids') then raise exception 'budgeteer_schema_upgrade_required'; end if;
 perform pg_advisory_xact_lock(hashtextextended('budgeteer:'||own::text,0));
 select * into p from public.budgeteer_plans where owner_id=own and month=p_month for update;
 if coalesce(p.revision,0)<>p_revision then raise exception 'budgeteer_conflict'; end if;
 if p.id is null then
  if p_operation='groups_copy' then raise exception 'budgeteer_plan_not_found'; end if;
  insert into public.budgeteer_plans(owner_id,month) values(own,p_month) returning * into p;
  select * into source from public.budgeteer_plans where owner_id=own and month<p_month order by month desc limit 1;
  if source.id is not null then perform private.budgeteer_copy_groups(own,p.id,source.id); end if;
  created:=true;
 end if;
 result:=private.budgeteer_mutate_sources(p_month,p_revision,p_operation,p_payload);
 -- Empty source batches still commit first initialization and its copied tree.
 if created and (result->'plan'->>'revision')::bigint=0 then
  update public.budgeteer_plans set revision=1,updated_at=clock_timestamp() where id=p.id;
  result:=public.budgeteer_read(p_month);
 end if;
 return result;
end $$;
revoke all on function private.budgeteer_validate_parent(),private.budgeteer_copy_groups(uuid,uuid,uuid),
 private.budgeteer_read_legacy(date),private.budgeteer_mutate_flat(date,bigint,text,jsonb),
 private.budgeteer_mutate_existing(date,bigint,text,jsonb),private.budgeteer_mutate_sources(date,bigint,text,jsonb) from public,anon,authenticated;
revoke all on function public.budgeteer_read(date),public.budgeteer_mutate(date,bigint,text,jsonb) from public,anon;
grant execute on function public.budgeteer_read(date),public.budgeteer_mutate(date,bigint,text,jsonb) to authenticated;
