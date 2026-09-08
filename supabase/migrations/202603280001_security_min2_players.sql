-- Security hardening + min 2 players

-- Revoke public/anon execute on game RPCs (only authenticated / service_role)
revoke execute on function public.create_room(text, text) from public, anon;
revoke execute on function public.join_room(text, text) from public, anon;
revoke execute on function public.leave_room(uuid) from public, anon;
revoke execute on function public.get_pool_count(uuid) from public, anon;
revoke execute on function public.add_proposal(uuid, uuid, text) from public, anon;
revoke execute on function public.suggest_from_bank(uuid, uuid, int) from public, anon;
revoke execute on function public.start_round(uuid, uuid) from public, anon;
revoke execute on function public.get_my_card(uuid, uuid) from public, anon;
revoke execute on function public.end_round(uuid, uuid, text) from public, anon;
revoke execute on function public.return_to_lobby(uuid, uuid) from public, anon;
revoke execute on function public.is_google_user() from public, anon;
revoke execute on function public.is_room_member(uuid) from public, anon;
revoke execute on function public.is_round_revealed(uuid) from public, anon;
revoke execute on function public.cleanup_expired_rooms() from public, anon, authenticated;

grant execute on function public.create_room(text, text) to authenticated;
grant execute on function public.join_room(text, text) to authenticated;
grant execute on function public.leave_room(uuid) to authenticated;
grant execute on function public.get_pool_count(uuid) to authenticated;
grant execute on function public.add_proposal(uuid, uuid, text) to authenticated;
grant execute on function public.suggest_from_bank(uuid, uuid, int) to authenticated;
grant execute on function public.start_round(uuid, uuid) to authenticated;
grant execute on function public.get_my_card(uuid, uuid) to authenticated;
grant execute on function public.end_round(uuid, uuid, text) to authenticated;
grant execute on function public.return_to_lobby(uuid, uuid) to authenticated;
grant execute on function public.cleanup_expired_rooms() to service_role;

-- Google check: identities OR JWT app_metadata (for tests / edge cases)
create or replace function public.is_google_user()
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select
    exists (
      select 1
      from auth.identities i
      where i.user_id = auth.uid()
        and i.provider = 'google'
    )
    or coalesce(auth.jwt() -> 'app_metadata' ->> 'provider', '') = 'google'
    or coalesce(auth.jwt() -> 'app_metadata' -> 'providers' ? 'google', false);
$$;

grant execute on function public.is_google_user() to authenticated;

-- Min 2 players; 1 impostor for 2–6, 2 for 7–12
create or replace function public.start_round(p_room_id uuid, p_player_id uuid)
returns table (round_id uuid, impostor_count int)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room public.rooms%rowtype;
  v_player public.players%rowtype;
  v_players uuid[];
  v_count int;
  v_impostors int;
  v_word text;
  v_source text;
  v_proposal_id uuid;
  v_new_round_id uuid;
  v_pick uuid;
  v_i int;
begin
  select * into v_player from public.players where id = p_player_id;
  if not found or v_player.user_id <> auth.uid() then
    raise exception 'FORBIDDEN';
  end if;

  select * into v_room from public.rooms where id = p_room_id;
  if not found then
    raise exception 'ROOM_NOT_FOUND';
  end if;
  if v_room.expires_at is not null and v_room.expires_at < now() then
    raise exception 'ROOM_EXPIRED';
  end if;
  if v_room.host_player_id <> p_player_id then
    raise exception 'NOT_HOST';
  end if;
  if v_room.status <> 'lobby' then
    raise exception 'WRONG_STATUS';
  end if;

  select array_agg(p.id order by p.joined_at)
  into v_players
  from public.players p
  where p.room_id = p_room_id and p.is_active = true;

  v_count := coalesce(array_length(v_players, 1), 0);
  if v_count < 2 then
    raise exception 'NEED_PLAYERS';
  end if;
  if v_count > 12 then
    raise exception 'ROOM_FULL';
  end if;

  v_impostors := case when v_count >= 7 then 2 else 1 end;

  select pr.id, pr.text into v_proposal_id, v_word
  from public.proposals pr
  where pr.room_id = p_room_id and pr.used = false
  order by random()
  limit 1;

  if v_word is not null then
    v_source := 'proposal';
    update public.proposals set used = true where id = v_proposal_id;
  else
    select wb.text into v_word
    from public.word_bank wb
    where wb.active = true
      and not (wb.text = any (v_room.used_words))
    order by random()
    limit 1;

    if v_word is null then
      select wb.text into v_word
      from public.word_bank wb
      where wb.active = true
      order by random()
      limit 1;
    end if;

    if v_word is null then
      raise exception 'EMPTY_BANK';
    end if;
    v_source := 'bank';
  end if;

  insert into public.rounds (room_id, word, word_source)
  values (p_room_id, v_word, v_source)
  returning id into v_new_round_id;

  for v_i in 1 .. v_count loop
    insert into public.round_roles (round_id, player_id, is_impostor)
    values (v_new_round_id, v_players[v_i], false);
  end loop;

  for v_i in 1 .. v_impostors loop
    loop
      v_pick := v_players[1 + floor(random() * v_count)::int];
      exit when exists (
        select 1 from public.round_roles rr
        where rr.round_id = v_new_round_id
          and rr.player_id = v_pick
          and rr.is_impostor = false
      );
    end loop;

    update public.round_roles rr
    set is_impostor = true
    where rr.round_id = v_new_round_id and rr.player_id = v_pick;
  end loop;

  update public.rooms
  set status = 'playing',
      current_round_id = v_new_round_id,
      used_words = array_append(used_words, v_word)
  where id = p_room_id;

  return query select v_new_round_id, v_impostors;
end;
$$;

-- Service-role helper for automated tests (never grant to anon/authenticated)
create or replace function public.create_room_for_tests(p_code text, p_nickname text, p_user_id uuid)
returns table (room_id uuid, player_id uuid, code text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room_id uuid;
  v_player_id uuid;
  v_nick text := trim(p_nickname);
begin
  if p_code !~ '^[A-Z0-9]{6}$' then
    raise exception 'INVALID_CODE';
  end if;
  if char_length(v_nick) < 2 or char_length(v_nick) > 20 then
    raise exception 'INVALID_NICKNAME';
  end if;

  insert into public.rooms (code, created_by, expires_at)
  values (p_code, p_user_id, now() + interval '4 hours')
  returning id into v_room_id;

  insert into public.players (room_id, user_id, nickname)
  values (v_room_id, p_user_id, v_nick)
  returning id into v_player_id;

  update public.rooms
  set host_player_id = v_player_id
  where id = v_room_id;

  return query select v_room_id, v_player_id, p_code;
end;
$$;

revoke execute on function public.create_room_for_tests(text, text, uuid) from public, anon, authenticated;
grant execute on function public.create_room_for_tests(text, text, uuid) to service_role;
