# Maré Baixa

Site da mesa de **Deep Tales**: o Livro Profano (versão dos jogadores), fichas online com login de e-mail e senha, e mesas onde o Mestre vê e mexe nas fichas e entrega itens.

## Como pôr no ar
1. **Supabase → SQL Editor:** cole o conteúdo de `supabase/setup.sql` e clique em **Run**.
2. **Supabase → Authentication → Sign In / Providers → Email:** ligue **Enable Email provider** e desligue **Confirm email**. (O e-mail padrão do Supabase só entrega para quem é do time do projeto, 2 por hora; com a confirmação ligada, os jogadores nunca recebem o link.)
3. **Supabase → Authentication → URL Configuration:** em **Site URL**, ponha o endereço do site, e adicione o mesmo endereço em **Redirect URLs**. É para onde voltam os links de troca de senha.
4. **Opcional, para "Esqueci a senha" funcionar com os jogadores:** em *Authentication → Emails → SMTP Settings*, ligue um SMTP próprio (Resend, Brevo e outros têm plano grátis).
5. **Cloudflare → Workers & Pages:** o projeto `mare-baixa` lê este repositório e publica a pasta `public/` (veja `wrangler.jsonc`). O site fica em `https://mare-baixa.<sua-conta>.workers.dev`.

## Como funciona
- Cada pessoa cria a conta com nome na mesa, e-mail e senha (mínimo 6 letras), e depois entra com e-mail e senha.
- **Fichas:** cada jogador cria as suas e escolhe em qual mesa cada uma joga.
- **Mesas:** o Mestre cria a mesa e passa o código. Na mesa ele vê as fichas de todos, abre qualquer uma para mexer, e dá itens do catálogo (armas, Trajes, Peças, consumíveis e itens que ele mesmo criar).
- As telas se atualizam sozinhas a cada poucos segundos.
- Senha esquecida: **Esqueci a senha** manda um link por e-mail (precisa do SMTP do passo 4). Sem SMTP, o Mestre pode apagar a conta em *Authentication → Users*, e a pessoa cria de novo (as fichas da conta apagada somem junto).
- **Mãos de talento:** a ficha conta os talentos que faltam e sorteia duas mãos de 5 cartas por nível (4 Comuns e 1 Rara em cada) com os requisitos já conferidos.

`public/index.html` é gerado a partir do livro; não edite à mão.
- **Juramento e Badaladas:** só o Mestre anota, pela mesa ou abrindo a ficha do jogador. O jogador vê o Juramento depois que o Mestre anota, e nunca vê as Badaladas. Rode `supabase/segredos.sql` uma vez no SQL Editor (já está no fim do `setup.sql` para quem for instalar do zero).
- **Tabuleiro:** cada mesa tem um mapa de combate (botão *Abrir o tabuleiro* na mesa, ou *Tabuleiro* na ficha). Quadrados de 1,5 m. O Mestre põe os personagens e os inimigos, envia uma imagem de fundo ou pinta terreno (água, difícil, cobertura, parede), cobre partes com névoa e conduz a ordem dos turnos (rodada 1 por Iniciativa; depois rápido, inimigos, lento; o Chefe age duas vezes). Cada jogador arrasta a própria peça, gasta os próprios PA, escolhe rápido ou lento e passa a vez. Todos têm régua e áreas de mantra (raio, cone, linha) que mostram quem fica dentro. Peças escondidas ou debaixo da névoa não chegam ao jogador nem pela API. Rode `supabase/tabuleiro.sql` uma vez no SQL Editor (já está no fim do `setup.sql`).
