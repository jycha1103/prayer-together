-- 기도 제목 태그와 글마다 남기는 마음 표현(🤗 💪 👍 🥹 🙌). 여러 번 실행해도 괜찮아요.
alter table public.posts add column if not exists tag text not null default '';

create table if not exists public.post_reacts (
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check (kind in ('comfort','cheer','like','moved','praise')),
  created_at timestamptz not null default now(),
  primary key (post_id, user_id, kind)
);
alter table public.post_reacts enable row level security;
revoke all on public.post_reacts from anon, authenticated;

-- 내가 볼 수 있는 글의 태그와 마음 표현 숫자
create or replace view public.v_post_extras as
  select v.id, p.tag,
    coalesce((select json_object_agg(x.kind, x.n) from (select r.kind, count(*) as n from post_reacts r where r.post_id = v.id group by r.kind) x), '{}'::json) as reacts,
    coalesce((select array_agg(r.kind) from post_reacts r where r.post_id = v.id and r.user_id = auth.uid()), '{}') as my
  from public.v_posts v join public.posts p on p.id = v.id
  where p.tag <> '' or exists (select 1 from post_reacts r where r.post_id = v.id);
grant select on public.v_post_extras to authenticated;
revoke all on public.v_post_extras from anon;

create or replace function public.set_post_tag(p_id uuid, p_tag text) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := pt_require_user();
begin
  if coalesce(p_tag, '') not in ('', '건강', '가정', '자녀', '직장', '진로', '결혼', '경제', '관계', '학업', '신앙') then raise exception '태그를 다시 골라 주세요'; end if;
  update posts set tag = coalesce(p_tag, '') where id = p_id and author_id = u;
end $$;

create or replace function public.toggle_react(p_id uuid, p_kind text) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := pt_require_user();
begin
  if not exists (select 1 from v_posts where id = p_id) then raise exception '글을 찾을 수 없어요'; end if;
  delete from post_reacts where post_id = p_id and user_id = u and kind = p_kind;
  if not found then insert into post_reacts (post_id, user_id, kind) values (p_id, u, p_kind); end if;
end $$;

do $$ declare f text; begin
  foreach f in array array['set_post_tag(uuid,text)','toggle_react(uuid,text)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
