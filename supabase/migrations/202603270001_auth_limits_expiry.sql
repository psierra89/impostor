-- Auth limits + room expiry + cleanup

alter table public.rooms
  add column if not exists expires_at timestamptz,
  add column if not exists created_by uuid references auth.users (id) on delete set null;

update public.rooms
set expires_at = coalesce(expires_at, created_at + interval '4 hours')
where expires_at is null;

alter table public.rooms
  alter column expires_at set default (now() + interval '4 hours');

create index if not exists rooms_expires_at_idx on public.rooms (expires_at);
create index if not exists rooms_created_by_idx on public.rooms (created_by);

create or replace function public.is_google_user()
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select exists (
    select 1
    from auth.identities i
    where i.user_id = auth.uid()
      and i.provider = 'google'
  );
$$;

create or replace function public.create_room(p_code text, p_nickname text)
returns table (room_id uuid, player_id uuid, code text)
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_room_id uuid;
  v_player_id uuid;
  v_nick text := trim(p_nickname);
  v_created_24h int;
  v_active int;
begin
  if auth.uid() is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if not public.is_google_user() then
    raise exception 'NOT_GOOGLE';
  end if;
  if char_length(v_nick) < 2 or char_length(v_nick) > 20 then
    raise exception 'INVALID_NICKNAME';
  end if;
  if p_code !~ '^[A-Z0-9]{6}$' then
    raise exception 'INVALID_CODE';
  end if;

  select count(*)::int into v_created_24h
  from public.rooms r
  where r.created_by = auth.uid()
    and r.created_at > now() - interval '24 hours';

  if v_created_24h >= 5 then
    raise exception 'ROOM_LIMIT';
  end if;

  select count(*)::int into v_active
  from public.rooms r
  where r.created_by = auth.uid()
    and r.expires_at > now();

  if v_active >= 1 then
    raise exception 'ACTIVE_ROOM_EXISTS';
  end if;

  insert into public.rooms (code, created_by, expires_at)
  values (p_code, auth.uid(), now() + interval '4 hours')
  returning id into v_room_id;

  insert into public.players (room_id, user_id, nickname)
  values (v_room_id, auth.uid(), v_nick)
  returning id into v_player_id;

  update public.rooms
  set host_player_id = v_player_id
  where id = v_room_id;

  return query select v_room_id, v_player_id, p_code;
end;
$$;

