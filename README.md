# FIAP X Infra

Infraestrutura compartilhada para execucao local/integrada da solucao FIAP X.

Este repositorio concentra Docker Compose, Keycloak, RabbitMQ, MinIO,
PostgreSQL, Redis, Mailpit e scripts E2E. O Compose base executa os
microsservicos por imagem; o override dev constroi imagens locais a partir dos
repositorios irmaos.

## Pre-requisitos

- Docker e Docker Compose.
- Repositorios irmaos no mesmo diretorio:
  - `../fiapx-video-management`
  - `../fiapx-video-processing`
- PowerShell para scripts E2E e deploy local.

## Environment

`.env.example` e uma configuracao DEMO/local versionavel e funcional. Ela nao
deve conter tokens reais, senhas pessoais, PAT GitHub, credenciais cloud ou
secrets de producao.

Para configuracao privada local, copie os valores necessarios para `.env`.
O arquivo `.env` e ignorado pelo Git e e a fonte de verdade operacional para:

- `VIDEO_MANAGEMENT_IMAGE`
- `VIDEO_PROCESSING_IMAGE`

O CI/CD de infraestrutura nao substitui arbitrariamente essas imagens. Elas
representam o ultimo deploy confirmado pelos CDs dos microsservicos.

## Usuarios DEMO

O realm Keycloak versionado provisiona os usuarios DEMO oficiais do ambiente
integrado:

- `usertest1`, e-mail `usertest1@fiapx.local`
- `usertest2`, e-mail `usertest2@fiapx.local`

As senhas sao locais/DEMO:

- `fiapx_usertest1_demo_password`
- `fiapx_usertest2_demo_password`

Nao use essas credenciais fora do ambiente local/demonstracao.

## Desenvolvimento Integrado

Constroi os microsservicos localmente e sobe todo o ambiente:

```powershell
docker compose `
  --env-file .env `
  -f docker-compose.yml `
  -f docker-compose.dev.yml `
  up -d --build
```

Scale do Processor em dev:

```powershell
docker compose `
  --env-file .env `
  -f docker-compose.yml `
  -f docker-compose.dev.yml `
  up -d --build --scale video-processing-service=3
```

## Execucao Por Imagens

Usa somente as imagens indicadas no `.env`:

```powershell
docker compose `
  --env-file .env `
  -f docker-compose.yml `
  up -d
```

Scale do Processor por imagens:

```powershell
docker compose `
  --env-file .env `
  -f docker-compose.yml `
  up -d --scale video-processing-service=3
```

Para uso local sem `.env`, os mesmos comandos podem usar `--env-file .env.example`.

## CI

O workflow `.github/workflows/ci.yml` executa em `ubuntu-24.04` para
`pull_request`, `push` em `main` e `workflow_dispatch`.

Validacoes principais:

- YAML/Compose via `docker compose config`;
- JSON de RabbitMQ e Keycloak;
- scripts PowerShell via parser;
- ausencia de `.env` versionado;
- `.env.example` somente DEMO/local;
- Compose base image-only;
- services, volumes e imagens esperados;
- nenhuma imagem `latest`.

## CD

O deploy de infraestrutura roda somente em `push` na `main`, depois do CI verde,
em um self-hosted runner Windows repo-scoped:

- pasta sugerida: `C:\actions-runner-infra`
- nome: `fiapx-infra-deploy`
- labels: `self-hosted`, `Windows`, `X64`, `fiap-fase5`
- inicio inicial via `run.cmd`, nao Windows Service

O workflow usa `permissions: contents: read`, checkout sem credenciais
persistidas e `github.token` efemero apenas para buscar o commit operacional.
O token nao deve ser impresso nem persistido.

Configure a variavel do repositorio:

```text
DEPLOY_INFRA_PATH=C:\Projetos\fiap-fase5\fiapx-infra
```

Se a maquina ainda nao tiver `.env`, configure tambem:

```text
BOOTSTRAP_VIDEO_MANAGEMENT_IMAGE=ghcr.io/<owner>/fiapx-video-management:<sha>
BOOTSTRAP_VIDEO_PROCESSING_IMAGE=ghcr.io/<owner>/fiapx-video-processing:<sha>
```

