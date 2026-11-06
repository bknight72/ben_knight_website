-- Retain financial provenance and refresh accounting, never runnable provider state.
truncate private.jobs, private.link_sessions, private.provider_accounts, private.customers;
update public.accounts set connection_state='disconnected', sync_error=null where source='stripe';
-- Even an accidentally started service-role worker cannot replay or enqueue work.
revoke execute on function public.backend_state(text,jsonb) from public, anon, authenticated, service_role;
