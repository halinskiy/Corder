-- Storage removal needs SELECT as well as DELETE. Keep access owner-scoped;
-- public playback continues to use Worker-issued signed URLs.
drop policy if exists shares_obj_owner_select on storage.objects;
create policy shares_obj_owner_select on storage.objects
  for select to authenticated
  using (bucket_id = 'shares' and (storage.foldername(name))[1] = (select auth.uid())::text);