create or replace function public.join_room(p_code text, p_nickname text)
returns table (room_id uuid, player_id uuid, code text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room public.rooms%rowtype;
  v_player_id uuid;
  v_nick text := trim(p_nickname);
  v_count int;
begin
  if auth.uid() is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if char_length(v_nick) < 2 or char_length(v_nick) > 20 then
    raise exception 'INVALID_NICKNAME';
  end if;

  select * into v_room
  from public.rooms r
  where r.code = upper(p_code);

  if not found then
    raise exception 'ROOM_NOT_FOUND';
  end if;

  if v_room.expires_at is not null and v_room.expires_at < now() then
    raise exception 'ROOM_EXPIRED';
  end if;

  if v_room.status <> 'lobby' then
    select p.id into v_player_id
    from public.players p
    where p.room_id = v_room.id and p.user_id = auth.uid();

    if v_player_id is not null then
      update public.players
      set is_active = true,
          nickname = v_nick,
          last_seen = now()
      where id = v_player_id;
      return query select v_room.id, v_player_id, v_room.code;
    end if;

    raise exception 'ROOM_STARTED';
  end if;

  select p.id into v_player_id
  from public.players p
  where p.room_id = v_room.id and p.user_id = auth.uid();

  if v_player_id is not null then
    update public.players
    set is_active = true,
        nickname = v_nick,
        last_seen = now()
    where id = v_player_id;
    return query select v_room.id, v_player_id, v_room.code;
  end if;

  select count(*) into v_count
  from public.players p
  where p.room_id = v_room.id and p.is_active = true;

  if v_count >= 12 then
    raise exception 'ROOM_FULL';
  end if;

  insert into public.players (room_id, user_id, nickname)
  values (v_room.id, auth.uid(), v_nick)
  returning id into v_player_id;

  return query select v_room.id, v_player_id, v_room.code;
end;
$$;

create or replace function public.add_proposal(p_room_id uuid, p_player_id uuid, p_text text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_text text := trim(p_text);
  v_player public.players%rowtype;
  v_room public.rooms%rowtype;
  v_count int;
begin
  select * into v_player from public.players where id = p_player_id;
  if not found or v_player.user_id <> auth.uid() or v_player.room_id <> p_room_id then
    raise exception 'FORBIDDEN';
  end if;

  select * into v_room from public.rooms where id = p_room_id;
  if not found then
    raise exception 'ROOM_NOT_FOUND';
  end if;
  if v_room.expires_at is not null and v_room.expires_at < now() then
    raise exception 'ROOM_EXPIRED';
  end if;
  if char_length(v_text) < 2 or char_length(v_text) > 60 then
    raise exception 'INVALID_PROPOSAL';
  end if;

  select count(*)::int into v_count
  from public.proposals
  where room_id = p_room_id
    and author_player_id = p_player_id
    and from_bank = false;

  if v_count >= 20 then
    raise exception 'PROPOSAL_LIMIT';
  end if;

  insert into public.proposals (room_id, author_player_id, text, from_bank)
  values (p_room_id, p_player_id, v_text, false);
end;
$$;

create or replace function public.suggest_from_bank(
  p_room_id uuid,
  p_player_id uuid,
  p_count int default 3
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player public.players%rowtype;
  v_room public.rooms%rowtype;
  v_added int := 0;
  v_word text;
  v_suggests int;
begin
  select * into v_player from public.players where id = p_player_id;
  if not found or v_player.user_id <> auth.uid() or v_player.room_id <> p_room_id then
    raise exception 'FORBIDDEN';
  end if;

  select * into v_room from public.rooms where id = p_room_id;
  if v_room.expires_at is not null and v_room.expires_at < now() then
    raise exception 'ROOM_EXPIRED';
  end if;

  select count(*)::int into v_suggests
  from public.proposals
  where room_id = p_room_id
    and author_player_id = p_player_id
    and from_bank = true;

  if v_suggests >= 9 then
    raise exception 'SUGGEST_LIMIT';
  end if;

  for v_word in
    select wb.text
    from public.word_bank wb
    where wb.active = true
      and not (wb.text = any (v_room.used_words))
      and not exists (
        select 1 from public.proposals pr
        where pr.room_id = p_room_id
          and pr.used = false
          and lower(pr.text) = lower(wb.text)
      )
    order by random()
    limit greatest(1, least(coalesce(p_count, 3), 5))
  loop
    insert into public.proposals (room_id, author_player_id, text, from_bank)
    values (p_room_id, p_player_id, v_word, true);
    v_added := v_added + 1;
  end loop;

  return v_added;
end;
$$;

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
  v_round_id uuid;
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
  returning id into v_round_id;

  for v_i in 1 .. v_count loop
    insert into public.round_roles (round_id, player_id, is_impostor)
    values (v_round_id, v_players[v_i], false);
  end loop;

  for v_i in 1 .. v_impostors loop
    loop
      v_pick := v_players[1 + floor(random() * v_count)::int];
      exit when exists (
        select 1 from public.round_roles rr
        where rr.round_id = v_round_id
          and rr.player_id = v_pick
          and rr.is_impostor = false
      );
    end loop;

    update public.round_roles
    set is_impostor = true
    where round_id = v_round_id and player_id = v_pick;
  end loop;

  update public.rooms
  set status = 'playing',
      current_round_id = v_round_id,
      used_words = array_append(used_words, v_word)
  where id = p_room_id;

  return query select v_round_id, v_impostors;
end;
$$;

create or replace function public.cleanup_expired_rooms()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_deleted int := 0;
begin
  with doomed as (
    select id from public.rooms where expires_at < now()
  ),
  gone as (
    delete from public.rooms r
    using doomed d
    where r.id = d.id
    returning r.id
  )
  select count(*)::int into v_deleted from gone;

  return coalesce(v_deleted, 0);
end;
$$;

grant execute on function public.is_google_user() to authenticated;
grant execute on function public.create_room(text, text) to authenticated;
grant execute on function public.join_room(text, text) to authenticated;
grant execute on function public.add_proposal(uuid, uuid, text) to authenticated;
grant execute on function public.suggest_from_bank(uuid, uuid, int) to authenticated;
grant execute on function public.start_round(uuid, uuid) to authenticated;
grant execute on function public.cleanup_expired_rooms() to service_role;
