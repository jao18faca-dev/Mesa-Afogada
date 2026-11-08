-- Maré Baixa · tabuleiro de combate
-- Cole no SQL Editor do Supabase e clique em Run (depois do setup.sql). Pode rodar de novo sem medo.

-- ------------------------------------------------------------ tabelas
-- um tabuleiro por mesa. terreno e névoa: uma letra por quadrado, linha por linha.
--   terreno: . vazio · a água · d difícil · c cobertura · p parede
--   névoa:   0 aberto · 1 coberto
create table if not exists public.tabuleiros (
  mesa_id uuid primary key references public.mesas on delete cascade,
  cols int not null default 24 check (cols between 4 and 80),
  linhas int not null default 16 check (linhas between 4 and 80),
  terreno text not null default '',
  nevoa text not null default '',
  turno jsonb not null default '{}'::jsonb,
  fundo_versao int not null default 0,
  versao bigint not null default 0,
  atualizado timestamptz not null default now()
);

-- a imagem de fundo fica numa tabela à parte, para a consulta de todo segundo continuar leve
create table if not exists public.tabuleiro_fundo (
  mesa_id uuid primary key references public.mesas on delete cascade,
  imagem text not null default '' check (length(imagem) < 4000000),
  atualizado timestamptz not null default now()
);

create table if not exists public.pecas (
  id uuid primary key default gen_random_uuid(),
  mesa_id uuid not null references public.mesas on delete cascade,
  ficha_id uuid references public.fichas on delete cascade,
  nome text not null default '',
  tipo text not null default 'inimigo' check (tipo in ('pj', 'inimigo', 'aliado', 'objeto')),
  cor text not null default '#c0392d',
  x int not null default 0,
  y int not null default 0,
  tam int not null default 1 check (tam between 1 and 4),
  oculta boolean not null default false,
  chefe boolean not null default false,
  pv int,
  pv_max int,
  atualizado timestamptz not null default now()
);
create index if not exists pecas_mesa on public.pecas (mesa_id);

-- áreas de mantra que alguém pôs no tabuleiro (raio, cone ou linha)
create table if not exists public.marcas (
  id uuid primary key default gen_random_uuid(),
  mesa_id uuid not null references public.mesas on delete cascade,
  autor uuid not null default auth.uid() references auth.users on delete cascade,
  forma text not null check (forma in ('circulo', 'cone', 'linha')),
  x real not null, y real not null,
  ax real not null, ay real not null,
  metros real not null check (metros > 0 and metros <= 60),
  cor text not null default '#3fb3d2',
  rotulo text not null default '',
  criado timestamptz not null default now()
);
create index if not exists marcas_mesa on public.marcas (mesa_id);

alter table public.tabuleiros enable row level security;
alter table public.tabuleiro_fundo enable row level security;
alter table public.pecas enable row level security;
alter table public.marcas enable row level security;

-- ------------------------------------------------------------ quem é quem
create or replace function public.dono_da_ficha(f uuid) returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from fichas where id = f and dono = auth.uid());
$$;

-- o quadrado (px, py) está debaixo da névoa?
create or replace function public.na_nevoa(m uuid, px int, py int) returns boolean
language sql security definer stable set search_path = public as $$
  select coalesce((select px >= 0 and py >= 0 and px < t.cols and substr(t.nevoa, py * t.cols + px + 1, 1) = '1'
                   from tabuleiros t where t.mesa_id = m), false);
$$;

-- ------------------------------------------------------------ regras de acesso
drop policy if exists tb_ler on public.tabuleiros;
drop policy if exists tb_mestre on public.tabuleiros;
create policy tb_ler on public.tabuleiros for select to authenticated using (public.e_membro(mesa_id));
create policy tb_mestre on public.tabuleiros for all to authenticated using (public.e_mestre(mesa_id)) with check (public.e_mestre(mesa_id));

drop policy if exists tbf_ler on public.tabuleiro_fundo;
drop policy if exists tbf_mestre on public.tabuleiro_fundo;
create policy tbf_ler on public.tabuleiro_fundo for select to authenticated using (public.e_membro(mesa_id));
create policy tbf_mestre on public.tabuleiro_fundo for all to authenticated using (public.e_mestre(mesa_id)) with check (public.e_mestre(mesa_id));

-- o jogador não recebe peças ocultas nem peças debaixo da névoa (a dele ele sempre vê)
drop policy if exists pecas_ler on public.pecas;
drop policy if exists pecas_mestre on public.pecas;
create policy pecas_ler on public.pecas for select to authenticated using (
  public.e_mestre(mesa_id)
  or (public.e_membro(mesa_id) and (
        (ficha_id is not null and public.dono_da_ficha(ficha_id))
     or (not oculta and not public.na_nevoa(mesa_id, x, y)))));
create policy pecas_mestre on public.pecas for all to authenticated using (public.e_mestre(mesa_id)) with check (public.e_mestre(mesa_id));

