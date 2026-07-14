-- ============================================================
-- report photos — Supabase Storage bucket + policies
--
-- Phase 1 lets a citizen attach a photo of the source; Claude then
-- classifies the photo + text. Photos live in a public-read bucket
-- so the field officer (and the classify service) can load them by URL.
-- Writes are restricted to authenticated users, into their own folder.
--
-- Idempotent: safe to run repeatedly and via `supabase db push`.
-- ============================================================

insert into storage.buckets (id, name, public)
values ('report-photos', 'report-photos', true)
on conflict (id) do nothing;

-- public read (bucket is public, but be explicit for clarity)
drop policy if exists report_photos_read on storage.objects;
create policy report_photos_read on storage.objects
  for select using (bucket_id = 'report-photos');

-- authenticated users may upload into a folder named by their uid:
--   report-photos/<auth.uid()>/<filename>
drop policy if exists report_photos_insert on storage.objects;
create policy report_photos_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'report-photos'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- users may replace/delete their own uploads
drop policy if exists report_photos_update on storage.objects;
create policy report_photos_update on storage.objects
  for update to authenticated
  using (bucket_id = 'report-photos' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists report_photos_delete on storage.objects;
create policy report_photos_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'report-photos' and (storage.foldername(name))[1] = auth.uid()::text);
