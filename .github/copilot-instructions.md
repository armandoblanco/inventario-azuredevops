## Contexto del Repositorio

Este repositorio contiene herramientas de inventario para Azure DevOps Server 2022 On-Premises.
Se usa como base para planificar migraciones hacia GitHub (Enterprise Cloud o Enterprise Server).

Los scripts de inventario están en `src/` y cubren: repos Git, TFVC, pipelines, work items,
test plans, artifacts, seguridad, extensiones y agentes.

Cuando se hagan cambios en scripts PowerShell, seguir el patrón existente:
- Carga de `.env` con `Import-DotEnv`
- Autenticación PAT o NTLM/Kerberos
- Función `Invoke-AdoApi` para llamadas REST
- `Write-Status` para logging en consola y archivo
- Salida en CSV y JSON
- Indicadores de progreso en consola
