-- 합력하여 선을 이루는 기도 · Supabase 서버 설정
-- Supabase 화면의 SQL Editor 에 이 파일 전체를 붙여 넣고 Run 을 누르면 됩니다.
-- 여러 번 실행해도 안전하도록 만들었어요.
--
-- 원칙
--  * 표(table)는 앱에서 직접 읽거나 쓸 수 없어요. 읽기는 view, 쓰기는 함수(rpc)로만 해요.
--  * view 와 함수가 "지금 로그인한 사람"(auth.uid())을 보고 보여줄 것과 할 수 있는 일을 정해요.
--  * 말못할 사연은 작성자가 누구인지(회원 번호) 밖으로 나가지 않아요. 1:1 대화는 작성자와 답한 사람만 봐요.
--  * 가장 먼저 가입한 사람이 최고 관리자가 돼요.

create extension if not exists pgcrypto;

-- ===================== 표 =====================
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  nick text not null,
  show_name text not null,
  role text not null default '일반 성도',
  verified boolean not null default false,
  created_at timestamptz not null default now()
);
create table if not exists public.profile_private (
  id uuid primary key references auth.users(id) on delete cascade,
  info jsonb not null default '{}'::jsonb,
  verify text,
  warns int not null default 0,
  suspended_until timestamptz
);
create table if not exists public.staff (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('최고 관리자', '운영자', '콘텐츠 담당', '안전 담당'))
);
create table if not exists public.activity (
  user_id uuid not null references auth.users(id) on delete cascade,
  day date not null,
  minutes int not null default 0,
  prayed boolean not null default false,
  primary key (user_id, day)
);
create table if not exists public.rooms (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 40),
  intro text not null default '',
  leader_id uuid not null references auth.users(id) on delete cascade,
  code text not null unique,
  notice text not null default '',
  created_at timestamptz not null default now()
);
create table if not exists public.room_members (
  room_id uuid not null references public.rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (room_id, user_id)
);
create table if not exists public.posts (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references auth.users(id) on delete cascade,
  author_name text not null,
  board text not null check (board in ('pray', 'story', 'concern', 'tips')),
  cat text not null default '',
  room_id uuid references public.rooms(id) on delete cascade,
  title text not null check (char_length(title) between 1 and 80),
  body text not null check (char_length(body) between 1 and 5000),
  urgent boolean not null default false,
  scope text[] not null default '{}',
  hide_after int,
  answered boolean not null default false,
  reports int not null default 0,
  reviewed boolean not null default false,
  crisis_seen boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists posts_created_idx on public.posts (created_at desc);
create table if not exists public.prayers (
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  at timestamptz not null default now(),
  primary key (post_id, user_id)
);
create table if not exists public.comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  author_id uuid not null references auth.users(id) on delete cascade,
  author_name text not null,
  role text not null default '',
  text text not null check (char_length(text) between 1 and 2000),
  created_at timestamptz not null default now()
);
create table if not exists public.chats (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  responder_id uuid not null references auth.users(id) on delete cascade,
  label text,
  from_author boolean not null,
  text text not null check (char_length(text) between 1 and 2000),
  created_at timestamptz not null default now()
);
create table if not exists public.reports (
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  at timestamptz not null default now(),
  primary key (post_id, user_id)
);
create table if not exists public.relays (
  id uuid primary key default gen_random_uuid(),
  room_id uuid references public.rooms(id) on delete cascade,
  by_name text not null,
  title text not null check (char_length(title) between 1 and 60),
  descr text not null default '',
  start_day date not null,
  days int not null check (days between 1 and 60),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create table if not exists public.relay_slots (
  relay_id uuid not null references public.relays(id) on delete cascade,
  day date not null,
  slot int not null check (slot between 0 and 47),
  user_id uuid not null references auth.users(id) on delete cascade,
  primary key (relay_id, day, slot)
);
create table if not exists public.verses (
  day date primary key,
  text text not null,
  ref text not null
);
create table if not exists public.guides (
  id uuid primary key default gen_random_uuid(),
  kind text not null,
  title text not null,
  body text not null,
  created_at timestamptz not null default now()
);
create table if not exists public.blocked_log (
  id bigserial primary key,
  user_id uuid references auth.users(id) on delete cascade,
  alias text not null default '',
  text text not null,
  at timestamptz not null default now()
);

-- 표는 앱에서 직접 건드릴 수 없게 잠가요.
do $$ declare t text; begin
  foreach t in array array['profiles','profile_private','staff','activity','rooms','room_members','posts','prayers','comments','chats','reports','relays','relay_slots','verses','guides','blocked_log'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

-- ===================== 도우미 함수 =====================
create or replace function public.pt_me() returns uuid language sql stable as $$ select auth.uid() $$;

create or replace function public.pt_staff_role() returns text language sql stable security definer set search_path = public as $$
  select role from staff where user_id = auth.uid()
$$;

-- area: 현황 안전 회원 콘텐츠 릴레이 운영진
create or replace function public.pt_can(area text) returns boolean language sql stable security definer set search_path = public as $$
  select case pt_staff_role()
    when '최고 관리자' then true
    when '운영자' then area <> '운영진'
    when '콘텐츠 담당' then area in ('현황', '콘텐츠', '릴레이')
    when '안전 담당' then area in ('현황', '안전', '회원')
    else false end
$$;

create or replace function public.pt_in_room(r uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from room_members where room_id = r and user_id = auth.uid())
$$;

create or replace function public.pt_require_user() returns uuid language plpgsql stable security definer set search_path = public as $$
declare u uuid := auth.uid();
begin
  if u is null then raise exception '로그인이 필요해요'; end if;
  if not exists (select 1 from profiles where id = u) then raise exception '가입을 먼저 마쳐 주세요'; end if;
  if exists (select 1 from profile_private where id = u and suspended_until > now()) then raise exception '지금은 이용이 잠시 정지된 상태예요'; end if;
  return u;
end $$;

create or replace function public.pt_require(area text) returns void language plpgsql stable security definer set search_path = public as $$
begin
  if not pt_can(area) then raise exception '이 일을 할 권한이 없어요'; end if;
end $$;

create or replace function public.pt_name(u uuid) returns text language sql stable security definer set search_path = public as $$
  select coalesce((select show_name from profiles where id = u), '알 수 없음')
$$;

create or replace function public.pt_has_contact(t text) returns boolean language sql immutable as $$
  select t ~ '01[016789][\s.\-]?\d{3,4}[\s.\-]?\d{4}'
      or t ~* '(https?:|www\.|\.(com|net|kr|org|me|ly)\b|open\.kakao)'
      or t ~ '(카톡|카카오톡|오픈채팅|텔레그램|인스타)\s*(아이디|id|ID|:)'
$$;

-- ===================== 읽기 (view) =====================
-- 내 정보
create or replace view public.v_me as
  select p.id, p.nick, p.show_name, p.role, p.verified, p.created_at, pp.info, pp.verify, pp.warns, pp.suspended_until, s.role as staff_role
  from profiles p left join profile_private pp on pp.id = p.id left join staff s on s.user_id = p.id
  where p.id = auth.uid();

-- 글: 모임방 글은 식구만, 신고 3번 쌓인 글은 작성자와 운영진만 봐요. 작성자 회원 번호는 내보내지 않아요.
create or replace view public.v_posts as
  select p.id, p.board, p.cat, p.room_id, p.title, p.body, p.urgent, p.scope, p.hide_after, p.answered, p.author_name, p.created_at,
    (p.author_id = auth.uid()) as mine,
    (select count(*) from prayers x where x.post_id = p.id)::int as prayers,
    exists (select 1 from prayers x where x.post_id = p.id and x.user_id = auth.uid()) as prayed,
    exists (select 1 from reports x where x.post_id = p.id and x.user_id = auth.uid()) as reported,
    case when pt_can('안전') then p.reports else 0 end as reports,
    case when pt_can('안전') then p.reviewed else false end as reviewed,
    case when pt_can('안전') then p.crisis_seen else false end as crisis_seen,
    coalesce((select json_agg(json_build_object('author', c.author_name, 'role', c.role, 'text', c.text, 'created', c.created_at) order by c.created_at)
      from comments c where c.post_id = p.id), '[]'::json) as comments
  from posts p
  where auth.uid() is not null
    and (case when p.room_id is null then true else pt_in_room(p.room_id) end)
    and (p.author_id = auth.uid() or pt_can('안전') or (p.reports < 3 and (p.hide_after is null or p.created_at > now() - make_interval(days => p.hide_after))));

-- 말못할 사연 1:1 대화: 작성자와 답한 사람(그리고 운영자가 보낸 위로 메시지)만 봐요.
create or replace view public.v_chats as
  select c.post_id, coalesce(c.label, pt_name(c.responder_id)) as with_name,
    case when c.label is not null then c.label else (select role from profiles where id = c.responder_id) end as with_role,
    c.from_author, c.text, c.created_at
  from chats c join posts p on p.id = c.post_id
  where auth.uid() is not null and (p.author_id = auth.uid() or c.responder_id = auth.uid());

-- 내가 들어간 모임방
create or replace view public.v_rooms as
  select r.id, r.name, r.intro, r.code, r.notice, r.created_at, pt_name(r.leader_id) as leader, (r.leader_id = auth.uid()) as mine,
    coalesce((select json_agg(json_build_object('n', pt_name(m.user_id),
        'last', (select max(a.day) from activity a where a.user_id = m.user_id and a.prayed),
        'w', coalesce((select sum(a.minutes) from activity a where a.user_id = m.user_id and a.day > current_date - 7), 0)) order by m.joined_at)
      from room_members m where m.room_id = r.id and m.user_id <> auth.uid()), '[]'::json) as members
  from rooms r
  where pt_in_room(r.id);

-- 릴레이 기도: 전체 릴레이와 내 모임방 릴레이
create or replace view public.v_relays as
  select l.id, l.room_id, l.by_name, l.title, l.descr, l.start_day, l.days, l.created_at,
    coalesce((select json_object_agg(d.day, d.slots) from (
      select s.day::text as day, json_object_agg(s.slot, json_build_object('n', pt_name(s.user_id), 'me', s.user_id = auth.uid())) as slots
      from relay_slots s where s.relay_id = l.id group by s.day) d), '{}'::json) as slots
  from relays l
  where auth.uid() is not null and (l.room_id is null or pt_in_room(l.room_id));

create or replace view public.v_verses as select day, text, ref from verses where auth.uid() is not null and day between current_date - 1 and current_date + 30;
create or replace view public.v_guides as select id, kind, title, body, created_at from guides where auth.uid() is not null;

-- 운영자 화면
create or replace view public.v_adm_members as
  select p.id, p.nick, p.show_name, p.role, p.verified, p.created_at, pp.info->>'real' as real_name,
    pp.info->'org' as org, pp.info->>'proof' as proof, pp.verify, pp.warns, pp.suspended_until
  from profiles p left join profile_private pp on pp.id = p.id
  where pt_can('회원') and p.id <> auth.uid();
create or replace view public.v_adm_staff as
  select s.user_id, s.role, pt_name(s.user_id) as name from staff s where pt_can('현황');
create or replace view public.v_adm_blocked as
  select b.alias, b.text, b.at, pt_name(b.user_id) as who from blocked_log b where pt_can('안전') order by b.at desc limit 100;
create or replace view public.v_adm_posts as
  select p.id, p.board, p.title, p.body, p.author_name, p.created_at, p.reports, p.reviewed, p.crisis_seen
  from posts p where pt_can('안전') and ((p.reports > 0 and not p.reviewed) or (p.board = 'concern' and not p.crisis_seen));
create or replace view public.v_adm_stats as
  with info as (select pp.info from profile_private pp)
  select
    (select count(*) from profiles)::int as members,
    (select count(*) from profiles where created_at > now() - interval '1 day')::int as members_today,
    (select count(*) from prayers)::int as prayers,
    (select coalesce(sum(minutes), 0) from activity)::int as minutes,
    (select count(*) from posts)::int as posts,
    (select count(*) from posts where created_at > now() - interval '1 day')::int as posts_today,
    (select count(*) from rooms)::int as rooms,
    (select count(*) from relay_slots)::int as relay_slots,
    (select count(distinct user_id) from activity where day = current_date)::int as active_today,
    (select json_agg(n order by w) from (select w, (select count(*) from profiles where date_trunc('week', created_at) = date_trunc('week', now()) - make_interval(weeks => w))::int as n from generate_series(7, 0, -1) w) z) as weeks,
    (select json_object_agg(k, n) from (select coalesce(info->>'gender', '') as k, count(*) as n from info group by 1) z) as gender,
    (select json_object_agg(k, n) from (select case when info->>'birth' is null then '' else
        least(6, greatest(1, floor((extract(year from age((info->>'birth')::date)))/10)))::text end as k, count(*) as n from info group by 1) z) as age,
    (select json_object_agg(k, n) from (select coalesce(info->>'sido', '') as k, count(*) as n from info group by 1) z) as region,
    (select json_object_agg(k, n) from (select coalesce(info->>'faith', '') as k, count(*) as n from info group by 1) z) as faith
  where pt_can('현황');

grant select on public.v_me, public.v_posts, public.v_chats, public.v_rooms, public.v_relays, public.v_verses, public.v_guides,
  public.v_adm_members, public.v_adm_staff, public.v_adm_blocked, public.v_adm_posts, public.v_adm_stats to authenticated;
revoke all on public.v_me, public.v_posts, public.v_chats, public.v_rooms, public.v_relays, public.v_verses, public.v_guides,
  public.v_adm_members, public.v_adm_staff, public.v_adm_blocked, public.v_adm_posts, public.v_adm_stats from anon;

-- ===================== 쓰기 (함수) =====================
-- 가입과 내 정보 저장. 가장 먼저 가입한 사람이 최고 관리자가 돼요.
create or replace function public.save_profile(p_nick text, p_show_name text, p_role text, p_info jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); was_verified boolean;
begin
  if u is null then raise exception '로그인이 필요해요'; end if;
  if char_length(coalesce(p_nick, '')) not between 1 and 20 then raise exception '닉네임을 확인해 주세요'; end if;
  if p_role not in ('일반 성도', '목회자·선교사', '상담사') then p_role := '일반 성도'; end if;
  select verified into was_verified from profiles where id = u;
  insert into profiles (id, nick, show_name, role) values (u, p_nick, coalesce(nullif(p_show_name, ''), p_nick), p_role)
    on conflict (id) do update set nick = excluded.nick, show_name = excluded.show_name,
      verified = case when profiles.role = excluded.role then profiles.verified else false end, role = excluded.role;
  insert into profile_private (id, info, verify) values (u, coalesce(p_info, '{}'::jsonb), case when p_role <> '일반 성도' then 'wait' end)
    on conflict (id) do update set info = excluded.info,
      verify = case when p_role = '일반 성도' then null when (select verified from profiles where id = u) then 'ok' else coalesce(profile_private.verify, 'wait') end;
  if not exists (select 1 from staff) then insert into staff (user_id, role) values (u, '최고 관리자'); end if;
end $$;

-- 기도 시간, 출석 (모임방 얼굴과 주간 기도 시간에 쓰여요)
create or replace function public.log_activity(p_day date, p_minutes int, p_prayed boolean) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := pt_require_user();
begin
  if p_day < current_date - 60 or p_day > current_date + 1 then return; end if;
  insert into activity (user_id, day, minutes, prayed) values (u, p_day, greatest(0, least(p_minutes, 1440)), p_prayed)
    on conflict (user_id, day) do update set minutes = excluded.minutes, prayed = excluded.prayed;
end $$;

create or replace function public.create_post(p_id uuid, p_board text, p_cat text, p_room uuid, p_title text, p_body text, p_urgent boolean, p_scope text[], p_hide_after int, p_author text) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := pt_require_user(); me profiles; nm text;
begin
  select * into me from profiles where id = u;
  if p_room is not null and not pt_in_room(p_room) then raise exception '모임방 식구만 글을 올릴 수 있어요'; end if;
  if p_board = 'concern' then
    nm := trim(coalesce(p_author, ''));
    if nm = '' or nm = me.nick or nm = me.show_name or nm = (select info->>'real' from profile_private where id = u) then raise exception '평소 닉네임이나 실명과 다른 별명을 써 주세요'; end if;
    if pt_has_contact(p_title || ' ' || p_body) then
      raise exception '전화번호, 카톡 아이디, 링크는 쓸 수 없어요';
    end if;
    if coalesce(array_length(p_scope, 1), 0) = 0 then raise exception '답글을 달 수 있는 분을 골라 주세요'; end if;
  elsif p_author = '익명의 성도' then nm := '익명의 성도';
  else nm := me.show_name; end if;
  insert into posts (id, author_id, author_name, board, cat, room_id, title, body, urgent, scope, hide_after)
    values (coalesce(p_id, gen_random_uuid()), u, nm, p_board, case when p_room is null then coalesce(p_cat, '') else '' end, p_room, p_title, p_body,
      coalesce(p_urgent, false), case when p_board = 'concern' then p_scope else '{}' end, case when p_board = 'concern' then p_hide_after end);
end $$;

create or replace function public.log_blocked(p_alias text, p_text text) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := pt_require_user();
begin insert into blocked_log (user_id, alias, text) values (u, left(coalesce(p_alias, ''), 20), left(p_text, 60)); end $$;

create or replace function public.delete_post(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid();
begin
  delete from posts where id = p_id and (author_id = u or pt_can('안전'));
end $$;

create or replace function public.set_answered(p_id uuid, p_on boolean) returns void
language sql security definer set search_path = public as $$
  update posts set answered = p_on where id = p_id and author_id = auth.uid();
$$;

create or replace function public.toggle_pray(p_id uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare u uuid := pt_require_user();
begin
  if not exists (select 1 from v_posts where id = p_id) then raise exception '글을 찾을 수 없어요'; end if;
  if exists (select 1 from prayers where post_id = p_id and user_id = u) then
    delete from prayers where post_id = p_id and user_id = u; return false;
  end if;
  insert into prayers (post_id, user_id) values (p_id, u); return true;
end $$;

create or replace function public.add_comment(p_id uuid, p_text text) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := pt_require_user(); me profiles; b text;
begin
  select * into me from profiles where id = u;
  select board into b from v_posts where id = p_id;
  if b is null then raise exception '글을 찾을 수 없어요'; end if;
  if b = 'concern' then raise exception '사연에는 1:1 대화로만 답할 수 있어요'; end if;
  insert into comments (post_id, author_id, author_name, role, text) values (p_id, u, me.show_name, (case when me.verified then me.role else '일반 성도' end), p_text);
end $$;

-- 1:1 대화. 작성자는 p_with(상대 이름)로, 답하는 사람은 자기 자신으로 보내요.
create or replace function public.send_chat(p_id uuid, p_with text, p_text text) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := pt_require_user(); p posts; me profiles; rid uuid;
begin
  select * into p from posts where id = p_id;
  if p.id is null or p.board <> 'concern' then raise exception '글을 찾을 수 없어요'; end if;
  if pt_has_contact(p_text) then raise exception '전화번호, 카톡 아이디, 링크는 보낼 수 없어요'; end if;
  select * into me from profiles where id = u;
  if p.author_id = u then
    select c.responder_id into rid from chats c where c.post_id = p_id and coalesce(c.label, pt_name(c.responder_id)) = p_with limit 1;
    if rid is null then raise exception '대화 상대를 찾을 수 없어요'; end if;
    insert into chats (post_id, responder_id, label, from_author, text)
      values (p_id, rid, (select label from chats where post_id = p_id and responder_id = rid and label is not null limit 1), true, p_text);
  else
    if not ((case when me.verified then me.role else '일반 성도' end) = any (p.scope) or '전체' = any (p.scope) or pt_can('안전')) then raise exception '이 사연은 고른 분들만 답할 수 있어요'; end if;
    insert into chats (post_id, responder_id, from_author, text) values (p_id, u, false, p_text);
  end if;
end $$;

create or replace function public.report_post(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := pt_require_user();
begin
  if not exists (select 1 from v_posts where id = p_id) then return; end if;
  insert into reports (post_id, user_id) values (p_id, u) on conflict do nothing;
  if found then update posts set reports = reports + 1, reviewed = false where id = p_id; end if;
end $$;

-- 모임방
create or replace function public.room_create(p_id uuid, p_name text, p_intro text, p_code text) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := pt_require_user();
begin
  insert into rooms (id, name, intro, leader_id, code) values (coalesce(p_id, gen_random_uuid()), p_name, coalesce(p_intro, ''), u, upper(p_code));
  insert into room_members (room_id, user_id) values (coalesce(p_id, (select id from rooms where code = upper(p_code))), u);
end $$;

create or replace function public.room_join(p_code text) returns uuid
language plpgsql security definer set search_path = public as $$
declare u uuid := pt_require_user(); r uuid;
begin
  select id into r from rooms where code = upper(trim(p_code));
  if r is null then return null; end if;
  insert into room_members (room_id, user_id) values (r, u) on conflict do nothing;
  return r;
end $$;

create or replace function public.room_leave(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid();
begin
  if exists (select 1 from rooms where id = p_id and leader_id = u) then delete from rooms where id = p_id;
  else delete from room_members where room_id = p_id and user_id = u; end if;
end $$;

create or replace function public.room_notice(p_id uuid, p_text text) returns void
language sql security definer set search_path = public as $$
  update rooms set notice = coalesce(p_text, '') where id = p_id and leader_id = auth.uid();
$$;

-- 릴레이 기도
create or replace function public.relay_create(p_id uuid, p_room uuid, p_by text, p_title text, p_descr text, p_start date, p_days int) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := pt_require_user();
begin
  if p_room is null then perform pt_require('릴레이');
  elsif not exists (select 1 from rooms where id = p_room and leader_id = u) then raise exception '방장만 모임 릴레이를 열 수 있어요'; end if;
  insert into relays (id, room_id, by_name, title, descr, start_day, days, created_by)
    values (coalesce(p_id, gen_random_uuid()), p_room, coalesce(nullif(p_by, ''), '운영자'), p_title, coalesce(p_descr, ''), coalesce(p_start, current_date), p_days, u);
end $$;

create or replace function public.relay_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from relays l where l.id = p_id and ((l.room_id is null and pt_can('릴레이')) or exists (select 1 from rooms r where r.id = l.room_id and r.leader_id = auth.uid()));
end $$;

create or replace function public.relay_slot_toggle(p_id uuid, p_day date, p_slot int) returns boolean
language plpgsql security definer set search_path = public as $$
declare u uuid := pt_require_user(); l relays; who uuid;
begin
  select * into l from relays where id = p_id;
  if l.id is null or (l.room_id is not null and not pt_in_room(l.room_id)) then raise exception '릴레이를 찾을 수 없어요'; end if;
  if p_day < l.start_day or p_day > l.start_day + l.days - 1 then raise exception '기간이 아닌 날이에요'; end if;
  select user_id into who from relay_slots where relay_id = p_id and day = p_day and slot = p_slot;
  if who = u then delete from relay_slots where relay_id = p_id and day = p_day and slot = p_slot; return false; end if;
  if who is not null then raise exception '이미 다른 분이 예약한 시간이에요'; end if;
  insert into relay_slots (relay_id, day, slot, user_id) values (p_id, p_day, p_slot, u); return true;
end $$;

-- 운영자
create or replace function public.adm_review(p_id uuid, p_action text) returns void
language plpgsql security definer set search_path = public as $$
declare a uuid;
begin
  perform pt_require('안전');
  select author_id into a from posts where id = p_id;
  if p_action = 'keep' then update posts set reports = 0, reviewed = true where id = p_id; delete from reports where post_id = p_id;
  elsif p_action = 'crisis' then update posts set crisis_seen = true where id = p_id;
  elsif p_action in ('delete', 'warn') then
    if p_action = 'warn' then update profile_private set warns = warns + 1 where id = a; end if;
    delete from posts where id = p_id;
  end if;
end $$;

create or replace function public.adm_comfort(p_id uuid, p_text text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform pt_require('안전');
  update posts set crisis_seen = true where id = p_id;
  insert into chats (post_id, responder_id, label, from_author, text) values (p_id, auth.uid(), '운영자', false, p_text);
end $$;

create or replace function public.adm_member(p_user uuid, p_action text, p_days int default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform pt_require('회원');
  if p_action = 'verify-ok' then update profiles set verified = true where id = p_user; update profile_private set verify = 'ok' where id = p_user;
  elsif p_action = 'verify-no' then update profiles set verified = false where id = p_user; update profile_private set verify = 'no' where id = p_user;
  elsif p_action = 'warn' then update profile_private set warns = warns + 1 where id = p_user;
  elsif p_action = 'suspend' then update profile_private set suspended_until = now() + make_interval(days => greatest(1, least(coalesce(p_days, 7), 365))) where id = p_user;
  elsif p_action = 'free' then update profile_private set suspended_until = null where id = p_user;
  end if;
end $$;

create or replace function public.adm_verse(p_day date, p_text text, p_ref text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform pt_require('콘텐츠');
  if coalesce(p_text, '') = '' then delete from verses where day = p_day;
  else insert into verses (day, text, ref) values (p_day, p_text, p_ref) on conflict (day) do update set text = excluded.text, ref = excluded.ref; end if;
end $$;

create or replace function public.adm_guide(p_id uuid, p_kind text, p_title text, p_body text, p_delete boolean default false) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform pt_require('콘텐츠');
  if p_delete then delete from guides where id = p_id; return; end if;
  insert into guides (id, kind, title, body) values (coalesce(p_id, gen_random_uuid()), p_kind, p_title, p_body)
    on conflict (id) do update set kind = excluded.kind, title = excluded.title, body = excluded.body;
end $$;

create or replace function public.adm_staff(p_user uuid, p_role text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform pt_require('운영진');
  if p_role is null then
    if p_user = auth.uid() then raise exception '나 자신은 뺄 수 없어요'; end if;
    delete from staff where user_id = p_user;
  else
    if p_user = auth.uid() and p_role <> '최고 관리자' and not exists (select 1 from staff where role = '최고 관리자' and user_id <> p_user) then
      raise exception '최고 관리자가 한 명은 있어야 해요'; end if;
    insert into staff (user_id, role) values (p_user, p_role) on conflict (user_id) do update set role = excluded.role;
  end if;
end $$;

-- 함수 실행 권한: 로그인한 사람만
do $$ declare f text; begin
  foreach f in array array['save_profile(text,text,text,jsonb)','log_activity(date,int,boolean)',
    'create_post(uuid,text,text,uuid,text,text,boolean,text[],int,text)','log_blocked(text,text)','delete_post(uuid)','set_answered(uuid,boolean)',
    'toggle_pray(uuid)','add_comment(uuid,text)','send_chat(uuid,text,text)','report_post(uuid)',
    'room_create(uuid,text,text,text)','room_join(text)','room_leave(uuid)','room_notice(uuid,text)',
    'relay_create(uuid,uuid,text,text,text,date,int)','relay_delete(uuid)','relay_slot_toggle(uuid,date,int)',
    'adm_review(uuid,text)','adm_comfort(uuid,text)','adm_member(uuid,text,int)','adm_verse(date,text,text)','adm_guide(uuid,text,text,text,boolean)','adm_staff(uuid,text)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- 처음 시작할 때 보일 기도의 모든 것 (원하면 운영자 화면에서 지우거나 고칠 수 있어요)
insert into public.guides (kind, title, body)
select * from (values
  ('따라하는 기도', '주기도문으로 기도하기', '하늘에 계신 우리 아버지여, 이름이 거룩히 여김을 받으시오며 나라가 임하시오며 뜻이 하늘에서 이루어진 것 같이 땅에서도 이루어지이다. 한 구절씩 천천히 읽고, 그 구절에 내 삶을 담아 기도해 보세요.'),
  ('기도의 방법', '감사 기도: 오늘 받은 은혜 세 가지 세기', '기도를 시작할 때 오늘 받은 은혜 세 가지를 구체적으로 떠올리고 감사로 고백해 보세요. 문제를 말하기 전에 감사로 마음을 여는 연습이에요.')
) v(kind, title, body)
where not exists (select 1 from public.guides);

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

create or replace function public.set_post_images(p_id uuid, p_images text[]) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := pt_require_user(); p posts;
begin
  select * into p from posts where id = p_id;
  if p.id is null or p.author_id <> u then raise exception '내 글에만 사진을 붙일 수 있어요'; end if;
  if not (p.board = 'tips' or (p.board = 'pray' and p.cat = '선교지 편지')) then raise exception '사진은 선교지 편지와 기도 노하우에만 붙일 수 있어요'; end if;
  if not pt_pics_ok(p_images, u) then raise exception '사진은 3장까지 올릴 수 있어요'; end if;
  update posts set images = coalesce(p_images, '{}') where id = p_id;
end $$;

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
