# Arquitetura de Dados e Contextos Delimitados em um ERP

Entregável de Banco de Dados — Semana 13

Projeto de arquitetura de dados para um ERP de e-commerce, dividido em três contextos delimitados (*bounded contexts*) com **persistência poliglota**: cada contexto usa o SGBD que melhor atende ao seu padrão de acesso e à sua necessidade de consistência.

---

## Sumário

- [Parte 1 — Desenho da Arquitetura e Contextos](#parte-1--desenho-da-arquitetura-e-contextos)
- [Parte 2 — Mini Projeto (Modelagem e Scripts)](#parte-2--mini-projeto-modelagem-e-scripts)
- [Parte 3 — Integração Assíncrona e Transação com ROLLBACK](#parte-3--integração-assíncrona-e-transação-com-rollback)
- [Parte 4 — Reflexão: Persistência Poliglota](#parte-4--reflexão-persistência-poliglota)
- [Como executar](#como-executar)
- [Estrutura do repositório](#estrutura-do-repositório)

---

## Parte 1 — Desenho da Arquitetura e Contextos

### Visão geral

```
                            ┌──────────────────────────┐
                            │      CLIENTE / APP       │
                            └────────────┬─────────────┘
                                         │
         ┌───────────────────────────────┼───────────────────────────────┐
         │                               │                               │
┌────────▼─────────┐          ┌──────────▼─────────┐          ┌──────────▼─────────┐
│     VENDAS       │          │      ESTOQUE       │          │    FINANCEIRO      │
│                  │          │                    │          │                    │
│      Redis       │          │      MongoDB       │          │    PostgreSQL      │
│  chave-valor     │          │    documentos      │          │    relacional      │
│                  │          │                    │          │                    │
│ Carrinho         │          │ Produto            │          │ Fatura             │
│ Sessao           │          │ Movimentacao       │          │ Cliente            │
│ Reserva          │          │ Deposito           │          │ Pagamento          │
│                  │          │                    │          │                    │
│ CAP: AP          │          │ CAP: AP            │          │ CAP: CP            │
│ latencia < 1ms   │          │ esquema flexivel   │          │ ACID obrigatorio   │
└────────┬─────────┘          └──────────▲─────────┘          └──────────▲─────────┘
         │                               │                               │
         │  evento venda.finalizada      │                               │
         └───────────────────────────────┴───────────────────────────────┘
                        (Message Broker — integração assíncrona)
```

### Os limites de cada contexto

A divisão não é técnica, é **de domínio**. Cada contexto responde a uma pergunta de negócio diferente e, por isso, cada um é dono dos seus próprios dados. Nenhum contexto escreve direto no banco do outro — a comunicação acontece por eventos.

| | **Vendas** | **Estoque** | **Financeiro** |
|---|---|---|---|
| **Pergunta de negócio** | "O que o cliente quer comprar agora?" | "Isto existe e quanto tem?" | "Quanto entrou, quanto falta receber?" |
| **SGBD** | Redis | MongoDB | PostgreSQL |
| **Modelo** | Chave-valor / cache em memória | Documentos | Relacional |
| **Entidades** | `Carrinho`, `Sessao`, `Reserva` | `Produto`, `Movimentacao`, `Deposito` | `Fatura`, `Cliente`, `Pagamento` |
| **Vida do dado** | Minutos a horas (efêmero) | Meses a anos | Permanente (obrigação legal) |
| **Leitura / escrita** | Escrita altíssima, leitura altíssima | Leitura alta, escrita média | Escrita baixa, leitura média |
| **Consistência** | Eventual | Eventual | **Forte (ACID)** |
| **Teorema CAP** | AP | AP | **CP** |
| **Custo de perder 1 registro** | Baixo — o cliente remonta o carrinho | Médio — recontagem de inventário | **Inaceitável** — problema contábil e fiscal |

---

### 🔵 Contexto Financeiro → PostgreSQL (Relacional)

**Entidades principais:** `Fatura`, `Cliente`, `Pagamento`

**Por que relacional:**

1. **Transações ACID são obrigatórias.** Debitar o saldo do cliente e emitir a fatura são duas operações que precisam acontecer juntas ou não acontecer. Se o sistema cair no meio, não pode existir "dinheiro debitado sem fatura emitida". O `BEGIN / COMMIT / ROLLBACK` do PostgreSQL resolve isso nativamente — e é exatamente o que o script [`financeiro/03_transacao_saldo_rollback.sql`](financeiro/03_transacao_saldo_rollback.sql) demonstra.

2. **O esquema é estável e deve ser rígido.** Uma fatura tem sempre valor, cliente, emissão e vencimento. Flexibilidade de esquema aqui não é vantagem, é **risco**: uma fatura sem valor é um bug contábil. Por isso o modelo usa `NOT NULL`, `CHECK (valor_total > 0)`, `CHECK (saldo >= 0)` e chaves estrangeiras como barreira de integridade dentro do próprio banco.

3. **As consultas são agregações e junções.** "Total faturado no mês", "inadimplência por cliente", "conciliação fatura × pagamento". `SUM`, `GROUP BY` e `JOIN` sobre um esquema normalizado são o terreno onde o relacional é insuperável.

4. **Auditoria e conformidade fiscal.** O dado financeiro precisa ser rastreável e imutável. Esquema versionado e log de transações atendem exigências de auditoria que um banco schemaless não atende com a mesma facilidade.

**CAP: CP.** Diante de uma partição de rede, este contexto prefere **recusar a operação** a devolver um saldo desatualizado. Indisponibilidade momentânea é um incômodo; saldo errado é prejuízo.

---

### 🟢 Contexto de Estoque → MongoDB (NoSQL — Documentos)

**Entidades principais:** `Produto`, `Movimentacao`, `Deposito`

**Por que documentos:**

1. **Flexibilidade de esquema resolve um problema real do catálogo.** No estoque de uma loja de eletrônicos, um **celular** tem cerca de 20 atributos (tela, taxa de atualização, bateria, RAM, câmera, chipset, resistência à água, peso…). Uma **camiseta** tem 6 (cor, tamanho, composição, gramatura, modelagem, lavagem). Um **cabo HDMI** tem 2 (comprimento, versão).

   No modelo relacional isso teria duas saídas ruins:
   - **Uma tabela por categoria** (`especificacoes_celular`, `especificacoes_vestuario`, `especificacoes_cabo`…) — cada nova categoria exige migração de banco e um `JOIN` novo em toda consulta de catálogo;
   - **Uma tabela genérica EAV** (`produto_id`, `atributo`, `valor`) — transforma "mostrar um produto" em dezenas de linhas a pivotar, perde tipagem e destrói o desempenho.

   No modelo de documentos, cada produto carrega seu próprio formato no campo `especificacoes` e **nenhuma migração é necessária** para lançar uma categoria nova. O script [`estoque/produtos.js`](estoque/produtos.js) mostra os três produtos convivendo com estruturas completamente diferentes na mesma coleção.

2. **O agregado é lido inteiro.** A tela de produto precisa de nome, preço, especificações, dimensões e saldo — tudo de uma vez. No documento isso é **uma leitura**, sem junção.

3. **A baixa de estoque é atômica no documento.** `$inc` em um único documento é atômico no MongoDB. Combinado com o filtro `{"estoque.quantidade": {$gte: n}}`, garante que a baixa só ocorre se houver saldo — sem transação distribuída.

**CAP: AP.** O catálogo pode exibir "últimas unidades" com alguns segundos de atraso sem prejuízo. Disponibilidade da vitrine vale mais que exatidão instantânea do contador.

---

### 🔴 Contexto de Vendas → Redis (NoSQL — Chave-Valor / Cache)

**Entidades principais:** `Carrinho`, `Sessao`, `Reserva`

**Por que chave-valor em memória:**

1. **Baixa latência é requisito de conversão.** O carrinho é lido e reescrito a **cada clique**: adicionar item, mudar quantidade, aplicar cupom, recarregar a página. São milhares de operações por minuto nos picos. O Redis opera em memória e responde em microssegundos; o mesmo volume de escrita em disco relacional geraria contenção de locks e travaria o checkout.

2. **O dado é descartável e o TTL resolve isso sozinho.** Cerca de 70% dos carrinhos são abandonados e nunca viram pedido. Persistir isso em tabela significa gravar em disco, indexar e depois rodar um *job* de limpeza para apagar lixo. No Redis, `EXPIRE carrinho:usr:4471 86400` faz o carrinho **expirar sozinho** em 24h — sem rotina de limpeza, sem tabela inflando.

3. **O acesso é sempre por chave conhecida.** Nunca se consulta "todos os carrinhos com camiseta preta". Sempre é "o carrinho **deste** usuário". É o padrão de acesso exato para o qual o modelo chave-valor foi desenhado — `O(1)`.

4. **A estrutura de dados certa para cada caso.** `HASH` para o carrinho (altera um item com `HINCRBY` sem reescrever o resto), `SET … EX … NX` para a reserva anti-*oversell* de 10 minutos, `ZSET` para o ranking de mais vendidos em tempo real, `STREAM` para publicar o evento de venda finalizada.

**CAP: AP.** Perder um carrinho irrita o cliente; indisponibilizar o checkout perde a venda. Disponibilidade e performance vencem.

---

## Parte 2 — Mini Projeto (Modelagem e Scripts)

| Contexto | Arquivo | O que faz |
|---|---|---|
| Financeiro | [`financeiro/01_schema_faturas.sql`](financeiro/01_schema_faturas.sql) | Cria `clientes`, `faturas` e `pagamentos` com constraints de integridade; insere os 2 registros de fatura dentro de uma transação |
| Financeiro | [`financeiro/02_consultas.sql`](financeiro/02_consultas.sql) | Consulta com `SUM(valor_total)` do total faturado, total por status, faturamento por cliente (`JOIN`), série mensal e conciliação |
| Financeiro | [`financeiro/03_transacao_saldo_rollback.sql`](financeiro/03_transacao_saldo_rollback.sql) | **Bônus:** transação que falha e sofre `ROLLBACK` quando o saldo é insuficiente |
| Estoque | [`estoque/produtos.js`](estoque/produtos.js) | Coleção `produtos` com documentos de **atributos variáveis** (celular, camiseta, cabo), índices esparsos, *aggregation* e baixa de estoque atômica |
| Vendas | [`vendas/carrinho.redis`](vendas/carrinho.redis) | Sessão e carrinho em `HASH` com **TTL**, reserva de estoque, ranking `ZSET`, publicação do evento e demonstração de carrinho abandonado expirando sozinho |

**Resultado da consulta obrigatória** (`financeiro/02_consultas.sql`):

```
 qtd_faturas | total_faturado
-------------+----------------
           2 |        6150.65
```

---

## Parte 3 — Integração Assíncrona e Transação com ROLLBACK

### 3.1 Como os três bancos conversam

O ponto central: **nenhum contexto escreve no banco do outro**. Se o Vendas fizesse `UPDATE` direto no MongoDB e `INSERT` no PostgreSQL, os três bancos ficariam acoplados — uma indisponibilidade do Financeiro derrubaria o checkout, e qualquer mudança de esquema em um contexto quebraria os outros.

A integração acontece por **eventos de domínio** publicados em um *message broker* (Redis Streams, Kafka ou RabbitMQ). O Vendas anuncia **o que aconteceu**; quem se interessa reage no seu próprio ritmo.

#### Fluxo: finalização de uma venda

```
1. VENDAS (Redis)
   Cliente clica em "Finalizar compra".
   - Lê o carrinho:            HGETALL carrinho:usr:4471
   - Confirma a reserva:       TTL reserva:CEL-SMX-256:usr:4471
   - Publica o evento:         XADD eventos:vendas * tipo venda.finalizada ...
   - Limpa o estado efêmero:   DEL carrinho:usr:4471
   → Responde "pedido confirmado" ao cliente em milissegundos,
     SEM esperar Estoque e Financeiro.

2. BROKER
   Evento venda.finalizada entregue a dois consumidores independentes.

   {
     "tipo": "venda.finalizada",
     "pedido": "PED-2026-0005",
     "usuario_id": 4471,
     "valor_total": 3729.60,
     "itens": [
       { "sku": "CEL-SMX-256", "qtd": 1 },
       { "sku": "CAM-BAS-PRT", "qtd": 2 }
     ],
     "ocorrido_em": "2026-11-24T10:31:00Z"
   }

3. ESTOQUE (MongoDB) — consumidor A
   Dá baixa no saldo de cada SKU, de forma atômica por documento:

   db.produtos.updateOne(
     { sku: "CEL-SMX-256", "estoque.quantidade": { $gte: 1 } },
     { $inc:  { "estoque.quantidade": -1 },
       $push: { movimentacoes: { tipo: "SAIDA_VENDA", pedido: "PED-2026-0005" } } }
   )

   Se não houver saldo (venda concorrente), publica estoque.insuficiente
   e o Vendas compensa — cancela o pedido e avisa o cliente.

4. FINANCEIRO (PostgreSQL) — consumidor B
   Emite a fatura dentro da sua própria transação ACID:

   BEGIN;
     INSERT INTO faturas (cliente_id, numero_pedido, valor_total, status, data_vencimento)
     VALUES (2, 'PED-2026-0005', 3729.60, 'PENDENTE', CURRENT_DATE + 30);
   COMMIT;

   Publica fatura.emitida, que o Vendas usa para liberar o link de pagamento.
```

#### Decisões de projeto desse fluxo

**Consistência eventual, não consistência imediata.** Entre o passo 1 e o passo 4 passam milissegundos — ou segundos, se o Financeiro estiver sob carga. Durante essa janela a venda existe e a fatura ainda não. Isso é aceitável e é o preço de não acoplar os três bancos.

**Idempotência obrigatória.** O broker pode entregar o mesmo evento duas vezes. Sem proteção, o estoque baixaria em dobro e o cliente receberia duas faturas. Por isso:
- no Financeiro, `numero_pedido` é `UNIQUE` — a segunda tentativa de inserir a mesma fatura é rejeitada pelo próprio banco;
- no Estoque, o `pedido` gravado no array `movimentacoes` permite verificar se aquela baixa já foi aplicada.

**Saga com compensação, não transação distribuída.** Não existe `BEGIN` que abranja Redis, MongoDB e PostgreSQL ao mesmo tempo. Em vez de *two-phase commit* (lento e frágil), usa-se o padrão **Saga**: cada contexto comete sua transação local e, se um passo falha, publica um evento de falha que dispara a **compensação** nos anteriores — estorno da fatura, devolução do saldo ao estoque, cancelamento do pedido.

**Reserva com TTL contra *oversell*.** O estoque real só é debitado no passo 3, depois do pagamento. Para evitar vender a mesma última unidade duas vezes, o Vendas cria no Redis uma reserva com validade curta (`SET reserva:SKU:usr 1 EX 600 NX`). Se o cliente não concluir em 10 minutos, a reserva expira sozinha e a unidade volta à vitrine.

**Outbox para não perder evento.** Se o processo cair entre gravar o pedido e publicar o evento, a venda ficaria órfã. O padrão *outbox* grava o evento na mesma transação local do pedido e um publicador o envia depois, garantindo entrega **ao menos uma vez** — o que a idempotência acima torna seguro.

### 3.2 Bônus — Transação que falha por saldo insuficiente

Implementada em [`financeiro/03_transacao_saldo_rollback.sql`](financeiro/03_transacao_saldo_rollback.sql), com três cenários:

| Cenário | Situação | Resultado |
|---|---|---|
| **A** | Cliente 1 tem R$ 15.000,00 e compra R$ 2.500,00 | `COMMIT` — débito, fatura e pagamento gravados juntos |
| **B** | Cliente 2 tem R$ 320,50 e tenta comprar R$ 1.800,00 | `RAISE EXCEPTION` → **`ROLLBACK` automático**: nem o débito nem a fatura persistem |
| **C** | `ROLLBACK` explícito após um `UPDATE` válido | Débito desfeito, saldo volta ao original |

Três mecanismos garantem a proteção em camadas:

1. **`CHECK (saldo >= 0)`** na tabela `clientes` — o banco recusa saldo negativo mesmo que a aplicação erre;
2. **`SELECT ... FOR UPDATE`** — bloqueia a linha do cliente, impedindo que duas compras simultâneas leiam o mesmo saldo e gastem o dinheiro duas vezes (*race condition*);
3. **`EXCEPTION WHEN OTHERS`** — captura a falha, informa o motivo e descarta todo o trabalho do bloco.

Estado final verificável: o saldo do cliente 2 permanece em **R$ 320,50** e o pedido `PED-2026-0004` **não existe** na tabela. A transação que falhou não deixou rastro.

---

## Parte 4 — Reflexão: Persistência Poliglota

> **O que é "Polyglot Persistence" e por que grandes sistemas (como ERPs e e-commerces) não usam apenas um único tipo de banco de dados para tudo?**

**Persistência poliglota** é a prática de usar, dentro de um mesmo sistema, **vários bancos de dados de tipos diferentes**, escolhendo para cada parte do domínio aquele que melhor atende ao seu padrão de acesso e à sua necessidade de consistência. O termo foi popularizado por Martin Fowler em analogia à programação poliglota: assim como ninguém escreve todo um sistema em uma única linguagem, não há razão para guardar todo o dado em um único modelo de persistência.

### Por que um único banco não serve

Porque **"dado" não é uma coisa só**. Dentro do mesmo ERP convivem naturezas radicalmente diferentes:

| Tipo de dado | Padrão de acesso | Consistência necessária | Vida |
|---|---|---|---|
| Fatura | Agregações, junções, auditoria | **Forte (ACID)** | Permanente |
| Produto do catálogo | Leitura do agregado inteiro, atributos variáveis | Eventual | Longa |
| Carrinho | Escrita/leitura por chave, altíssima frequência | Eventual | Minutos |

Um único SGBD atenderia bem **uma** dessas colunas e mal as outras duas. As consequências aparecem rápido:

**Forçar tudo no relacional** gera, no catálogo, o problema EAV ou a multiplicação de tabelas por categoria — cada nova categoria de produto exige migração de esquema e um `JOIN` extra em toda consulta de vitrine. E coloca o carrinho, o dado mais volátil do sistema, competindo por *locks* e I/O de disco com o fechamento contábil. **Resultado: gargalo de performance e modelagem contorcida.**

**Forçar tudo no NoSQL** entrega flexibilidade onde ela é útil, mas remove exatamente a garantia que o Financeiro não pode perder. Sem ACID transacional, "debitar saldo e emitir fatura" deixa de ser atômico, e cada regra de integridade (valor positivo, saldo não negativo, cliente existente) migra para o código da aplicação — onde mais cedo ou mais tarde alguém esquece de validar. **Resultado: risco de inconsistência em dado financeiro, que é o pior lugar possível para tê-lo.**

### Os ganhos concretos

1. **Elimina gargalos de performance.** Cada carga vai para o motor desenhado para ela: o carrinho atende em microssegundos na memória, a vitrine entrega o agregado em uma leitura, o fechamento contábil faz `SUM` e `JOIN` sobre um esquema normalizado. Nenhuma carga atrapalha a outra.

2. **Simplifica a modelagem.** O modelo deixa de ser uma concessão ao banco disponível e passa a refletir o domínio. Especificações variáveis de produto deixam de ser um problema a contornar; viram simplesmente um documento.

3. **Permite escolher o lado certo do Teorema CAP, contexto por contexto.** O teorema diz que em um sistema distribuído não se pode ter Consistência, Disponibilidade e Tolerância a Partição ao mesmo tempo. Com um único banco, o sistema inteiro faz uma única escolha. Com persistência poliglota, o Financeiro é **CP** (prefere recusar a operação a devolver saldo errado) e o Carrinho é **AP** (prefere responder sempre, mesmo com dado ligeiramente defasado) — cada um otimizando o que realmente importa no seu domínio.

4. **Isola falhas e escala de forma independente.** Se o MongoDB do catálogo ficar lento na Black Friday, o Financeiro continua faturando. É possível escalar o Redis horizontalmente para o pico de tráfego sem tocar no banco contábil.

### O custo — porque não é almoço grátis

Persistência poliglota não é gratuita, e reconhecer isso faz parte da decisão arquitetural:

- **Complexidade operacional:** três SGBDs para monitorar, versionar, fazer *backup* e recuperar em caso de desastre;
- **Perda da transação global:** não existe `BEGIN` que abranja os três bancos, o que obriga ao padrão Saga, à idempotência e à lógica de compensação descrita na Parte 3;
- **Consistência eventual visível ao negócio:** há uma janela em que a venda existe e a fatura ainda não — e o negócio precisa aceitar essa janela;
- **Custo de equipe:** o time precisa dominar SQL, modelagem de documentos e estruturas de dados do Redis.

Por isso a regra prática é: **começar simples e dividir quando o domínio exigir.** Um sistema pequeno roda bem em um único PostgreSQL — que, com `JSONB` e `UNLOGGED tables`, cobre boa parte dos casos. A persistência poliglota se justifica quando a diferença entre os padrões de acesso passa a doer: quando o carrinho começa a travar o fechamento contábil, ou quando cada nova categoria de produto exige uma migração de esquema.

### Em uma frase

> **Usar o banco certo para o problema certo.** Não existe banco de dados melhor — existe banco adequado a um padrão de acesso e a um nível de consistência. O trabalho do arquiteto é identificar as fronteiras do domínio e escolher, dentro de cada uma, a ferramenta que resolve aquele problema nativamente, em vez de forçar todo o sistema a caber na ferramenta que já estava instalada.

---

## Como executar

### Financeiro — PostgreSQL

```bash
# cria o banco
createdb erp_financeiro

# executa na ordem
psql -d erp_financeiro -f financeiro/01_schema_faturas.sql
psql -d erp_financeiro -f financeiro/02_consultas.sql
psql -d erp_financeiro -f financeiro/03_transacao_saldo_rollback.sql
```

Com Docker:

```bash
docker run --name pg-erp -e POSTGRES_PASSWORD=erp -e POSTGRES_DB=erp_financeiro -p 5432:5432 -d postgres:16
docker cp financeiro pg-erp:/tmp/
docker exec -it pg-erp psql -U postgres -d erp_financeiro -f /tmp/financeiro/01_schema_faturas.sql
```

### Estoque — MongoDB

```bash
mongosh < estoque/produtos.js

# ou, dentro do shell:
mongosh
> load("estoque/produtos.js")
```

Com Docker:

```bash
docker run --name mongo-erp -p 27017:27017 -d mongo:7
docker cp estoque/produtos.js mongo-erp:/tmp/
docker exec -it mongo-erp mongosh /tmp/produtos.js
```

### Vendas — Redis

O `redis-cli` não interpreta linhas de comentário quando lê de um arquivo, então os comentários são removidos antes do envio:

```bash
grep -v '^[[:space:]]*#' vendas/carrinho.redis | grep -v '^[[:space:]]*$' | redis-cli
```

Ou comando por comando, para acompanhar cada retorno:

```bash
redis-cli
127.0.0.1:6379> HGETALL carrinho:usr:4471
```

Com Docker:

```bash
docker run --name redis-erp -p 6379:6379 -d redis:7
grep -v '^[[:space:]]*#' vendas/carrinho.redis | grep -v '^[[:space:]]*$' | docker exec -i redis-erp redis-cli
```

---

## Estrutura do repositório

```
.
├── README.md                              # Partes 1, 3 e 4: arquitetura, integração e reflexão
│
├── financeiro/                            # Contexto Financeiro — PostgreSQL (relacional)
│   ├── 01_schema_faturas.sql              # DDL + carga transacional dos 2 registros
│   ├── 02_consultas.sql                   # SUM do total faturado + consultas analíticas
│   └── 03_transacao_saldo_rollback.sql    # Bônus: BEGIN / COMMIT / ROLLBACK
│
├── estoque/                               # Contexto de Estoque — MongoDB (documentos)
│   └── produtos.js                        # Coleção com atributos variáveis + aggregation
│
└── vendas/                                # Contexto de Vendas — Redis (chave-valor)
    └── carrinho.redis                     # Carrinho e sessão com TTL + evento de venda
```

A organização em pastas por contexto é intencional: deixa explícito, já na raiz do repositório, que se trata de **uma arquitetura dividida em contextos delimitados** — e não de um banco único com três scripts soltos.
