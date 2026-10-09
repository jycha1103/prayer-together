-- 오픈 기도 모임방: 방장이 "오픈"으로 열면 누구나 가입 신청하고, 방장이 수락하면 들어가요.
-- 여러 번 실행해도 괜찮아요.
alter table public.rooms add column if not exists is_open boolean not null default false;

create table if not exists public.room_requests (
  room_id uuid not null references public.rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (room_id, user_id)
);
alter table public.room_requests enable row level security;
revoke all on public.room_requests from anon, authenticated;

-- 내가 들어간 모임방 (방장에게는 가입 신청 목록도 보여요)
create or replace view public.v_rooms as
  select r.id, r.name, r.intro, r.code, r.notice, r.created_at, pt_name(r.leader_id) as leader, (r.leader_id = auth.uid()) as mine,
    coalesce((select json_agg(json_build_object('n', pt_name(m.user_id),
        'last', (select max(a.day) from activity a where a.user_id = m.user_id and a.prayed),
        'w', coalesce((select sum(a.minutes) from activity a where a.user_id = m.user_id and a.day > current_date - 7), 0)) order by m.joined_at)
      from room_members m where m.room_id = r.id and m.user_id <> auth.uid()), '[]'::json) as members,
    r.is_open,
    case when r.leader_id = auth.uid() then coalesce((select json_agg(json_build_object('u', q.user_id, 'n', pt_name(q.user_id), 'at', q.created_at) order by q.created_at)
      from room_requests q where q.room_id = r.id), '[]'::json) else '[]'::json end as requests
  from rooms r
  where pt_in_room(r.id);

-- 아직 들어가지 않은 오픈 모임방 목록
create or replace view public.v_open_rooms as
  select r.id, r.name, r.intro, pt_name(r.leader_id) as leader,
    (select count(*) from room_members m where m.room_id = r.id)::int as members,
    exists (select 1 from room_requests q where q.room_id = r.id and q.user_id = auth.uid()) as requested
  from rooms r
  where r.is_open and auth.uid() is not null and not pt_in_room(r.id)
  order by r.created_at desc;
grant select on public.v_rooms, public.v_open_rooms to authenticated;
revoke all on public.v_open_rooms from anon;

create or replace function public.room_set_open(p_id uuid, p_open boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  update rooms set is_open = coalesce(p_open, false) where id = p_id and leader_id = auth.uid();
  if not found then raise exception '방장만 바꿀 수 있어요'; end if;
end $$;

create or replace function public.room_request(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := pt_require_user();
begin
  if not exists (select 1 from rooms where id = p_id and is_open) then raise exception '신청할 수 없는 모임방이에요'; end if;
  if pt_in_room(p_id) then return; end if;
  insert into room_requests (room_id, user_id) values (p_id, u) on conflict do nothing;
end $$;

create or replace function public.room_request_cancel(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from room_requests where room_id = p_id and user_id = auth.uid();
end $$;

create or replace function public.room_decide(p_room uuid, p_user uuid, p_ok boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from rooms where id = p_room and leader_id = auth.uid()) then raise exception '방장만 수락할 수 있어요'; end if;
  if not exists (select 1 from room_requests where room_id = p_room and user_id = p_user) then return; end if;
  delete from room_requests where room_id = p_room and user_id = p_user;
  if p_ok then insert into room_members (room_id, user_id) values (p_room, p_user) on conflict do nothing; end if;
end $$;

do $$ declare f text; begin
  foreach f in array array['room_set_open(uuid,boolean)','room_request(uuid)','room_request_cancel(uuid)','room_decide(uuid,uuid,boolean)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
