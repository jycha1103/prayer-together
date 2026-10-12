
-- 릴레이 기도 수정: 전체 릴레이는 릴레이 권한이 있는 운영진이, 모임 릴레이는 방장이 고칠 수 있어요. 여러 번 실행해도 괜찮아요.
create or replace function public.relay_update(p_id uuid, p_by text, p_title text, p_descr text, p_start date, p_days int) returns void
language plpgsql security definer set search_path = public as $$
declare l relays;
begin
  select * into l from relays where id = p_id;
  if l.id is null then raise exception '릴레이를 찾을 수 없어요'; end if;
  if not ((l.room_id is null and pt_can('릴레이')) or exists (select 1 from rooms r where r.id = l.room_id and r.leader_id = auth.uid())) then
    raise exception '고칠 권한이 없어요'; end if;
  update relays set by_name = coalesce(nullif(p_by, ''), by_name), title = coalesce(nullif(p_title, ''), title), descr = coalesce(p_descr, descr),
    start_day = coalesce(p_start, start_day), days = coalesce(p_days, days) where id = p_id;
  delete from relay_slots where relay_id = p_id and (day < coalesce(p_start, l.start_day) or day > coalesce(p_start, l.start_day) + coalesce(p_days, l.days) - 1);
end $$;
grant execute on function public.relay_update(uuid, text, text, text, date, int) to authenticated;
