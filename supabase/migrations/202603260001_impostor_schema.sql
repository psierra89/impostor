-- Impostor: schema, RLS, RPCs, word bank seed

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.rooms (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  host_player_id uuid,
  status text not null default 'lobby'
    check (status in ('lobby', 'playing', 'revealed')),
  current_round_id uuid,
  used_words text[] not null default '{}',
  created_at timestamptz not null default now()
);

create table public.players (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  nickname text not null check (char_length(trim(nickname)) between 2 and 20),
  is_active boolean not null default true,
  joined_at timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  unique (room_id, user_id)
);

alter table public.rooms
  add constraint rooms_host_player_id_fkey
  foreign key (host_player_id) references public.players (id) on delete set null;

create table public.word_bank (
  id uuid primary key default gen_random_uuid(),
  text text not null unique,
  category text not null default 'general',
  active boolean not null default true
);

create table public.proposals (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms (id) on delete cascade,
  author_player_id uuid references public.players (id) on delete set null,
  text text not null check (char_length(trim(text)) between 2 and 60),
  used boolean not null default false,
  from_bank boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.rounds (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms (id) on delete cascade,
  word text not null,
  word_source text not null check (word_source in ('proposal', 'bank')),
  winner text check (winner is null or winner in ('civilians', 'impostors')),
  started_at timestamptz not null default now(),
  ended_at timestamptz
);

alter table public.rooms
  add constraint rooms_current_round_id_fkey
  foreign key (current_round_id) references public.rounds (id) on delete set null;

create table public.round_roles (
  id uuid primary key default gen_random_uuid(),
  round_id uuid not null references public.rounds (id) on delete cascade,
  player_id uuid not null references public.players (id) on delete cascade,
  is_impostor boolean not null default false,
  unique (round_id, player_id)
);

create index players_room_id_idx on public.players (room_id);
create index proposals_room_id_idx on public.proposals (room_id);
create index rounds_room_id_idx on public.rounds (room_id);
create index round_roles_round_id_idx on public.round_roles (round_id);
create index rooms_code_idx on public.rooms (code);

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

create or replace function public.is_room_member(p_room_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.players p
    where p.room_id = p_room_id
      and p.user_id = auth.uid()
      and p.is_active = true
  );
$$;

create or replace function public.is_round_revealed(p_round_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.rounds r
    join public.rooms rm on rm.id = r.room_id
    where r.id = p_round_id
      and rm.status = 'revealed'
      and rm.current_round_id = p_round_id
  );
$$;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------

alter table public.rooms enable row level security;
alter table public.players enable row level security;
alter table public.word_bank enable row level security;
alter table public.proposals enable row level security;
alter table public.rounds enable row level security;
alter table public.round_roles enable row level security;

create policy rooms_select_member on public.rooms
  for select to authenticated
  using (public.is_room_member(id));

create policy players_select_same_room on public.players
  for select to authenticated
  using (public.is_room_member(room_id));

create policy players_update_self on public.players
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- word_bank: no direct client reads (RPCs only)
-- proposals: no direct text reads; count via RPC

create policy rounds_select_member on public.rounds
  for select to authenticated
  using (
    public.is_room_member(room_id)
    and (
      exists (
        select 1 from public.rooms rm
        where rm.id = room_id and rm.status = 'revealed' and rm.current_round_id = rounds.id
      )
    )
  );

create policy round_roles_select_own_or_revealed on public.round_roles
  for select to authenticated
  using (
    exists (
      select 1
      from public.players p
      where p.id = round_roles.player_id
        and p.user_id = auth.uid()
    )
    or public.is_round_revealed(round_id)
  );

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------

create or replace function public.create_room(p_code text, p_nickname text)
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
  if auth.uid() is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if char_length(v_nick) < 2 or char_length(v_nick) > 20 then
    raise exception 'INVALID_NICKNAME';
  end if;
  if p_code !~ '^[A-Z0-9]{6}$' then
    raise exception 'INVALID_CODE';
  end if;

  insert into public.rooms (code) values (p_code)
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

  if v_room.status <> 'lobby' then
    -- allow reconnect of existing player even mid-game
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

create or replace function public.leave_room(p_player_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player public.players%rowtype;
  v_new_host uuid;
begin
  select * into v_player from public.players where id = p_player_id;
  if not found then
    return;
  end if;
  if v_player.user_id <> auth.uid() then
    raise exception 'FORBIDDEN';
  end if;

  update public.players
  set is_active = false, last_seen = now()
  where id = p_player_id;

  if exists (
    select 1 from public.rooms r
    where r.id = v_player.room_id and r.host_player_id = p_player_id
  ) then
    select p.id into v_new_host
    from public.players p
    where p.room_id = v_player.room_id
      and p.is_active = true
      and p.id <> p_player_id
    order by p.joined_at asc
    limit 1;

    update public.rooms
    set host_player_id = v_new_host
    where id = v_player.room_id;
  end if;
end;
$$;

create or replace function public.get_pool_count(p_room_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_room_member(p_room_id) then
    raise exception 'FORBIDDEN';
  end if;

  return (
    select count(*)::int
    from public.proposals
    where room_id = p_room_id and used = false
  );
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
begin
  select * into v_player from public.players where id = p_player_id;
  if not found or v_player.user_id <> auth.uid() or v_player.room_id <> p_room_id then
    raise exception 'FORBIDDEN';
  end if;
  if char_length(v_text) < 2 or char_length(v_text) > 60 then
    raise exception 'INVALID_PROPOSAL';
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
begin
  select * into v_player from public.players where id = p_player_id;
  if not found or v_player.user_id <> auth.uid() or v_player.room_id <> p_room_id then
    raise exception 'FORBIDDEN';
  end if;

  select * into v_room from public.rooms where id = p_room_id;

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

create or replace function public.get_my_card(p_round_id uuid, p_player_id uuid)
returns table (is_impostor boolean, word text)
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
    return query select true, null::text;
  else
    return query select false, v_round.word;
  end if;
end;
$$;

create or replace function public.end_round(
  p_room_id uuid,
  p_player_id uuid,
  p_winner text
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
  select * into v_room from public.rooms where id = p_room_id;

  if not found or v_player.user_id <> auth.uid() then
    raise exception 'FORBIDDEN';
  end if;
  if v_room.host_player_id <> p_player_id then
    raise exception 'NOT_HOST';
  end if;
  if v_room.status <> 'playing' then
    raise exception 'WRONG_STATUS';
  end if;
  if p_winner not in ('civilians', 'impostors') then
    raise exception 'INVALID_WINNER';
  end if;

  update public.rounds
  set winner = p_winner, ended_at = now()
  where id = v_room.current_round_id;

  update public.rooms
  set status = 'revealed'
  where id = p_room_id;
end;
$$;

create or replace function public.return_to_lobby(p_room_id uuid, p_player_id uuid)
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
  select * into v_room from public.rooms where id = p_room_id;

  if not found or v_player.user_id <> auth.uid() then
    raise exception 'FORBIDDEN';
  end if;
  if v_room.host_player_id <> p_player_id then
    raise exception 'NOT_HOST';
  end if;
  if v_room.status <> 'revealed' then
    raise exception 'WRONG_STATUS';
  end if;

  update public.rooms
  set status = 'lobby',
      current_round_id = null
  where id = p_room_id;
end;
$$;

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
grant execute on function public.is_room_member(uuid) to authenticated;
grant execute on function public.is_round_revealed(uuid) to authenticated;

grant select on public.rooms to authenticated;
grant select, update on public.players to authenticated;
grant select on public.rounds to authenticated;
grant select on public.round_roles to authenticated;

-- ---------------------------------------------------------------------------
-- Word bank seed (Rosario / 30-40 / humor y picardía)
-- ---------------------------------------------------------------------------

insert into public.word_bank (text, category) values
  ('El Monumento', 'rosario'),
  ('La Florida', 'rosario'),
  ('Pichincha de madrugada', 'rosario'),
  ('El Rusi', 'rosario'),
  ('Costanera al atardecer', 'rosario'),
  ('Fisherton un domingo', 'rosario'),
  ('El Puente Rosario-Victoria', 'rosario'),
  ('Patio de la Madera', 'rosario'),
  ('Barrio Martin', 'rosario'),
  ('El Parque Independencia', 'rosario'),
  ('La peatonal Córdoba', 'rosario'),
  ('Un choripán en la costanera', 'comida'),
  ('El asado del domingo', 'comida'),
  ('Mate amargo a las 7', 'comida'),
  ('Facturas del chino', 'comida'),
  ('Una milanesa a caballo', 'comida'),
  ('Fernet con Coca', 'comida'),
  ('La birra de after', 'comida'),
  ('Pizza de mozzarella a las 2 AM', 'comida'),
  ('Un vinito en la terraza', 'comida'),
  ('El vacío a punto', 'comida'),
  ('Newell''s vs Central', 'futbol'),
  ('La lepra en cancha', 'futbol'),
  ('El canalla en el Gigante', 'futbol'),
  ('El clásico rosarino', 'futbol'),
  ('Messi en la selección', 'futbol'),
  ('Di María volviendo a Rosario', 'futbol'),
  ('El VAR polémico', 'futbol'),
  ('La previa en el boliche', 'social'),
  ('El after office del viernes', 'social'),
  ('WhatsApp de los pibes', 'social'),
  ('El grupo de asado eterno', 'social'),
  ('La juntada que arranca a las 22', 'social'),
  ('El amigo que nunca llega', 'social'),
  ('La excusa del "estoy saliendo"', 'social'),
  ('El que invita y no paga', 'social'),
  ('Storie falsa en la playa', 'social'),
  ('El ex que aparece en stories', 'picardía'),
  ('Match de Tinder en Rosario', 'picardía'),
  ('El like a las 3 AM', 'picardía'),
  ('La amiga de la jermu', 'picardía'),
  ('El "vamos a tomar algo"', 'picardía'),
  ('El plan B del sábado', 'picardía'),
  ('La pelea por el control remoto', 'picardía'),
  ('Dormir en el sillón', 'picardía'),
  ('La siesta sagrada', 'vida'),
  ('El laburo híbrido', 'vida'),
  ('Reunión de Zoom con cámara off', 'vida'),
  ('El jefe en Slack a las 19', 'vida'),
  ('La cuota del auto', 'vida'),
  ('El AUH del vecino', 'vida'),
  ('Mercado Libre y el delivery', 'vida'),
  ('PedidosYa en pijama', 'vida'),
  ('Netflix y la cuenta compartida', 'vida'),
  ('El gimnasio que pagás y no vas', 'vida'),
  ('La dieta que dura hasta el viernes', 'vida'),
  ('El cumple de 40 en el quincho', 'vida'),
  ('El bautismo del sobrino', 'vida'),
  ('La suegra de visita', 'vida'),
  ('El cuñado opinólogo', 'vida'),
  ('Vacaciones en Carlos Paz', 'vida'),
  ('Un finde en San Lorenzo', 'rosario'),
  ('La pile del country', 'vida'),
  ('El quilombo del peaje', 'vida'),
  ('La inflación del almacén', 'vida'),
  ('El dólar blue del muchacho', 'vida'),
  ('La bici en la peatonal', 'rosario'),
  ('Un bondi de la 101', 'rosario'),
  ('El Uber que cancela', 'vida'),
  ('La pileta del club', 'vida'),
  ('El partido de paddle', 'vida'),
  ('El fútbol 5 de los jueves', 'futbol'),
  ('La lesión inventada', 'futbol'),
  ('El arquero de los pibes', 'futbol'),
  ('La camiseta del 2010', 'futbol'),
  ('El DT del grupo de WhatsApp', 'futbol'),
  ('La profe de yoga de la jermu', 'picardía'),
  ('El peluquero que sabe de más', 'picardía'),
  ('La vecina del 3° B', 'picardía'),
  ('El secreto del asado', 'comida'),
  ('La ensalada que nadie come', 'comida'),
  ('El pan casero de Instagram', 'comida'),
  ('El café de especialidad', 'comida'),
  ('La cervecería de Pichincha', 'rosario'),
  ('Un show en el Teatro El Círculo', 'rosario'),
  ('La feria de Alberdi', 'rosario'),
  ('El río un día de calor', 'rosario'),
  ('La isla antequeras', 'rosario'),
  ('El recital en el Hipódromo', 'rosario'),
  ('La previa en el auto', 'social'),
  ('El que maneja de vuelta', 'social'),
  ('La playlist del asado', 'social'),
  ('El karaoke vergonzoso', 'social'),
  ('El cumple sorpresa fallido', 'social'),
  ('La foto del grupo del cole', 'social'),
  ('El reencuentro de la secundaria', 'social'),
  ('El que se casó primero', 'social'),
  ('El que todavía vive con los viejos', 'picardía'),
  ('La crisis de los 35', 'vida'),
  ('El checkeo médico anual', 'vida'),
  ('Las gafas para ver de cerca', 'vida'),
  ('El dolor de espalda del office', 'vida')
on conflict (text) do nothing;
