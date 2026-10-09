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
