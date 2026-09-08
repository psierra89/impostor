-- Themes, kick player, quick rematch from revealed, brand hints

alter table public.rooms
  add column if not exists theme text not null default 'rosario';

alter table public.rooms
  drop constraint if exists rooms_theme_check;

alter table public.rooms
  add constraint rooms_theme_check
  check (theme in (
    'rosario',
    'futbol_ar_actual',
    'futbol_ar_historico',
    'mundial',
    'marcas'
  ));

alter table public.word_bank
  add column if not exists theme text;

alter table public.word_bank
  add column if not exists hint text;

alter table public.rounds
  add column if not exists theme_hint text;

update public.word_bank
set theme = coalesce(theme, 'rosario')
where theme is null;

alter table public.word_bank
  alter column theme set default 'rosario';

alter table public.word_bank
  alter column theme set not null;

create index if not exists word_bank_theme_active_idx
  on public.word_bank (theme)
  where active = true;

-- Kick (host only)
create or replace function public.kick_player(
  p_room_id uuid,
  p_host_player_id uuid,
  p_target_player_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room public.rooms%rowtype;
  v_host public.players%rowtype;
  v_target public.players%rowtype;
begin
  select * into v_host from public.players where id = p_host_player_id;
  if not found or v_host.user_id <> auth.uid() then
    raise exception 'FORBIDDEN';
  end if;

  select * into v_room from public.rooms where id = p_room_id;
  if not found then
    raise exception 'ROOM_NOT_FOUND';
  end if;
  if v_room.host_player_id <> p_host_player_id then
    raise exception 'NOT_HOST';
  end if;
  if v_room.status <> 'lobby' then
    raise exception 'WRONG_STATUS';
  end if;
  if p_target_player_id = p_host_player_id then
    raise exception 'CANNOT_KICK_SELF';
  end if;

  select * into v_target
  from public.players
  where id = p_target_player_id
    and room_id = p_room_id
    and is_active = true;

  if not found then
    raise exception 'PLAYER_NOT_FOUND';
  end if;

  update public.players
  set is_active = false
  where id = p_target_player_id;
end;
$$;

-- Set theme in lobby
create or replace function public.set_room_theme(
  p_room_id uuid,
  p_player_id uuid,
  p_theme text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room public.rooms%rowtype;
  v_player public.players%rowtype;
begin
  select * into v_player from public.players where id = p_player_id;
  if not found or v_player.user_id <> auth.uid() then
    raise exception 'FORBIDDEN';
  end if;

  select * into v_room from public.rooms where id = p_room_id;
  if not found then
    raise exception 'ROOM_NOT_FOUND';
  end if;
  if v_room.host_player_id <> p_player_id then
    raise exception 'NOT_HOST';
  end if;
  if v_room.status <> 'lobby' then
    raise exception 'WRONG_STATUS';
  end if;
  if p_theme not in (
    'rosario',
    'futbol_ar_actual',
    'futbol_ar_historico',
    'mundial',
    'marcas'
  ) then
    raise exception 'INVALID_THEME';
  end if;

  update public.rooms
  set theme = p_theme
  where id = p_room_id;
end;
$$;

-- create_room with theme
drop function if exists public.create_room(text, text);

create or replace function public.create_room(
  p_code text,
  p_nickname text,
  p_theme text default 'rosario'
)
returns table (room_id uuid, player_id uuid, code text)
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_room_id uuid;
  v_player_id uuid;
  v_nick text := trim(p_nickname);
  v_theme text := coalesce(nullif(trim(p_theme), ''), 'rosario');
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
  if v_theme not in (
    'rosario',
    'futbol_ar_actual',
    'futbol_ar_historico',
    'mundial',
    'marcas'
  ) then
    raise exception 'INVALID_THEME';
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

  insert into public.rooms (code, created_by, expires_at, theme)
  values (p_code, auth.uid(), now() + interval '4 hours', v_theme)
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

-- Suggest from bank filtered by room theme
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
      and wb.theme = v_room.theme
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

-- Start round: lobby OR revealed (quick rematch); theme-aware bank + hint
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
  v_hint text;
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
  if v_room.status not in ('lobby', 'revealed') then
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
  v_hint := null;

  select pr.id, pr.text into v_proposal_id, v_word
  from public.proposals pr
  where pr.room_id = p_room_id and pr.used = false
  order by random()
  limit 1;

  if v_word is not null then
    v_source := 'proposal';
    update public.proposals set used = true where id = v_proposal_id;
    select wb.hint into v_hint
    from public.word_bank wb
    where lower(wb.text) = lower(v_word)
      and wb.theme = v_room.theme
    limit 1;
  else
    select wb.text, wb.hint into v_word, v_hint
    from public.word_bank wb
    where wb.active = true
      and wb.theme = v_room.theme
      and not (wb.text = any (v_room.used_words))
    order by random()
    limit 1;

    if v_word is null then
      select wb.text, wb.hint into v_word, v_hint
      from public.word_bank wb
      where wb.active = true
        and wb.theme = v_room.theme
      order by random()
      limit 1;
    end if;

    if v_word is null then
      raise exception 'EMPTY_BANK';
    end if;
    v_source := 'bank';
  end if;

  insert into public.rounds (room_id, word, word_source, theme_hint)
  values (p_room_id, v_word, v_source, v_hint)
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

create or replace function public.get_my_card(p_round_id uuid, p_player_id uuid)
returns table (is_impostor boolean, word text, hint text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player public.players%rowtype;
  v_role public.round_roles%rowtype;
  v_round public.rounds%rowtype;
begin
  select * into v_player from public.players where id = p_player_id;
  if not found or v_player.user_id <> auth.uid() then
    raise exception 'FORBIDDEN';
  end if;

  select * into v_role
  from public.round_roles
  where round_id = p_round_id and player_id = p_player_id;

  if not found then
    raise exception 'NO_ROLE';
  end if;

  select * into v_round from public.rounds where id = p_round_id;

  if v_role.is_impostor then
    return query select true, null::text, v_round.theme_hint;
  else
    return query select false, v_round.word, v_round.theme_hint;
  end if;
end;
$$;

-- Seed theme words (idempotent on text+theme via unique text — keep unique text globally)
-- Existing bank stays as rosario. New themes use distinct texts.

insert into public.word_bank (text, category, theme, hint, active) values
  -- Fútbol argentino actual
  ('Messi', 'futbol', 'futbol_ar_actual', null, true),
  ('Di María', 'futbol', 'futbol_ar_actual', null, true),
  ('Dibu Martínez', 'futbol', 'futbol_ar_actual', null, true),
  ('Enzo Fernández', 'futbol', 'futbol_ar_actual', null, true),
  ('Julián Álvarez', 'futbol', 'futbol_ar_actual', null, true),
  ('De Paul', 'futbol', 'futbol_ar_actual', null, true),
  ('Mac Allister', 'futbol', 'futbol_ar_actual', null, true),
  ('Lautaro Martínez', 'futbol', 'futbol_ar_actual', null, true),
  ('Scaloni', 'futbol', 'futbol_ar_actual', null, true),
  ('La Scaloneta', 'futbol', 'futbol_ar_actual', null, true),
  ('River Plate', 'futbol', 'futbol_ar_actual', null, true),
  ('Boca Juniors', 'futbol', 'futbol_ar_actual', null, true),
  ('Racing', 'futbol', 'futbol_ar_actual', null, true),
  ('Independiente', 'futbol', 'futbol_ar_actual', null, true),
  ('San Lorenzo', 'futbol', 'futbol_ar_actual', null, true),
  ('Estudiantes', 'futbol', 'futbol_ar_actual', null, true),
  ('Talleres', 'futbol', 'futbol_ar_actual', null, true),
  ('Belgrano', 'futbol', 'futbol_ar_actual', null, true),
  ('Newell''s', 'futbol', 'futbol_ar_actual', null, true),
  ('Central', 'futbol', 'futbol_ar_actual', null, true),
  ('VAR', 'futbol', 'futbol_ar_actual', null, true),
  ('El Monumental', 'futbol', 'futbol_ar_actual', null, true),
  ('La Bombonera', 'futbol', 'futbol_ar_actual', null, true),
  ('Copa de la Liga', 'futbol', 'futbol_ar_actual', null, true),
  ('El clásico', 'futbol', 'futbol_ar_actual', null, true),
  ('Un penal atajado', 'futbol', 'futbol_ar_actual', null, true),
  ('La tercera de Messi', 'futbol', 'futbol_ar_actual', null, true),
  ('Otamendi', 'futbol', 'futbol_ar_actual', null, true),
  ('Cuti Romero', 'futbol', 'futbol_ar_actual', null, true),
  ('Molina', 'futbol', 'futbol_ar_actual', null, true),

  -- Fútbol argentino histórico
  ('Maradona', 'futbol', 'futbol_ar_historico', null, true),
  ('Kempes', 'futbol', 'futbol_ar_historico', null, true),
  ('Passarella', 'futbol', 'futbol_ar_historico', null, true),
  ('Batistuta', 'futbol', 'futbol_ar_historico', null, true),
  ('Riquelme', 'futbol', 'futbol_ar_historico', null, true),
  ('Verón', 'futbol', 'futbol_ar_historico', null, true),
  ('Crespo', 'futbol', 'futbol_ar_historico', null, true),
  ('Ayala', 'futbol', 'futbol_ar_historico', null, true),
  ('Ruggeri', 'futbol', 'futbol_ar_historico', null, true),
  ('Fillol', 'futbol', 'futbol_ar_historico', null, true),
  ('Bilardo', 'futbol', 'futbol_ar_historico', null, true),
  ('Menotti', 'futbol', 'futbol_ar_historico', null, true),
  ('México 86', 'futbol', 'futbol_ar_historico', null, true),
  ('Argentina 78', 'futbol', 'futbol_ar_historico', null, true),
  ('La mano de Dios', 'futbol', 'futbol_ar_historico', null, true),
  ('El gol del siglo', 'futbol', 'futbol_ar_historico', null, true),
  ('Boquita', 'futbol', 'futbol_ar_historico', null, true),
  ('La Máquina', 'futbol', 'futbol_ar_historico', null, true),
  ('El Diego', 'futbol', 'futbol_ar_historico', null, true),
  ('Caniggia', 'futbol', 'futbol_ar_historico', null, true),
  ('Redondo', 'futbol', 'futbol_ar_historico', null, true),
  ('Simeone jugador', 'futbol', 'futbol_ar_historico', null, true),
  ('Francescoli', 'futbol', 'futbol_ar_historico', null, true),
  ('Bochini', 'futbol', 'futbol_ar_historico', null, true),
  ('Labruna', 'futbol', 'futbol_ar_historico', null, true),
  ('Moreno', 'futbol', 'futbol_ar_historico', null, true),
  ('Di Stéfano', 'futbol', 'futbol_ar_historico', null, true),
  ('El Monumental lleno en los 90', 'futbol', 'futbol_ar_historico', null, true),
  ('Copa América 93', 'futbol', 'futbol_ar_historico', null, true),
  ('Napoli de Maradona', 'futbol', 'futbol_ar_historico', null, true),

  -- Mundial (más europeo)
  ('Mbappé', 'mundial', 'mundial', null, true),
  ('Haaland', 'mundial', 'mundial', null, true),
  ('Bellingham', 'mundial', 'mundial', null, true),
  ('Vinicius', 'mundial', 'mundial', null, true),
  ('Salah', 'mundial', 'mundial', null, true),
  ('Kane', 'mundial', 'mundial', null, true),
  ('Modric', 'mundial', 'mundial', null, true),
  ('Cristiano Ronaldo', 'mundial', 'mundial', null, true),
  ('Real Madrid', 'mundial', 'mundial', null, true),
  ('Barcelona', 'mundial', 'mundial', null, true),
  ('Manchester City', 'mundial', 'mundial', null, true),
  ('Liverpool', 'mundial', 'mundial', null, true),
  ('Bayern', 'mundial', 'mundial', null, true),
  ('PSG', 'mundial', 'mundial', null, true),
  ('Champions League', 'mundial', 'mundial', null, true),
  ('Wembley', 'mundial', 'mundial', null, true),
  ('San Siro', 'mundial', 'mundial', null, true),
  ('Old Trafford', 'mundial', 'mundial', null, true),
  ('El Bernabéu', 'mundial', 'mundial', null, true),
  ('Zidane', 'mundial', 'mundial', null, true),
  ('Iniesta', 'mundial', 'mundial', null, true),
  ('Xavi', 'mundial', 'mundial', null, true),
  ('Ronaldinho', 'mundial', 'mundial', null, true),
  ('Beckham', 'mundial', 'mundial', null, true),
  ('Guardiola', 'mundial', 'mundial', null, true),
  ('Ancelotti', 'mundial', 'mundial', null, true),
  ('El tiki-taka', 'mundial', 'mundial', null, true),
  ('Un hat-trick', 'mundial', 'mundial', null, true),
  ('La final de Champions', 'mundial', 'mundial', null, true),
  ('El Balón de Oro', 'mundial', 'mundial', null, true),

  -- Marcas (con pista)
  ('Ferrari', 'marcas', 'marcas', 'Marca de autos', true),
  ('Toyota', 'marcas', 'marcas', 'Marca de autos', true),
  ('Ford', 'marcas', 'marcas', 'Marca de autos', true),
  ('Chevrolet', 'marcas', 'marcas', 'Marca de autos', true),
  ('Volkswagen', 'marcas', 'marcas', 'Marca de autos', true),
  ('Mercedes', 'marcas', 'marcas', 'Marca de autos', true),
  ('BMW', 'marcas', 'marcas', 'Marca de autos', true),
  ('Nike', 'marcas', 'marcas', 'Marca de ropa / deportes', true),
  ('Adidas', 'marcas', 'marcas', 'Marca de ropa / deportes', true),
  ('Puma', 'marcas', 'marcas', 'Marca de ropa / deportes', true),
  ('Apple', 'marcas', 'marcas', 'Marca de tecnología', true),
  ('Samsung', 'marcas', 'marcas', 'Marca de tecnología', true),
  ('Sony', 'marcas', 'marcas', 'Marca de tecnología', true),
  ('Coca-Cola', 'marcas', 'marcas', 'Marca de bebidas', true),
  ('Pepsi', 'marcas', 'marcas', 'Marca de bebidas', true),
  ('Quilmes', 'marcas', 'marcas', 'Marca de bebidas', true),
  ('Starbucks', 'marcas', 'marcas', 'Marca de café / comida', true),
  ('McDonald''s', 'marcas', 'marcas', 'Marca de café / comida', true),
  ('Burger King', 'marcas', 'marcas', 'Marca de café / comida', true),
  ('Marlboro', 'marcas', 'marcas', 'Marca de cigarrillos', true),
  ('Lucky Strike', 'marcas', 'marcas', 'Marca de cigarrillos', true),
  ('Philip Morris', 'marcas', 'marcas', 'Marca de cigarrillos', true),
  ('Chanel', 'marcas', 'marcas', 'Marca de lujo / moda', true),
  ('Louis Vuitton', 'marcas', 'marcas', 'Marca de lujo / moda', true),
  ('Rolex', 'marcas', 'marcas', 'Marca de lujo / moda', true),
  ('Nestlé', 'marcas', 'marcas', 'Marca de alimentos', true),
  ('Knorr', 'marcas', 'marcas', 'Marca de alimentos', true),
  ('Hellmann''s', 'marcas', 'marcas', 'Marca de alimentos', true),
  ('Ikea', 'marcas', 'marcas', 'Marca de hogar', true),
  ('Lego', 'marcas', 'marcas', 'Marca de juguetes', true)
on conflict (text) do update
set theme = excluded.theme,
    hint = excluded.hint,
    category = excluded.category,
    active = true;

revoke execute on function public.kick_player(uuid, uuid, uuid) from public, anon;
revoke execute on function public.set_room_theme(uuid, uuid, text) from public, anon;
revoke execute on function public.create_room(text, text, text) from public, anon;
revoke execute on function public.get_my_card(uuid, uuid) from public, anon;

grant execute on function public.kick_player(uuid, uuid, uuid) to authenticated;
grant execute on function public.set_room_theme(uuid, uuid, text) to authenticated;
grant execute on function public.create_room(text, text, text) to authenticated;
grant execute on function public.suggest_from_bank(uuid, uuid, int) to authenticated;
grant execute on function public.start_round(uuid, uuid) to authenticated;
grant execute on function public.get_my_card(uuid, uuid) to authenticated;
