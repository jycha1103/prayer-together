-- 사진 첨부: 선교지 편지 기도 요청과 운영자의 기도의 모든 것 콘텐츠에 사진을 최대 3장까지 붙여요.
-- 사진은 휴대폰에서 줄여서 올리고(한 장 약 200KB), Supabase Storage 의 pics 보관함에 저장해요.
-- 여러 번 실행해도 괜찮아요.
alter table public.posts add column if not exists images text[] not null default '{}';
alter table public.guides add column if not exists images text[] not null default '{}';

-- 보이는 글의 사진 (글을 볼 수 있는 사람만)
create or replace view public.v_post_pics as
  select v.id, p.images from public.v_posts v join public.posts p on p.id = v.id where cardinality(p.images) > 0;
create or replace view public.v_guides as select id, kind, title, body, created_at, images from guides where auth.uid() is not null;
grant select on public.v_post_pics, public.v_guides to authenticated;
revoke all on public.v_post_pics, public.v_guides from anon;

create or replace function public.pt_pics_ok(p_images text[], p_owner uuid) returns boolean language sql immutable as $$
  select coalesce(cardinality(p_images), 0) <= 3
    and not exists (select 1 from unnest(coalesce(p_images, '{}')) x
      where x !~ '^https?://' or position('/storage/v1/object/public/pics/' in x) = 0
        or (p_owner is not null and position('/pics/' || p_owner::text || '/' in x) = 0))
$$;

create or replace function public.set_post_images(p_id uuid, p_images text[]) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := pt_require_user(); p posts;
begin
  select * into p from posts where id = p_id;
  if p.id is null or p.author_id <> u then raise exception '내 글에만 사진을 붙일 수 있어요'; end if;
  if not (p.board = 'pray' and p.cat = '선교지 편지') then raise exception '사진은 선교지 편지에만 붙일 수 있어요'; end if;
  if not pt_pics_ok(p_images, u) then raise exception '사진은 3장까지 올릴 수 있어요'; end if;
  update posts set images = coalesce(p_images, '{}') where id = p_id;
end $$;

create or replace function public.adm_guide_images(p_id uuid, p_images text[]) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform pt_require('콘텐츠');
  if not pt_pics_ok(p_images, null) then raise exception '사진은 3장까지 올릴 수 있어요'; end if;
  update guides set images = coalesce(p_images, '{}') where id = p_id;
end $$;

revoke all on function public.set_post_images(uuid, text[]) from public, anon;
grant execute on function public.set_post_images(uuid, text[]) to authenticated;
revoke all on function public.adm_guide_images(uuid, text[]) from public, anon;
grant execute on function public.adm_guide_images(uuid, text[]) to authenticated;

-- 사진 보관함(pics): 누구나 볼 수 있고, 로그인한 사람은 자기 폴더에만 올리고 지울 수 있어요.
do $$ begin
  if to_regclass('storage.buckets') is not null then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('pics', 'pics', true, 600000, array['image/jpeg', 'image/png', 'image/webp'])
    on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
    execute 'drop policy if exists "pics upload own folder" on storage.objects';
    execute $p$create policy "pics upload own folder" on storage.objects for insert to authenticated
      with check (bucket_id = 'pics' and (storage.foldername(name))[1] = auth.uid()::text)$p$;
    execute 'drop policy if exists "pics delete own" on storage.objects';
    execute $p$create policy "pics delete own" on storage.objects for delete to authenticated
      using (bucket_id = 'pics' and (storage.foldername(name))[1] = auth.uid()::text)$p$;
  end if;
end $$;
