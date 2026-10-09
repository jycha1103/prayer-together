-- 목회자·선교사·상담사는 운영자가 확인(인증 승인)한 뒤에만 그 자격으로 말 못할 사연에 답할 수 있어요.
-- 확인 전에는 일반 성도로 활동해요. 여러 번 실행해도 괜찮아요.
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