Essas imagens precisam estar pinadas por tag SHA de commit ou digest.

## Working Copy Operacional

`DEPLOY_INFRA_PATH` e a working copy operacional. O CD pode deixa-la em
detached HEAD no `GITHUB_SHA` implantado.

Antes de atualizar essa working copy, o deploy exige arvore versionada limpa.
Arquivos ignorados como `.env` sao preservados. Nao ha diretorio alternativo de
deploy.

## Ordem Segura do Deploy

O CD participa do mutex global:

```text
Global\FiapXDeployLock
```

Ordem obrigatoria:

1. adquirir o lock;
2. capturar a escala existente do Processor por labels Docker, excluindo one-off;
3. atualizar a working copy operacional para `GITHUB_SHA`;
4. validar `.env` e Compose;
5. fazer pull das imagens;
6. subir somente `postgres redis rabbitmq minio keycloak mailpit`;
7. aguardar infraestrutura base;
8. reconciliar RabbitMQ;
9. executar `docker compose run --rm --no-deps minio-init`;
10. executar `docker compose run --rm --no-deps video-management-migrations`;
11. subir/reconciliar `video-management-service`;
12. subir/reconciliar `video-processing-service` com escala explicita;
13. validar health integrado.

O CD nunca executa `docker compose up -d` generico.

## Escala do Processor

A escala anterior do Processor e estado operacional do runtime.

- Se existem containers anteriores, o CD preserva exatamente `N`.
- Se nenhum container anterior existe, o CD usa bootstrap scale `1`.

Se todos os containers forem removidos, nao ha informacao confiavel para
recuperar automaticamente a escala anterior. Nesse caso o ambiente e reconstruido
com escala inicial `1`.

## Recuperacao

Cenario suportado:

```text
containers ausentes
images ausentes
volumes preservados
        |
Infra CD/bootstrap
        |
pull das imagens
        |
recriacao da stack
        |
health integrado
```

O deploy nao executa:

- `docker compose down -v`
- `docker volume prune`
- `docker system prune`

Dados PostgreSQL, objetos MinIO, estado RabbitMQ, estado Keycloak e volumes nao
sao removidos automaticamente.

## Zero-State

Com volumes novos:

- PostgreSQL nasce pelo container e migrations do Management.
- Redis nasce vazio e funcional.
- RabbitMQ nasce pelo usuario/permissoes e `rabbitmq/definitions.json`.
- MinIO nasce com bucket/event notification via `minio-init`.
- Keycloak nasce com realm, clients e usuarios DEMO `usertest1`/`usertest2`.
- Mailpit e stateless.
- Management e Processor nascem se `.env` apontar para imagens GHCR pullable.

## Rollback

Reverter um commit de infraestrutura e rerodar o CD faz rollback/reconciliacao
da configuracao versionada.

Isso nao desfaz automaticamente:

- dados PostgreSQL;
- objetos MinIO;
- estado RabbitMQ;
- estado Keycloak;
- volumes;
- migrations ja aplicadas.

Rollback destrutivo de dados fica fora do CD automatico.

## Health Integrado

O deploy valida:

- PostgreSQL, Redis, RabbitMQ e MinIO por health/container;
- Keycloak pelo realm HTTP;
- Mailpit pela interface HTTP;
- Management por `/health`;
- Processor por containers vivos e `consumer_count` da fila `video.processing`.

## E2E

Modo dev, com build local:

```powershell
.\scripts\e2e-rabbitmq.ps1 -EnvFile .\.env.example -BootstrapUsers
```

Modo image-only, sem build local:

```powershell
.\scripts\e2e-rabbitmq.ps1 -EnvFile .\.env.example -ImageOnly -SkipBuild -BootstrapUsers
```

Se `-EnvFile` nao for informado, o script usa `.env` quando existir; caso
contrario usa `.env.example` e informa o arquivo escolhido.

## URLs Locais

- API Video Management: http://localhost:8080
- Keycloak: http://localhost:8081
- MinIO Console: http://localhost:9001
- MinIO API: http://localhost:9000
- RabbitMQ Management: http://localhost:15672
- Mailpit: http://localhost:8025
- PostgreSQL: localhost:5432
- Redis: localhost:6379
