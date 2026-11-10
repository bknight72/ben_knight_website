do $$ begin
 if (select count(*) from public.transactions where source_id='upgrade_history')<>1 then raise exception 'upgrade erased history'; end if;
 if (select disconnect_requested_at is null from private.provider_accounts where provider_id='fca_upgrade') then raise exception 'upgrade lost disconnect intent'; end if;
 if public.backend_state('session_claim','{"id":"fcs_upgrade","owner_id":"90000000-0000-4000-8000-000000000001"}')->'completion_result' is null then raise exception 'legacy completed session can be replayed'; end if;
 begin
  perform public.backend_state('map_account','{"provider_id":"fca_upgrade","owner_id":"90000000-0000-4000-8000-000000000001","livemode":false}');
  raise exception 'upgrade revived disconnected account';
 exception when raise_exception then if sqlerrm<>'disconnecting' then raise; end if; end;
end $$;
delete from public.accounts where owner_id='90000000-0000-4000-8000-000000000001';
delete from private.link_sessions where owner_id='90000000-0000-4000-8000-000000000001';
delete from private.customers where owner_id='90000000-0000-4000-8000-000000000001';
delete from private.disconnected_provider_accounts where provider_id='fca_upgrade';
delete from public.categories where owner_id='90000000-0000-4000-8000-000000000001';
delete from public.profiles where owner_id='90000000-0000-4000-8000-000000000001';
delete from private.app_owner where owner_id='90000000-0000-4000-8000-000000000001';
delete from auth.users where id='90000000-0000-4000-8000-000000000001';
