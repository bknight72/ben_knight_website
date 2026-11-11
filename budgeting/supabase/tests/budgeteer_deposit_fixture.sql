\set ON_ERROR_STOP on
\ir budgeteer_hierarchy_fixture.sql
-- Populated v2 hierarchy/archive verifies the v3 forward upgrade preserves both.
update public.budgeteer_groups set parent_group_id='40000000-0000-4000-8000-000000000001'
 where id='40000000-0000-4000-8000-000000000002';
insert into public.budgeteer_legacy_entry_labels(owner_id,plan_id,entry_id,label_id,entry_snapshot)
 select el.owner_id,e.plan_id,el.entry_id,el.label_id,to_jsonb(e) from public.budgeteer_entry_labels el
 join public.budgeteer_entries e on e.id=el.entry_id;
