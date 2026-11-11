\set ON_ERROR_STOP on
-- Synthetic pre-upgrade records verify a genuinely populated forward migration.
insert into auth.users(id) values('00000000-0000-4000-8000-000000000001');
insert into private.app_owner(owner_id) values('00000000-0000-4000-8000-000000000001');
insert into public.accounts(id,owner_id,source,name,kind) values
 ('10000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000001','manual','Synthetic upgrade','cash');
insert into public.transactions(id,owner_id,account_id,source,source_id,amount_minor,description,transaction_date,status) values
 ('20000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','csv','upgrade-source',-123,'Synthetic source','2026-10-01','posted');
insert into public.budgeteer_plans(id,owner_id,month,revision) values
 ('30000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000001','2026-10-01',4);
insert into public.budgeteer_groups(id,owner_id,plan_id,name,color_key,sort_position) values
 ('40000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001','Same name','blue',7),
 ('40000000-0000-4000-8000-000000000002','00000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001','Same name','teal',9);
insert into public.budgeteer_entries(id,owner_id,plan_id,kind,name,amount_minor,sort_position,group_id) values
 ('50000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001','withdrawal','Archived withdrawal',123,8,'40000000-0000-4000-8000-000000000001');
update public.budgeteer_entries set source_transaction_id=t.id,source_snapshot=to_jsonb(t) from public.transactions t where t.source_id='upgrade-source';
insert into public.budgeteer_labels(id,owner_id,name,color_key) values
 ('60000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000001','Legacy one','blue'),
 ('60000000-0000-4000-8000-000000000002','00000000-0000-4000-8000-000000000001','Legacy two','teal');
insert into public.budgeteer_entry_labels(owner_id,entry_id,label_id)
 select owner_id,'50000000-0000-4000-8000-000000000001',id from public.budgeteer_labels;
