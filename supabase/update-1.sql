-- 2026-10-09 업데이트: 운영자에게 한마디 + 기도다이어리 서버 보관 + 사진 첨부
-- Supabase SQL Editor 에 전부 붙여 넣고 Run 하세요. 여러 번 실행해도 괜찮아요.
-- 운영자에게 한마디: 회원이 불편한 점·제안을 보내고, 운영진이 모아 보고 답해요.
-- 처음 schema.sql 을 실행한 뒤에 한 번 더 실행하면 돼요. 여러 번 실행해도 괜찮아요.
create table if not exists public.feedback (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade,
  kind text not null default '불편해요',
  body text not null,
  answer text not null default '',
  done boolean not null default false,
  created_at timestamptz not null default now(),
  answered_at timestamptz
);
alter table public.feedback enable row level security;
revoke all on public.feedback from anon, authenticated;

-- 내가 보낸 의견과 답
create or replace view public.v_my_feedback as
  select f.id, f.kind, f.body, f.answer, f.done, f.created_at, f.answered_at
  from feedback f where f.user_id = auth.uid() order by f.created_at desc limit 50;
-- 운영진이 보는 의견 목록 (운영진 누구나)
create or replace view public.v_adm_feedback as
  select f.id, f.kind, f.body, f.answer, f.done, f.created_at, f.answered_at, pt_name(f.user_id) as who
  from feedback f where pt_can('현황') order by f.done, f.created_at desc limit 200;
grant select on public.v_my_feedback, public.v_adm_feedback to authenticated;
revoke all on public.v_my_feedback, public.v_adm_feedback from anon;

create or replace function public.send_feedback(p_kind text, p_body text) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := pt_require_user();
begin
  if coalesce(trim(p_body), '') = '' then raise exception '내용을 적어 주세요'; end if;
  if (select count(*) from feedback where user_id = u and created_at > now() - interval '1 hour') >= 10 then raise exception '잠시 뒤에 다시 보내 주세요'; end if;
  insert into feedback (user_id, kind, body) values (u, left(coalesce(nullif(p_kind, ''), '기타'), 10), left(p_body, 1000));
end $$;

create or replace function public.adm_feedback(p_id uuid, p_answer text, p_done boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform pt_require('현황');
  update feedback set answer = left(coalesce(p_answer, ''), 1000), done = coalesce(p_done, done),
    answered_at = case when coalesce(p_answer, '') <> '' then now() else answered_at end
  where id = p_id;
end $$;

revoke all on function public.send_feedback(text, text) from public, anon;
grant execute on function public.send_feedback(text, text) to authenticated;
revoke all on function public.adm_feedback(uuid, text, boolean) from public, anon;
grant execute on function public.adm_feedback(uuid, text, boolean) to authenticated;
-- 기도다이어리(개인 기도제목, 기도 시간, 기도 편지, 스크랩, 알림)를 서버에 보관해요.
-- 본인만 읽고 쓸 수 있어요. 여러 번 실행해도 괜찮아요.
create table if not exists public.user_state (
  user_id uuid primary key references auth.users(id) on delete cascade,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.user_state enable row level security;
revoke all on public.user_state from anon, authenticated;

create or replace view public.v_my_state as
  select s.data, s.updated_at from user_state s where s.user_id = auth.uid();
grant select on public.v_my_state to authenticated;
revoke all on public.v_my_state from anon;

create or replace function public.save_state(p_data jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := pt_require_user();
begin
  if p_data is null or jsonb_typeof(p_data) <> 'object' then raise exception '저장할 내용이 올바르지 않아요'; end if;
  if pg_column_size(p_data) > 1000000 then raise exception '기록이 너무 많아서 저장하지 못했어요'; end if;
  insert into user_state (user_id, data, updated_at) values (u, p_data, now())
  on conflict (user_id) do update set data = excluded.data, updated_at = now();
end $$;
revoke all on function public.save_state(jsonb) from public, anon;
grant execute on function public.save_state(jsonb) to authenticated;
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
