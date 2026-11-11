\set ON_ERROR_STOP on
\ir budgeteer_deposit_fixture.sql
-- Deliberately duplicate names across months, retaining all identities/assignments.
insert into public.budgeteer_plans(id,owner_id,month,revision) values
 ('30000000-0000-4000-8000-000000000002','00000000-0000-4000-8000-000000000001','2026-11-01',8);
insert into public.budgeteer_groups(id,owner_id,plan_id,name,color_key,sort_position,parent_group_id,kind) values
 ('40000000-0000-4000-8000-000000000003','00000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000002','Same name','hex_a1b2c3',3,null,'withdrawal'),
 ('40000000-0000-4000-8000-000000000004','00000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000002','Nested','teal',5,'40000000-0000-4000-8000-000000000003','withdrawal'),
 ('40000000-0000-4000-8000-000000000005','00000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000002','Salary','hex_22c55e',11,null,'deposit');
insert into public.budgeteer_entries(id,owner_id,plan_id,kind,name,amount_minor,sort_position,group_id) values
 ('50000000-0000-4000-8000-000000000002','00000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000002','withdrawal','November withdrawal',456,2,'40000000-0000-4000-8000-000000000003'),
 ('50000000-0000-4000-8000-000000000003','00000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000002','deposit','November income',1000,1,'40000000-0000-4000-8000-000000000005');
insert into public.budgeteer_source_exclusions(owner_id,month,source_transaction_id) values
 ('00000000-0000-4000-8000-000000000001','2026-11-01','20000000-0000-4000-8000-000000000001');
create table public.budgeteer_global_upgrade_expected as
 select 'entries' as kind,to_jsonb(e) as value from public.budgeteer_entries e
 union all select 'archives',to_jsonb(a) from public.budgeteer_legacy_entry_labels a
 union all select 'exclusions',to_jsonb(x) from public.budgeteer_source_exclusions x
 union all select 'groups',to_jsonb(g)-'plan_id'-'sort_position' from public.budgeteer_groups g
 union all select 'positions',jsonb_build_object('owner_id',owner_id,'plan_id',plan_id,'group_id',id,'sort_position',sort_position) from public.budgeteer_groups;
