-- Applied only in disposable databases immediately before the forward migration.
insert into auth.users(id) values('90000000-0000-4000-8000-000000000001');
insert into private.app_owner(owner_id) values('90000000-0000-4000-8000-000000000001');
insert into private.customers values('90000000-0000-4000-8000-000000000001','cus_upgrade',false);
insert into private.link_sessions(id,owner_id,customer_id,completed_at) values('fcs_upgrade','90000000-0000-4000-8000-000000000001','cus_upgrade',now());
insert into public.accounts(id,owner_id,source,name,kind,connection_state) values
 ('90000000-0000-4000-8000-000000000002','90000000-0000-4000-8000-000000000001','stripe','Synthetic retained history','cash','disconnected');
insert into private.provider_accounts(account_id,provider_id,owner_id,livemode,subscribed) values
 ('90000000-0000-4000-8000-000000000002','fca_upgrade','90000000-0000-4000-8000-000000000001',false,false);
insert into public.transactions(owner_id,account_id,source,source_id,amount_minor,description,transaction_date,status) values
 ('90000000-0000-4000-8000-000000000001','90000000-0000-4000-8000-000000000002','stripe','upgrade_history',123,'Synthetic retained entry','2026-11-01','posted');
