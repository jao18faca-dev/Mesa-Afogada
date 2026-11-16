-- Maré Baixa · tirar fichas da mesa e esconder fichas dos outros jogadores
-- Cole no SQL Editor do Supabase e clique em Run. Pode rodar de novo sem medo.
-- Ficha escondida: só o dono e o Mestre da mesa veem. Tirar da mesa: o dono ou o Mestre.

alter table public.fichas add column if not exists escondida boolean not null default false;

drop policy if exists fichas_ler on public.fichas;
create policy fichas_ler on public.fichas for select to authenticated
  using (dono = auth.uid() or (mesa_id is not null and (public.e_mestre(mesa_id) or (not escondida and public.e_membro(mesa_id)))));

create or replace function public.ve_ficha(f uuid) returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from fichas fi where fi.id = f and (fi.dono = auth.uid()
    or (fi.mesa_id is not null and (public.e_mestre(fi.mesa_id) or (not fi.escondida and public.e_membro(fi.mesa_id))))));
$$;

create or replace function public.tirar_da_mesa(f uuid) returns void
language plpgsql security definer set search_path = public as $$
declare d uuid; m uuid;
begin
  select dono, mesa_id into d, m from fichas where id = f;
  if d is null then raise exception 'ficha não encontrada'; end if;
  if not (d = auth.uid() or (m is not null and public.e_mestre(m))) then raise exception 'sem permissão'; end if;
  update fichas set mesa_id = null, escondida = false, atualizado = now() where id = f;
end $$;

revoke execute on function public.tirar_da_mesa(uuid), public.ve_ficha(uuid) from public, anon;
grant execute on function public.tirar_da_mesa(uuid), public.ve_ficha(uuid) to authenticated;
