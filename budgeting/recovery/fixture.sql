insert into auth.users values ('11111111-1111-4111-8111-111111111111');
insert into private.app_owner(owner_id) values ('11111111-1111-4111-8111-111111111111');
insert into public.accounts(id,owner_id,source,name,kind,connection_state) values
 ('22222222-2222-4222-8222-222222222222','11111111-1111-4111-8111-111111111111','stripe','Synthetic only','cash','active');
insert into public.balance_snapshots(owner_id,account_id,current_minor,available_minor,observed_at,source) values
 ('11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222',123456,120000,'2026-11-01T00:00:00Z','stripe');
insert into public.transactions(owner_id,account_id,source,source_id,amount_minor,description,transaction_date,posted_date,status) values
 ('11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222','stripe','synthetic-1',-1250,'Synthetic purchase','2026-11-01','2026-11-01','posted'),
 ('11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222','stripe','synthetic-2',5000,'Synthetic income','2026-11-01','2026-11-01','posted');
insert into private.customers values ('11111111-1111-4111-8111-111111111111','cus_synthetic',true);
insert into private.provider_accounts values ('22222222-2222-4222-8222-222222222222','fca_synthetic','11111111-1111-4111-8111-111111111111',true,true);
insert into private.jobs(account_id,kind,dedupe_key) values ('22222222-2222-4222-8222-222222222222','disconnect','synthetic-job');
