-- Fix ambiguous round_id in start_round (RETURNS TABLE name clashes with column)
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
  if v_count < 3 then
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
