# FIAP X Infra

Infraestrutura compartilhada para execução local/integrada da solução FIAP X.

Este repositório concentra Docker Compose, Keycloak, RabbitMQ, MinIO, PostgreSQL,
Redis, Mailpit e scripts E2E. O Compose base executa os microsserviços por
imagem; o override dev constrói imagens locais a partir dos repositórios irmãos.

## Pré-requisitos

- Docker e Docker Compose.
- Repositórios irmãos no mesmo diretório:
  - `../fiapx-video-management`
  - `../fiapx-video-processing`
- PowerShell para scripts E2E.

## Environment

`.env.example` é uma configuração DEMO/local versionável e funcional. Ela não
deve conter tokens reais, senhas pessoais, PAT GitHub, credenciais cloud ou
secrets de produção.

Para configuração privada local, copie os valores necessários para `.env`.
O arquivo `.env` é ignorado pelo Git.

No futuro, CI/CD deve usar GitHub Secrets e substituir apenas:

- `VIDEO_MANAGEMENT_IMAGE`
- `VIDEO_PROCESSING_IMAGE`

## Desenvolvimento Integrado

Constrói os microsserviços localmente e sobe todo o ambiente:

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

## Execução Por Imagens

Usa somente as imagens indicadas no `.env`:

```powershell
docker compose `
  --env-file .env `
  up -d
```

Scale do Processor por imagens:

```powershell
docker compose `
  --env-file .env `
  up -d --scale video-processing-service=3
```

Para uso local sem `.env`, os mesmos comandos podem usar `--env-file .env.example`.

## URLs Locais

- API Video Management: http://localhost:8080
- Keycloak: http://localhost:8081
- MinIO Console: http://localhost:9001
- MinIO API: http://localhost:9000
- RabbitMQ Management: http://localhost:15672
- Mailpit: http://localhost:8025
- PostgreSQL: localhost:5432
- Redis: localhost:6379

## E2E

Modo dev, com build local:

```powershell
.\scripts\e2e-rabbitmq.ps1 -EnvFile .\.env.example -BootstrapUsers
```

Modo image-only, sem build local:

```powershell
.\scripts\e2e-rabbitmq.ps1 -EnvFile .\.env.example -ImageOnly -SkipBuild -BootstrapUsers
```

Se `-EnvFile` não for informado, o script usa `.env` quando existir; caso
contrário usa `.env.example` e informa o arquivo escolhido.