drop policy if exists marcas_ler on public.marcas;
drop policy if exists marcas_criar on public.marcas;
drop policy if exists marcas_apagar on public.marcas;
create policy marcas_ler on public.marcas for select to authenticated using (public.e_membro(mesa_id));
create policy marcas_criar on public.marcas for insert to authenticated with check (autor = auth.uid() and public.e_membro(mesa_id));
create policy marcas_apagar on public.marcas for delete to authenticated using (autor = auth.uid() or public.e_mestre(mesa_id));

-- ------------------------------------------------------------ ações
-- o jogador move a própria peça; o Mestre move qualquer uma
create or replace function public.mover_peca(p uuid, nx int, ny int) returns void
language plpgsql security definer set search_path = public as $$
declare pe pecas; t tabuleiros;
begin
  select * into pe from pecas where id = p;
  if pe.id is null then raise exception 'peça não encontrada'; end if;
  if not (public.e_mestre(pe.mesa_id) or (pe.ficha_id is not null and public.dono_da_ficha(pe.ficha_id))) then raise exception 'sem permissão'; end if;
  select * into t from tabuleiros where mesa_id = pe.mesa_id;
  update pecas set x = greatest(0, least(coalesce(t.cols, 80) - pe.tam, nx)),
                   y = greatest(0, least(coalesce(t.linhas, 80) - pe.tam, ny)),
                   atualizado = now()
  where id = p;
end $$;

-- ritmo (rápido ou lento), PA que sobram e "passei a vez" de uma peça
create or replace function public.turno_peca(p uuid, ritmo text default null, pa int default null, feito boolean default null) returns void
language plpgsql security definer set search_path = public as $$
declare pe pecas; k text := p::text;
begin
  select * into pe from pecas where id = p;
  if pe.id is null then raise exception 'peça não encontrada'; end if;
  if not (public.e_mestre(pe.mesa_id) or (pe.ficha_id is not null and public.dono_da_ficha(pe.ficha_id))) then raise exception 'sem permissão'; end if;
  if ritmo is not null and ritmo not in ('rapido', 'lento') then raise exception 'ritmo inválido'; end if;
  update tabuleiros set turno = turno
      || case when ritmo is null then '{}'::jsonb else jsonb_build_object('ritmo', coalesce(turno -> 'ritmo', '{}'::jsonb) || jsonb_build_object(k, ritmo)) end
      || case when pa is null then '{}'::jsonb else jsonb_build_object('pa', coalesce(turno -> 'pa', '{}'::jsonb) || jsonb_build_object(k, greatest(0, least(3, pa)))) end
      || case when feito is null then '{}'::jsonb else jsonb_build_object('feito', coalesce(turno -> 'feito', '{}'::jsonb) || jsonb_build_object(k, feito)) end
  where mesa_id = pe.mesa_id;
end $$;

-- o Mestre muda partes do turno sem apagar o que os jogadores acabaram de escolher
create or replace function public.turno_mudar(m uuid, chaves jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.e_mestre(m) then raise exception 'sem permissão'; end if;
  update tabuleiros set turno = turno || chaves where mesa_id = m;
end $$;

-- ------------------------------------------------------------ versão: quem está olhando só baixa o tabuleiro quando algo mudou
create or replace function public.tb_versao() returns trigger
language plpgsql as $$
begin
  new.versao := old.versao + 1;
  new.atualizado := now();
  return new;
end $$;
drop trigger if exists tb_versao on public.tabuleiros;
create trigger tb_versao before update on public.tabuleiros for each row execute function public.tb_versao();

create or replace function public.tb_mexeu() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name = 'tabuleiro_fundo' then
    update tabuleiros set fundo_versao = fundo_versao + 1 where mesa_id = coalesce(new.mesa_id, old.mesa_id);
  else
    update tabuleiros set atualizado = now() where mesa_id = coalesce(new.mesa_id, old.mesa_id);
  end if;
  return null;
end $$;
drop trigger if exists pecas_mexeu on public.pecas;
create trigger pecas_mexeu after insert or update or delete on public.pecas for each row execute function public.tb_mexeu();
drop trigger if exists marcas_mexeu on public.marcas;
create trigger marcas_mexeu after insert or update or delete on public.marcas for each row execute function public.tb_mexeu();
drop trigger if exists fundo_mexeu on public.tabuleiro_fundo;
create trigger fundo_mexeu after insert or update or delete on public.tabuleiro_fundo for each row execute function public.tb_mexeu();

-- ------------------------------------------------------------ permissões da API
revoke all on public.tabuleiros, public.tabuleiro_fundo, public.pecas, public.marcas from anon;
grant select, insert, update, delete on public.tabuleiros, public.tabuleiro_fundo, public.pecas, public.marcas to authenticated;
revoke execute on function public.dono_da_ficha(uuid), public.na_nevoa(uuid, int, int), public.mover_peca(uuid, int, int),
  public.turno_peca(uuid, text, int, boolean), public.turno_mudar(uuid, jsonb) from public, anon;
grant execute on function public.dono_da_ficha(uuid), public.na_nevoa(uuid, int, int), public.mover_peca(uuid, int, int),
  public.turno_peca(uuid, text, int, boolean), public.turno_mudar(uuid, jsonb) to authenticated;
