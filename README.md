# fiapx-infra

Infraestrutura Docker Compose da solução FiapX, responsável por subir o ambiente integrado com API, Worker, banco de dados, cache, mensageria, armazenamento, identidade e e-mail local.

[![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white)]()
[![Keycloak](https://img.shields.io/badge/Keycloak-realm%20fiapx-4D4D4D)]()
[![RabbitMQ](https://img.shields.io/badge/RabbitMQ-quorum%20queues-FF6600?logo=rabbitmq&logoColor=white)]()
[![CI](https://github.com/fabianorodrigues/fiapx-infra/actions/workflows/ci.yml/badge.svg)](https://github.com/fabianorodrigues/fiapx-infra/actions/workflows/ci.yml)
[![CD](https://github.com/fabianorodrigues/fiapx-infra/actions/workflows/cd.yml/badge.svg)](https://github.com/fabianorodrigues/fiapx-infra/actions/workflows/cd.yml)

## Sumário

- [Visão geral](#visão-geral)
- [Solução integrada](#solução-integrada)
- [Responsabilidade deste repositório](#responsabilidade-deste-repositório)
- [Pré-requisitos](#pré-requisitos)
- [Configuração](#configuração)
- [Execução local](#execução-local)
- [CI/CD](#cicd)
- [Health e validação](#health-e-validação)
- [Recuperação e volumes](#recuperação-e-volumes)
- [Próxima etapa](#próxima-etapa)

---

## Documentação e apresentação

- [Acessar documentação completa](https://fabianorodrigues.github.io/fiap-fase5-docs/)
- [Assistir vídeo de apresentação](https://youtu.be/EvCfwoXaBsc)

---

## Visão geral

Este é o repositório inicial para quem quer executar a solução FiapX completa. Ele concentra o Compose integrado e os artefatos versionados necessários para provisionar o ambiente local/demonstrativo.

| Repositório | Papel |
| --- | --- |
| [fiapx-infra](https://github.com/fabianorodrigues/fiapx-infra) | Ambiente integrado, Docker Compose, bootstrap, health, deploy e recuperação |
| [fiapx-video-management](https://github.com/fabianorodrigues/fiapx-video-management) | API HTTP, autenticação, upload, status, listagem, download e notificação de erro |
| [fiapx-video-processing](https://github.com/fabianorodrigues/fiapx-video-processing) | Worker assíncrono, RabbitMQ, MinIO, FFmpeg, ZIP e eventos de processamento |

**Tecnologias:** Docker Compose, PostgreSQL 17, Redis 8, RabbitMQ 4.1, MinIO, Keycloak 26.7, Mailpit, .NET 10, GitHub Actions e PowerShell.

---

## Solução integrada

```mermaid
%%{init: {"flowchart": {"nodeSpacing": 34, "rankSpacing": 46}} }%%
flowchart LR
    classDef client fill:#EFEFEF,color:#222,stroke:#999
    classDef api fill:#512BD4,color:#fff,stroke:#39208A
    classDef worker fill:#1F7A5A,color:#fff,stroke:#0F4A35
    classDef broker fill:#FF6600,color:#fff,stroke:#B34700
    classDef store fill:#2563EB,color:#fff,stroke:#1E3A8A
    classDef auth fill:#6D28D9,color:#fff,stroke:#4C1D95
    classDef mail fill:#3F3F46,color:#fff,stroke:#18181B

    USER([Cliente ou Postman]):::client
    KC["Keycloak<br/>realm fiapx"]:::auth
    API["Video Management<br/>API HTTP"]:::api
    PG[("PostgreSQL<br/>metadados")]:::store
    REDIS[("Redis<br/>cache best-effort")]:::store
    MINIO[("MinIO<br/>bucket videos")]:::store
    RABBIT["RabbitMQ<br/>eventos e filas"]:::broker
    WORKER["Video Processing<br/>Worker .NET"]:::worker
    FFMPEG["FFmpeg<br/>frames PNG"]:::worker
    MAIL["Mailpit<br/>e-mail local"]:::mail

    USER -- "token OIDC" --> KC
    USER -- "JWT + /videos" --> API
    API --> PG
    API -. cache .-> REDIS
    API -- "presigned URL" --> MINIO
    MINIO -- "ObjectCreated: original.mp4" --> RABBIT
    RABBIT -- "video.uploaded" --> WORKER
    WORKER --> MINIO
    WORKER --> FFMPEG
    WORKER -- "resultado.zip" --> MINIO
    WORKER -- "started/completed/failed" --> RABBIT
    RABBIT -- "status updates" --> API
    API -. "falha de processamento" .-> MAIL
```

Fluxo principal:

1. O usuário autentica no Keycloak e chama a API Management.
2. A API registra o vídeo no PostgreSQL e devolve uma URL pré-assinada de upload.
3. O cliente envia `original.mp4` ao MinIO.
4. O MinIO publica o evento no RabbitMQ.
5. O Worker consome a fila, extrai frames com FFmpeg, gera `resultado.zip` e grava no MinIO.
6. O Worker publica eventos de status; a API atualiza o PostgreSQL e invalida o cache Redis.
7. O cliente consulta o status e baixa o ZIP quando o vídeo estiver `CONCLUIDO`.

---

## Responsabilidade deste repositório

| Item | Como é tratado |
| --- | --- |
| Docker Compose integrado | `docker-compose.yml` é o Compose base por imagens; `docker-compose.dev.yml` compila os repositórios irmãos |
| PostgreSQL | Criado pelo container; schema aplicado por `video-management-migrations` |
| Redis | Criado vazio e usado como cache best-effort pela API |
| RabbitMQ | Topologia versionada em `rabbitmq/definitions.json` |
| MinIO | Bucket e notificação AMQP criados por `minio-init` |
| Keycloak | Realm, clients e usuários DEMO versionados em `keycloak/fiapx-realm.json` |
| Mailpit | SMTP e UI local para validar notificações de erro |
| Deploy | Workflows `ci.yml` e `cd.yml`, com scripts em `.github/scripts/` |

O Compose base não compila código. Ele usa as imagens indicadas em `VIDEO_MANAGEMENT_IMAGE` e `VIDEO_PROCESSING_IMAGE`. Para desenvolvimento local com build dos repositórios irmãos, use também `docker-compose.dev.yml`.

---

## Pré-requisitos

Para execução local integrada:

| Requisito | Observação |
| --- | --- |
| Windows com Docker Desktop | Necessário para todos os serviços |
| Docker Compose | Usado pelos comandos deste README |
| Git e PowerShell | Necessários para clone, scripts e validações |
| Postman e um arquivo `.mp4` | Necessários para validação E2E manual |
| Repositórios irmãos no mesmo diretório pai | Necessário no modo dev com `docker-compose.dev.yml` |

Estrutura esperada para build local:

```text
C:\Projetos\fiap-fase5\
  fiapx-infra\
  fiapx-video-management\
  fiapx-video-processing\
```

Para deploy via GitHub Actions, cada runner self-hosted Windows também precisa ter Docker Desktop, Docker Compose, Git, PowerShell e acesso ao GHCR das imagens publicadas pelos repositórios dos serviços.

---

## Configuração

### Arquivos de ambiente

| Item | Classificação | Uso |
| --- | --- | --- |
| `.env.example` | JÁ VERSIONADO | Modelo DEMO/local e referência de credenciais locais |
| `.env` | LOCAL/NÃO VERSIONADO | Fonte operacional para execução local e CD |
| `VIDEO_MANAGEMENT_IMAGE` | MANUAL no modo image-only/CD | Imagem da API usada pelo Compose base |
| `VIDEO_PROCESSING_IMAGE` | MANUAL no modo image-only/CD | Imagem do Worker usada pelo Compose base |
| `BOOTSTRAP_VIDEO_MANAGEMENT_IMAGE` | CONDICIONAL no CD da infra | Primeira imagem da API se o CD precisar criar `.env` |
| `BOOTSTRAP_VIDEO_PROCESSING_IMAGE` | CONDICIONAL no CD da infra | Primeira imagem do Worker se o CD precisar criar `.env` |

Para uso local, crie o `.env` a partir do exemplo:

```powershell
Copy-Item .env.example .env
```

> [!IMPORTANT]
> O `.env` é ignorado pelo Git. Não versionar tokens, PATs, JWTs, connection strings privadas, SMTP real ou credenciais de ambiente real.

### Usuários DEMO

O realm Keycloak versionado cria dois usuários para demonstração local:

| Usuário | E-mail |
| --- | --- |
| `usertest1` | `usertest1@fiapx.local` |
| `usertest2` | `usertest2@fiapx.local` |

As senhas DEMO desses usuários e as credenciais de Keycloak, MinIO e RabbitMQ ficam em `.env.example`. Elas são exclusivamente locais e não devem ser reutilizadas fora deste contexto.

### Provisionamento automático e manual

| Item | Classificação | Detalhe |
| --- | --- | --- |
| PostgreSQL, Redis, RabbitMQ, MinIO, Keycloak e Mailpit | AUTOMÁTICO | Criados pelo Compose |
| Migrations da API | AUTOMÁTICO | Executadas por `video-management-migrations` |
| RabbitMQ exchanges, filas e bindings | JÁ VERSIONADO / AUTOMÁTICO | Importados de `rabbitmq/definitions.json` |
| MinIO bucket `videos` | AUTOMÁTICO | Criado por `minio-init` |
| Evento MinIO para `videos/*/original.mp4` | AUTOMÁTICO | Criado por `minio-init` |
| Keycloak realm `fiapx` e usuários DEMO | JÁ VERSIONADO / AUTOMÁTICO | Importados de `keycloak/fiapx-realm.json` |
| `.env` | MANUAL | Criado a partir de `.env.example` |
| GitHub Variables | MANUAL | Criadas nos três repositórios |
| Self-hosted runners | MANUAL | Criados nos três repositórios |

### Self-hosted runners

Crie cada runner no repositório correspondente:

```text
Settings > Actions > Runners > New self-hosted runner
```

Use Windows x64 e execute o comando de registro gerado pelo GitHub dentro da pasta indicada. O token de registro é temporário e não deve ser documentado.

| Repositório | Diretório | Runner name |
| --- | --- | --- |
| `fiapx-infra` | `C:\actions-runner-infra` | `fiapx-infra-deploy` |
| `fiapx-video-management` | `C:\actions-runner-management` | `fiapx-management-deploy` |
| `fiapx-video-processing` | `C:\actions-runner-processing` | `fiapx-processing-deploy` |

Configuração comum:

| Prompt | Valor |
| --- | --- |
| Runner group | `Default` |
| Additional labels | `fiap-fase5` |
| Work folder | `_work` |
| Run as service | `N` |

Labels esperadas:

```text
self-hosted
Windows
X64
fiap-fase5
```

Para iniciar cada runner:

```powershell
C:\actions-runner-infra\run.cmd
C:\actions-runner-management\run.cmd
C:\actions-runner-processing\run.cmd
```

Os runners precisam estar `Online` para o CD do respectivo repositório executar.

### GitHub Variables

Configure nos três repositórios:

```text
Settings > Secrets and variables > Actions > Variables
```

| Variável | Repositórios | Valor esperado | Uso |
| --- | --- | --- | --- |
| `DEPLOY_INFRA_PATH` | Infra, Management e Processing | `C:\Projetos\fiap-fase5\fiapx-infra` | Caminho da working copy operacional usada pelos scripts de CD |

Variáveis condicionais apenas no `fiapx-infra`, necessárias se o CD da infra precisar criar `.env` pela primeira vez:

| Variável | Valor esperado |
| --- | --- |
| `BOOTSTRAP_VIDEO_MANAGEMENT_IMAGE` | `ghcr.io/<owner>/fiapx-video-management:<commit-sha>` |
| `BOOTSTRAP_VIDEO_PROCESSING_IMAGE` | `ghcr.io/<owner>/fiapx-video-processing:<commit-sha>` |

As imagens de bootstrap devem estar pinadas por tag SHA de commit ou digest. Não use `latest` como referência operacional.

---

## Execução local

### Modo recomendado: ambiente integrado com build local

Use este modo quando estiver com os três repositórios clonados no mesmo diretório pai.

```powershell
docker compose `
  --env-file .env `
  -f docker-compose.yml `
  -f docker-compose.dev.yml `
  up -d --build
```

Para escalar o Worker:

```powershell
docker compose `
  --env-file .env `
  -f docker-compose.yml `
  -f docker-compose.dev.yml `
  up -d --build --scale video-processing-service=3
```

### Modo por imagens

Use este modo quando `VIDEO_MANAGEMENT_IMAGE` e `VIDEO_PROCESSING_IMAGE` já apontarem para imagens existentes.

```powershell
docker compose `
  --env-file .env `
  -f docker-compose.yml `
  up -d
```

### URLs locais

| Serviço | URL |
| --- | --- |
| Video Management API | `http://localhost:8080` |
| Swagger | `http://localhost:8080/swagger` |
| Keycloak | `http://localhost:8081` |
| MinIO API | `http://localhost:9000` |
| MinIO Console | `http://localhost:9001` |
| RabbitMQ Management | `http://localhost:15672` |
| Mailpit | `http://localhost:8025` |
| PostgreSQL | `localhost:5432` |
| Redis | `localhost:6379` |

---

## CI/CD

### CI

O workflow `.github/workflows/ci.yml` roda em `ubuntu-24.04` para:

- `pull_request`;
- `push` na branch `main`;
- `workflow_dispatch`.

Valida:

| Validação | Origem |
| --- | --- |
| Docker Compose | `docker compose config` |
| JSON RabbitMQ e Keycloak | `rabbitmq/definitions.json`, `keycloak/fiapx-realm.json` |
| PowerShell | Parser dos scripts |
| Segurança de `.env` | `.env` não pode estar versionado |
| `.env.example` | Deve permanecer DEMO/local |
| Imagens | Compose base não pode usar `build` nem imagem `latest` |
| Topologia | Serviços, volumes, filas, exchanges, policies e usuários esperados |

### CD

O CD roda por `workflow_run` depois do CI aprovado em `push` na `main`. Ele usa `head_sha`, valida se esse SHA ainda é o HEAD atual da `main`, executa no runner self-hosted Windows e faz deploy na máquina local apontada por `DEPLOY_INFRA_PATH`.

`workflow_dispatch` é útil para CI, mas o caminho normal de CI + CD completo é `push` ou merge na `main`.

Runner esperado para este repositório:

| Item | Valor |
| --- | --- |
| Diretório | `C:\actions-runner-infra` |
| Runner name | `fiapx-infra-deploy` |
| Labels | `self-hosted`, `Windows`, `X64`, `fiap-fase5` |
| Inicialização | `C:\actions-runner-infra\run.cmd` |

Ordem para ambiente vazio:

1. `fiapx-infra`
2. `fiapx-video-management`
3. `fiapx-video-processing`

A Infra cria/reconcilia as dependências e sobe a stack base. Management e Processing depois atualizam seus próprios serviços sobre o ambiente existente.

Ordem operacional do CD da Infra:

1. Adquire o lock `Global\FiapXDeployLock`.
2. Atualiza a working copy operacional para o SHA implantado.
3. Valida `.env` e Compose.
4. Sobe PostgreSQL, Redis, RabbitMQ, MinIO, Keycloak e Mailpit.
5. Reconcilia RabbitMQ e MinIO.
6. Executa migrations da API.
7. Recria Management e Processing preservando escala explícita do Worker.
8. Valida health integrado.

O CD não executa `docker compose up -d` genérico e não remove volumes automaticamente.

---

## Health e validação

### Health rápido

```powershell
docker compose --env-file .env -f docker-compose.yml ps
Invoke-RestMethod http://localhost:8080/health
Invoke-RestMethod http://localhost:8081/realms/fiapx
Invoke-RestMethod http://localhost:9000/minio/health/ready
Invoke-WebRequest http://localhost:8025 -UseBasicParsing
```

### Validação por serviço

| Serviço | Como validar |
| --- | --- |
| Swagger | Abrir `http://localhost:8080/swagger` |
| Keycloak | Abrir `http://localhost:8081`, realm `fiapx`, menu `Manage realms > fiapx > Users` |
| Usuários DEMO | Confirmar `usertest1` e `usertest2` |
| MinIO | Abrir `http://localhost:9001`, bucket `videos` criado automaticamente |
| RabbitMQ | Abrir `http://localhost:15672`, filas principais criadas |
| Mailpit | Abrir `http://localhost:8025` |

Filas RabbitMQ principais:

```text
video.processing
video.processing.retry
video.processing.dlq
video.status-updates
video.status-updates.retry
video.status-updates.dlq
```

Verifique consumidores do Worker:

```powershell
docker compose --env-file .env -f docker-compose.yml exec rabbitmq `
  rabbitmqctl list_queues name messages_ready messages_unacknowledged consumers
```

A fila `video.processing` deve ter `consumer_count >= 1`. `Ready` e `Unacked` podem ficar em `0` mesmo com tudo funcionando, pois mensagens podem ser consumidas rapidamente.

### Objetos esperados no MinIO

Antes do upload, o bucket pode estar vazio. Depois do processamento:

```text
videos/{userId}/{videoId}/original.mp4
results/{userId}/{videoId}/resultado.zip
```

### Postman e E2E

A Collection e o Environment ficam no repositório [fiapx-video-management](https://github.com/fabianorodrigues/fiapx-video-management):

```text
postman/fiapx-video-management.postman_collection.json
postman/fiapx-video-management.local.postman_environment.json
```

Fluxo esperado:

1. Autenticar no Keycloak.
2. Registrar vídeo na API.
3. Fazer upload do `.mp4`.
4. Consultar status até `CONCLUIDO`.
5. Obter download.
6. Baixar e abrir `resultado.zip`.

Fluxo de erro:

1. Enviar arquivo com extensão `.mp4`, mas conteúdo inválido.
2. Aguardar status `ERRO`.
3. Validar e-mail de falha no Mailpit.

### E2E integrado por script

O script E2E cria vídeos sintéticos, autentica, envia upload, valida status, baixa ZIP, exercita retry/DLQ e registra evidências em `artifacts/e2e-rabbitmq-results.json`.

Modo dev:

```powershell
.\scripts\e2e-rabbitmq.ps1 -EnvFile .\.env.example -BootstrapUsers
```

Modo por imagens, com `.env` apontando para imagens já existentes:

```powershell
.\scripts\e2e-rabbitmq.ps1 -EnvFile .\.env -ImageOnly -SkipBuild -BootstrapUsers
```

---

## Recuperação e volumes

Volumes versionados no Compose:

| Volume | Conteúdo |
| --- | --- |
| `postgres-data` | Dados e schema do PostgreSQL |
| `redis-data` | Persistência AOF do Redis |
| `minio-data` | Objetos do bucket |
| `minio-events` | Fila local de eventos AMQP do MinIO |
| `rabbitmq-data` | Estado do RabbitMQ |

Recriar containers preservando volumes:

```powershell
docker compose --env-file .env -f docker-compose.yml -f docker-compose.dev.yml up -d --build
```

Parar preservando volumes:

```powershell
docker compose --env-file .env -f docker-compose.yml down
```

Zerar volumes apenas em ambiente DEMO/local:

```powershell
docker compose --env-file .env -f docker-compose.yml down -v
```

O deploy não executa:

- `docker compose down -v`;
- `docker volume prune`;
- `docker system prune`.

Rollback de commit de infraestrutura reconcilia configuração versionada, mas não desfaz dados, objetos, filas, estado do Keycloak ou migrations já aplicadas.

---

## Próxima etapa

Com o ambiente saudável, siga para a validação da API no [fiapx-video-management](https://github.com/fabianorodrigues/fiapx-video-management).
