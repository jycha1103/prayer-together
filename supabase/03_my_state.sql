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
