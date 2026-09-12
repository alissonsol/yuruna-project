<a id="4286c679-0001"></a>

# Exemplo Text-to-SQL do Yuruna

> **Status: versão inicial.** Roda localmente contra o PostgreSQL e
> implanta pelo modelo completo de três fases do Yuruna (`Set-Resource` /
> `Set-Component` / `Set-Workload`); veja
> [Integração com o Yuruna](#integração-com-o-yuruna) abaixo. O Claude
> é ativado quando `ANTHROPIC_API_KEY` está definida.

Uma aplicação agêntica de text-to-SQL somente leitura: ASP.NET Core
(.NET 10) Razor Pages sobre o PostgreSQL, implementando um pipeline de
agente de seis estágios com recuperação de esquema, validação estática e
uma barreira de custo baseada em EXPLAIN.

Este exemplo mostra, de ponta a ponta, como é um agente observável e com
ações controladas por barreiras. O `ILlmClient` padrão é um substituto
determinístico baseado em regras, para que o exemplo rode offline contra
um PostgreSQL local; definir `ANTHROPIC_API_KEY` ativa em tempo de
execução o cliente real do Claude com uso de ferramentas
(`Services/ClaudeLlmClient.cs`).

| Caminho | O que é |
| ---- | ---------- |
| [db/schema.sql](../../../../example/text-to-sql/db/schema.sql) | Esquema do PostgreSQL + dados iniciais (assinaturas / churn / faturas) |
| [components/frontend/text-to-sql-ui/](../../../../example/text-to-sql/components/frontend/text-to-sql-ui/) | Aplicação ASP.NET Core (.NET 10) Razor Pages que implementa a arquitetura de seis estágios |

<a id="4286c679-0002"></a>

## Início rápido

<a id="4286c679-0003"></a>

<a id="1--preparar-o-postgresql"></a>

### 1 - Preparar o PostgreSQL

Qualquer PostgreSQL local >= 14 funciona (imagem Docker, um script de
configuração `<guest>.postgresql.sh` de convidado Yuruna ou uma instalação
nativa). Com um superusuário, crie o banco de dados e carregue o esquema:

```powershell
psql -h localhost -U postgres -c "CREATE DATABASE yuruna_demo;"
psql -h localhost -U postgres -d yuruna_demo -f db/schema.sql
```

O `schema.sql` cria um papel `yuruna_agent_ro` com permissões apenas de
`SELECT` -- essa é a camada de controle de ações no nível do banco de
dados. A aplicação .NET se conecta com esse papel.

<a id="4286c679-0004"></a>

<a id="2--executar-a-aplicação-net"></a>

### 2 - Executar a aplicação .NET

```powershell
cd components/frontend/text-to-sql-ui
dotnet run
```

Depois abra <http://localhost:5080>.

Substitua a string de conexão, se necessário:

```powershell
$env:TEXT2SQL_PG_CONN = "Host=localhost;Username=yuruna_agent_ro;Password=agent_demo_password;Database=yuruna_demo"
dotnet run
```

<a id="4286c679-0005"></a>

## O que a aplicação demonstra

A página inicial mostra o pipeline do agente como uma linha do tempo ao
vivo. Toda pergunta passa por seis estágios observáveis:

```
Question -> Schema Retrieval -> SQL Generation -> Static Validation
                  -> EXPLAIN Cost Gate -> Execute -> Observer (this timeline)
```

Experimente estes prompts:

| Prompt | O que mostra |
| ------ | ------------- |
| `churn rate by plan tier in EMEA` | agregação regional + a armadilha de renomeação `plan_code -> tier_code` |
| `MRR by tier` | agregação entre `plan_tier` x `subscription` |
| `active subscriptions by region` | tratamento de NULL em `cancelled_at` |
| `top 10 customers by invoice` | a coluna de PII (`customer.email`) **não** é selecionada |
| `drop table customer` | o validador estático recusa e a linha do tempo mostra a parada no estágio 3 |

A página **`/Schema`** exibe o que o recuperador de esquema indexa -- o
mesmo catálogo que o agente usa, visível como verdade de referência.

<a id="4286c679-0006"></a>

## Mapa da arquitetura

| Estágio | Implementação |
| ----- | -------------- |
| (1) Planejador (LLM) | `Services/ClaudeLlmClient.cs` (uso de ferramentas da Anthropic, ativo quando `ANTHROPIC_API_KEY` está definida) ou `Services/RuleBasedLlmClient.cs` (stub determinístico, o padrão offline) |
| (2) Recuperador de esquema | `Services/SchemaCatalog.cs` (ciente de FK) |
| (3) Gerador de SQL | compartilhado com (1) neste exemplo |
| (4) Validador / Guardrail | `Services/SqlValidator.cs` (estático + barreira EXPLAIN) |
| (5) Executor | `Services/AgentOrchestrator.cs` |
| (6) Observador | a linha do tempo em `Pages/Index.cshtml` |

<a id="4286c679-0007"></a>

### Notas dos serviços

Notas de design por serviço, referenciadas a partir dos comentários no
topo dos arquivos (`https://yuruna.link/4286c679-0007`).

**`Program.cs`** -- host mínimo de Razor Pages. Três coisas são
conectadas: Razor Pages para a interface de chat, um `DataSource` do
Npgsql para a conexão somente leitura com o PostgreSQL e os serviços do
agente (SchemaCatalog -> SqlValidator -> AgentOrchestrator). O
orquestrador usa por padrão a "LLM" determinística baseada em regras;
quando `ANTHROPIC_API_KEY` está definida, o caminho do ClaudeLlmClient
entra em seu lugar pela mesma interface `ILlmClient`.

**`Services/ILlmClient.cs`** -- o contrato da interface: `GenerateSqlAsync`
recebe a pergunta mais a fatia de esquema expandida por FK e retorna ou
uma string SQL ou uma recusa com um motivo. Existem três implementações
para que o exemplo rode de forma reproduzível com ou sem uma dependência
de LLM: `RuleBasedLlmClient` (determinístico, offline, sem chave de API),
`ClaudeLlmClient` (Messages API da Anthropic com uso de ferramentas) e
`OllamaLlmClient` (servidor Ollama local, ativado por `USE_LOCAL_MODEL`).

**`Services/RuleBasedLlmClient.cs`** -- substituto determinístico para a
caixa "(3) Gerador de SQL (LLM)". A cobertura de padrões acompanha os
dados iniciais: taxa de churn por tier de plano / região / canal /
trimestre, MRR / ARR por tier, assinaturas ativas / novas adesões,
principais clientes por valor de fatura e um caminho sem resposta para
prompts fora do domínio. Cada correspondência retorna uma pontuação de
confiança e o mesmo texto que uma LLM real produziria em um canal
"plan", de modo que a interface mostra um raciocínio de agente realista.

**`Services/SchemaCatalog.cs`** -- o estágio "(2) Recuperador de
esquema". Em tempo de compilação: inspeciona `information_schema` +
`pg_constraint` para materializar metadados por coluna (nome, tipo,
aceita nulo, valores de amostra), texto descritivo por tabela (a partir
de `COMMENT ON`) e o grafo de chaves estrangeiras como um arquivo
paralelo. Em tempo de consulta: `get_relevant_schema(question, k)` usa
pontuação híbrida (sobreposição de palavras-chave mais similaridade de
substring nas docstrings) com expansão de FK de um salto, para que a LLM
nunca precise inventar parceiros de JOIN, e retorna uma fatia compacta de
prompt (alvo < 2 KB). Um sistema em produção usaria um índice vetorial de
verdade (pgvector ou um armazenamento hospedado); mantê-lo determinístico
mantém o exemplo offline e reproduzível.

**`Services/SqlValidator.cs`** -- o estágio "(4) Validador (Guardrail)".
Ele impõe: (1) exatamente uma instrução, e que essa instrução seja um
SELECT (ou `WITH ... SELECT`) -- verbos DDL/DML são rejeitados; (2)
nenhum ponto e vírgula no meio da consulta (instruções empilhadas); (3)
nenhum comentário que possa esconder um payload; (4) um LIMIT de nível
superior, acrescentado quando ausente; (5) uma barreira de custo baseada
em EXPLAIN que recusa planos cujo "Plan Rows" do nó superior excede um
limite configurável. Em produção, a pré-verificação por regex seria um
parser de AST como o libpg_query; aqui a camada de regex é uma escolha
deliberada e assumida, e a barreira EXPLAIN é a verdadeira defesa em
profundidade.

**`Services/ClaudeLlmClient.cs`** -- `ILlmClient` de produção apoiado na
Messages API da Anthropic com uso de ferramentas para saída estruturada;
o papel de "(3) Gerador de SQL (LLM)" no orquestrador. Retorna um
`LlmDecision` com `Sql` (SELECT bruto, sem cercas de markdown),
`PlanText` (raciocínio mostrado no observador da interface), `Refused` e
`RefusalReason`.

**`Services/OllamaLlmClient.cs`** -- `ILlmClient` local-first apoiado em
um servidor Ollama (padrão `http://127.0.0.1:11434`) executando um modelo
de código local (por exemplo, `qwen3-coder`); ativado por
`USE_LOCAL_MODEL` / `OLLAMA_HOST`, mantendo o esquema e as perguntas no
dispositivo em vez de chamar uma API de terceiros. Espelha o contrato de
saída estruturada do `ClaudeLlmClient`: um `Refused=true` interpretado é
um `LlmDecision` normal, e todos os outros modos de falha lançam
`LlmClientException`.

**`Services/AgentOrchestrator.cs`** -- o "(5) Executor" mais o laço de
repetição. Roda os estágios em ordem (recuperador de esquema -> gerador
de SQL -> validador estático -> barreira de custo EXPLAIN -> executor) e
emite um `Step` por estágio com tempo decorrido em ms, status e notas; a
interface renderiza uma execução como uma única linha do tempo -- a
camada "Observador" em miniatura.

<a id="4286c679-0008"></a>

## Integração com o Yuruna

Este exemplo segue o mesmo padrão de pastas que
[`example/website`](../../../../example/website/README.md) -- `components/frontend/<app>/` --
e é implantado pelo modelo de três fases do Yuruna. As peças estão no lugar:

- `config/localhost/{resources,components,workloads}.yml` conduzem as
  três fases.
- `components/frontend/text-to-sql-ui/Dockerfile` compila a imagem de
  contêiner durante o `Set-Component`.
- O chart do Helm em
  [`workloads/frontend/text-to-sql-ui/`](../../../../example/text-to-sql/workloads/frontend/text-to-sql-ui/)
  o implanta no Kubernetes (pod + ingress TLS) durante o `Set-Workload`. A
  implantação injeta `TEXT2SQL_PG_CONN` apontando para `status.hostIP` (o nó),
  para que o pod alcance o PostgreSQL do nó pela rede de pods.
- `test/ubuntu.server.24/ubuntu.server.24.workload.k8s.text-to-sql.db.sh`
  sobe o banco de dados do nó: força `ssl = off`, abre
  `listen_addresses`/`pg_hba` para o CIDR dos pods, cria `yuruna_demo` e
  carrega [`db/schema.sql`](../../../../example/text-to-sql/db/schema.sql) (que também cria o papel somente
  leitura `yuruna_agent_ro` com o qual a aplicação se conecta).
- A carga de trabalho [`test/`](../../../../example/text-to-sql/test/) exercita o ciclo inteiro em um nó
  Kubernetes convidado -- a sequência `.baseline` instala o Kubernetes e faz
  um checkpoint dele; a sequência `.test` restaura esse checkpoint, configura
  o PostgreSQL, implanta e verifica `HTTP 200`. Ambas rodam sem supervisão.

A mesma seleção de `ILlmClient` vale no contêiner implantado: defina
`ANTHROPIC_API_KEY` para rodar com o Claude, deixe-a indefinida para
rodar o cliente offline baseado em regras.

<a id="4286c679-0009"></a>

### Certificado de desenvolvimento

Gere o certificado HTTPS de desenvolvimento **antes** da compilação
Docker / Yuruna. O `Set-Component` executa `copy-pfx.ps1`, que copia
`$HOME/.aspnet/https/aspnetapp.pfx` para o contexto de compilação, e o
`Dockerfile` então faz `COPY` desse pfx para a imagem. Se o pfx ainda não
existir, `copy-pfx.ps1` falha de forma explícita, com o comando exato a
ser executado.

```powershell
dotnet dev-certs https --check --trust              # check
mkdir $HOME/.aspnet/https
dotnet dev-certs https -ep $HOME/.aspnet/https/aspnetapp.pfx -p { password here }
dotnet dev-certs https --trust
```

Se aparecer "A valid HTTPS certificate is already present" -> execute `dotnet dev-certs https --clean` e tente novamente.

<a id="4286c679-000a"></a>

## Arquivos

```
example/text-to-sql/
+-- README.md                        <- this file
+-- db/
|   +-- schema.sql                   <- PostgreSQL schema + seed data
+-- config/
|   +-- localhost/                   <- resources - components - workloads (three-phase config)
+-- workloads/
|   +-- frontend/text-to-sql-ui/     <- helm chart (pod + TLS ingress)
+-- test/                            <- guest-Kubernetes deployment test
+-- components/
    +-- frontend/
        +-- text-to-sql-ui/
            +-- text-to-sql-ui.csproj
            +-- Program.cs
            +-- Dockerfile
            +-- copy-pfx.ps1          <- copies the dev cert into the build context
            +-- seed-base-images.ps1  <- pushes the Dockerfile's base images to the local registry
            +-- appsettings*.json
            +-- Properties/launchSettings.json
            +-- Pages/                <- Index - Schema - About - Error - Layout
            +-- Services/             <- ILlmClient - SchemaCatalog - SqlValidator
            |                            - AgentOrchestrator - RuleBasedLlmClient
            |                            - ClaudeLlmClient - OllamaLlmClient
            +-- wwwroot/css/site.css
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Última revisão: 2026.09.12

Voltar para [yuruna-project](../../../../README.md) - [Yuruna](https://yuruna.com)
