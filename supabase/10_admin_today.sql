-- 운영자 현황: 오늘 숫자, 종류별 새 글, 메뉴별 하루 방문자 수. 여러 번 실행해도 괜찮아요.
-- 날짜는 한국 시간 기준이에요.
create or replace function public.pt_today() returns date language sql stable as $$ select (now() at time zone 'Asia/Seoul')::date $$;

-- 기도 완료(체크)를 누른 날을 기도 시간과 따로 알 수 있게 해요
alter table public.activity add column if not exists checked boolean not null default false;
create or replace function public.log_check(p_day date, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := pt_require_user();
begin
  if p_day < current_date - 60 or p_day > current_date + 1 then return; end if;
  insert into activity (user_id, day, checked) values (u, p_day, coalesce(p_on, false))
    on conflict (user_id, day) do update set checked = excluded.checked;
end $$;

-- 메뉴별 방문: 한 사람이 하루에 여러 번 들어와도 한 번만 남아요. 90일이 지나면 지워요.
create table if not exists public.page_visits (
  day date not null,
  page text not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  primary key (day, page, user_id)
);
alter table public.page_visits enable row level security;
revoke all on public.page_visits from anon, authenticated;
create or replace function public.log_visit(p_page text) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := pt_require_user();
begin
  if p_page not in ('home', 'pray', 'diary-items', 'diary-time', 'diary-letter', 'diary-scrap', 'concern', 'story', 'rooms', 'relay', 'guide', 'tips') then return; end if;
  insert into page_visits (day, page, user_id) values (pt_today(), p_page, u) on conflict do nothing;
  if random() < 0.02 then delete from page_visits where day < pt_today() - 90; end if;
end $$;

create or replace view public.v_adm_visits as
  with v as (select * from page_visits where day > pt_today() - 8)
  select page, day, n from (
    select page, day, count(*)::int as n from v group by 1, 2
    union all select 'diary', day, count(distinct user_id)::int from v where page like 'diary-%' group by 2
    union all select 'all', day, count(distinct user_id)::int from v group by 2
  ) z where pt_can('현황');

create or replace view public.v_adm_today as
  with k as (select pt_today() as d, extract(epoch from (pt_today()::timestamp at time zone 'Asia/Seoul')) * 1000 as ms),
  pr as (select user_id from prayers, k where (at at time zone 'Asia/Seoul')::date = k.d)
  select
    (select count(*) from profiles, k where (created_at at time zone 'Asia/Seoul')::date = k.d)::int as joined,
    (select count(*) from activity, k where day = k.d and checked)::int as checked,
    (select count(*) from activity, k where day = k.d and minutes > 0)::int as timed,
    (select count(distinct user_id) from pr)::int as interceders,
    (select count(*) from pr)::int as intercessions,
    (select count(*) from (select user_id from activity, k where day = k.d and (checked or prayed or minutes > 0) union select user_id from pr) z)::int as prayed,
    (select coalesce(sum((select count(*) from jsonb_array_elements(case when jsonb_typeof(s.data->'items') = 'array' then s.data->'items' else '[]'::jsonb end) x
        where (x->>'made') ~ '^[0-9]+$' and (x->>'made')::bigint >= k.ms)), 0) from user_state s, k)::int as items,
    (select json_object_agg(board, n) from (select board, count(*) as n from posts, k where room_id is null and (created_at at time zone 'Asia/Seoul')::date = k.d group by 1) z) as boards
  where pt_can('현황');

grant select on public.v_adm_visits, public.v_adm_today to authenticated;
revoke all on public.v_adm_visits, public.v_adm_today from anon;
revoke all on function public.log_check(date, boolean) from public, anon;
grant execute on function public.log_check(date, boolean) to authenticated;
revoke all on function public.log_visit(text) from public, anon;
grant execute on function public.log_visit(text) to authenticated;
