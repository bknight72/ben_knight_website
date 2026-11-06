do $$ begin
 if (select count(*) from public.transactions)<>2 or (select sum(amount_minor) from public.transactions)<>3750
 or (select amount_minor from public.transactions where source_id='synthetic-1')<>-1250
 or (select current_minor from public.balance_snapshots)<>123456
 or (select available_minor from public.balance_snapshots)<>120000 then raise exception 'financial mismatch'; end if;
 if exists(select 1 from private.jobs) or exists(select 1 from private.provider_accounts) or exists(select 1 from private.customers)
 or exists(select 1 from public.accounts where connection_state<>'disconnected')
 or has_function_privilege('service_role','public.backend_state(text,jsonb)','execute') then raise exception 'unsafe replay'; end if;
 if (select owner_id from private.app_owner)<>'11111111-1111-4111-8111-111111111111' then raise exception 'owner mismatch'; end if;
end $$;
set role authenticated;
set request.jwt.claims='{"sub":"11111111-1111-4111-8111-111111111111","aal":"aal2"}';
do $$ begin if (select count(*) from public.transactions)<>2 or not public.is_budget_owner() then raise exception 'owner denied'; end if; end $$;
set request.jwt.claims='{"sub":"11111111-1111-4111-8111-111111111111","aal":"aal1"}';
do $$ begin if exists(select 1 from public.transactions) or public.is_budget_owner() then raise exception 'aal1 leak'; end if; end $$;
set request.jwt.claims='{"sub":"33333333-3333-4333-8333-333333333333","aal":"aal2"}';
do $$ begin if exists(select 1 from public.transactions) or public.is_budget_owner() then raise exception 'wrong owner leak'; end if; end $$;
reset role;
