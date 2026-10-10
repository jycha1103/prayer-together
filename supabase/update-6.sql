-- 내가 올린 글의 제목과 내용을 고칠 수 있게 해요. 여러 번 실행해도 괜찮아요.
create or replace function public.edit_post(p_id uuid, p_title text, p_body text) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := pt_require_user(); b text;
begin
  select board into b from posts where id = p_id and author_id = u;
  if b is null then raise exception '내가 올린 글만 고칠 수 있어요'; end if;
  if coalesce(trim(p_title), '') = '' or coalesce(trim(p_body), '') = '' then raise exception '제목과 내용을 모두 적어 주세요'; end if;
  if b = 'concern' and pt_has_contact(p_title || ' ' || p_body) then raise exception '전화번호, 카톡 아이디, 링크는 쓸 수 없어요'; end if;
  update posts set title = p_title, body = p_body where id = p_id and author_id = u;
end $$;
revoke all on function public.edit_post(uuid, text, text) from public, anon;
grant execute on function public.edit_post(uuid, text, text) to authenticated;
