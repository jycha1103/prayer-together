-- 골방 기도: 운영자 현황에서 골방 기도를 쓴 사람 수를 볼 수 있게 해요. 여러 번 실행해도 괜찮아요.
create or replace function public.log_visit(p_page text) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := pt_require_user();
begin
  if p_page not in ('home', 'pray', 'diary-items', 'diary-time', 'diary-letter', 'diary-scrap', 'concern', 'story', 'rooms', 'relay', 'guide', 'tips',
                    'closet', 'closet-pray', 'closet-note', 'closet-music', 'howto') then return; end if;
  insert into page_visits (day, page, user_id) values (pt_today(), p_page, u) on conflict do nothing;
  if random() < 0.02 then delete from page_visits where day < pt_today() - 90; end if;
end $$;
