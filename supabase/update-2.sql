-- 나만의 기도 노하우에도 사진을 3장까지 붙일 수 있게 해요. 여러 번 실행해도 괜찮아요.
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
