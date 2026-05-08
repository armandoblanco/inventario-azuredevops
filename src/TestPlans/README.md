# TestPlans — Inventario y Migración de Test Plans

Scripts PowerShell para inventariar y migrar **Azure DevOps Test Plans** desde
Azure DevOps Server **OnPrem** hacia Azure DevOps Services **Cloud**.

> Compatible con Windows PowerShell 5.1+ y PowerShell 7+. Macros, fechas y rutas
> de área se reescriben automáticamente al nombre del proyecto destino.

---

## 1. Scripts incluidos

| Script | Propósito |
|---|---|
| `Get-TestPlans.ps1` | Inventario completo de Test Plans / Suites / Test Cases en origen. Genera CSV + JSON. **Solo lectura.** |
| `Test-TargetClassificationNodes.ps1` | Pre-valida que las Áreas e Iteraciones referenciadas existan en destino. Con `-CreateMissing` las crea respetando jerarquía. |
| `Build-IdentityMap.ps1` | Mapea identidades (owners, asignados) origen → destino consultando `vssps.dev.azure.com/{org}/_apis/identities`. |
| `Migrate-TestPlans.ps1` | Migración por fases (configs, test cases, plans, suites, runs export) con **dry-run por defecto** y mappings persistentes JSON. |
| `Migrate-ProjectUsers.ps1` | **(Opcional)** Migra usuarios y Teams del proyecto origen al destino: alta con licencia, creación de teams y asignación de miembros. |

---

## 2. Configuración: `src/.env`

Los 4 scripts leen `src/.env` (un nivel arriba de esta carpeta). Variables:

```env
# === ORIGEN: Azure DevOps Server OnPrem ===
ADO_BASE=https://bcrtfs/tfs/BCRCollection
ADO_PAT=<PAT-del-TFS-onprem>

# === DESTINO: Azure DevOps Services (Cloud) ===
ADO_TARGET_ORG_URL=https://dev.azure.com/MiOrg
ADO_TARGET_PAT=<PAT-del-cloud>
ADO_TARGET_PROJECT=NombreExactoDelProyectoDestino
```

### Scopes mínimos del PAT destino (cloud)

Generar en `https://dev.azure.com/{org}/_usersSettings/tokens`:

- **Work Items** → Read & Write
- **Test Management** → Read, Write & Manage
- **Project and Team** → Read, Write & Manage
- **Identity** → Read

### Scopes mínimos del PAT origen (TFS)

- **Work Items** → Read
- **Test Management** → Read
- **Project and Team** → Read

---

## 3. Flujo recomendado de migración

> Ejecutar todos los comandos desde `D:\develop\inventario-azuredevops\src\TestPlans\`.

### Paso 1 — Inventario (opcional, recomendado)

Ver qué hay en el origen antes de migrar:

```powershell
.\Get-TestPlans.ps1 -TeamProject "TPBCRSICCRED"
```

Genera CSV/JSON en `.\testplans-inventory\`.

### Paso 2 — Pre-validar Áreas e Iteraciones

Verifica que toda la jerarquía referenciada existe en destino y, opcionalmente,
la crea automáticamente:

```powershell
# Modo solo reporte
.\Test-TargetClassificationNodes.ps1 -SourceProject "TPBCRSICCRED" -TargetProject "Prueba"

# Crear lo faltante
.\Test-TargetClassificationNodes.ps1 -SourceProject "TPBCRSICCRED" -TargetProject "Prueba" -CreateMissing
```

### Paso 3 — Mapping de identidades

Resuelve los owners/asignados origen → destino:

```powershell
.\Build-IdentityMap.ps1 -SourceProject "TPBCRSICCRED" -TargetProject "Prueba" -Interactive
```

`-Interactive` te pide manualmente el email destino para usuarios no resueltos
(ENTER para omitirlos). Salida: `..\testplans-migration\identity-map.json`.

### Paso 4 — Dry-run de migración

Sin `-Execute` el script **no escribe nada** en destino, solo simula y deja log:

```powershell
.\Migrate-TestPlans.ps1 `
    -SourceProject "TPBCRSICCRED" `
    -TargetProject "Prueba" `
    -IdentityMapFile ..\testplans-migration\identity-map.json
```

Revisar el log y los `[DRY-RUN]` antes de seguir.

### Paso 5 — Ejecución real

```powershell
.\Migrate-TestPlans.ps1 `
    -SourceProject "TPBCRSICCRED" `
    -TargetProject "Prueba" `
    -IdentityMapFile ..\testplans-migration\identity-map.json `
    -Execute
```

> El backtick `` ` `` al final de cada línea es el carácter de **continuación de
> línea en PowerShell** (equivalente a `\` en bash). Permite partir un comando
> largo. También puedes escribir todo en una sola línea sin backticks.

### Paso 6 (Opcional) — Migrar Usuarios y Teams

Si necesita dar de alta a los usuarios del proyecto origen en la organización
destino y recrear los Teams con sus miembros, use `Migrate-ProjectUsers.ps1`.

**Requisitos adicionales del PAT destino:**
- **Member Entitlement Management** → Read & Write
- **Graph** → Read & Manage

#### 6a — Generar inventario de usuarios

```powershell
.\Migrate-ProjectUsers.ps1 -SourceProject "TPBCRSICCRED"
```

Genera `users-migration/users-manifest.csv` con todos los usuarios y sus teams.

#### 6b — Completar el CSV

Abra `users-manifest.csv` y complete:

| Columna | Descripción |
|---|---|
| `TargetEmail` | Email/UPN del usuario en Azure AD (Entra ID) |
| `AccessLevel` | `stakeholder`, `express` (Basic) o `advanced` (VS Enterprise) |
| `GroupType` | `projectReader`, `projectContributor` o `projectAdministrator` |
| `Teams` | Teams separados por `;` (se pre-llenan del origen) |

Elimine filas de usuarios que **no** desee migrar (cuentas de servicio, etc.).

#### 6c — Dry-run

```powershell
.\Migrate-ProjectUsers.ps1 -SourceProject "TPBCRSICCRED" `
    -ManifestFile ".\users-migration\users-manifest.csv"
```

#### 6d — Ejecución real

```powershell
.\Migrate-ProjectUsers.ps1 -SourceProject "TPBCRSICCRED" `
    -ManifestFile ".\users-migration\users-manifest.csv" -Execute
```

#### Opciones adicionales

| Flag | Efecto |
|---|---|
| `-SkipTeamCreation` | Solo da de alta usuarios, no crea Teams |
| `-SkipMemberships` | Crea Teams pero no asigna miembros |
| `-DefaultAccessLevel express` | Nivel de licencia por defecto en el CSV template |

---

## 4. Variantes útiles

### Migrar un solo Test Plan (filtro por nombre)

```powershell
.\Migrate-TestPlans.ps1 -SourceProject "TPBCRSICCRED" -TargetProject "Prueba" -PlanFilter "TP #SS_P1*" -Execute
```

### Si los Test Cases ya los migró Data Migration Tool

```powershell
.\Migrate-TestPlans.ps1 -SourceProject "TPBCRSICCRED" -TargetProject "Prueba" `
    -SkipTestCases -TestCaseMappingFile .\dmt-mapping.json -Execute
```

`dmt-mapping.json` debe ser `{ "sourceId": targetId, ... }`.

### Saltar el export histórico de Runs (más rápido)

```powershell
.\Migrate-TestPlans.ps1 -SourceProject "TPBCRSICCRED" -TargetProject "Prueba" -SkipRunsExport -Execute
```

### Reanudar después de un fallo

Los mappings se guardan en `..\testplans-migration\mapping-*.json`. Vuelve a
correr el mismo comando: lo ya migrado se omite (idempotente).

---

## 5. Outputs en `..\testplans-migration\`

| Archivo | Contenido |
|---|---|
| `mapping-testcases.json` | sourceId → targetId de cada Test Case |
| `mapping-configurations.json` | sourceId → targetId de Configurations |
| `mapping-plans.json` | sourceId → targetId de Test Plans |
| `mapping-suites.json` | `"planId/suiteId"` → targetSuiteId |
| `identity-map.json` | mapping de owners/asignados |
| `classification_validation_*.csv\|.json` | reporte de áreas/iteraciones |
| `migrate_testplans_*.log` | log detallado de la corrida |
| `test-runs-export\run_*.json` | export histórico de ejecuciones (no se recrean) |

### En `users-migration\` (si se usa Paso 6)

| Archivo | Contenido |
|---|---|
| `users-manifest.csv` | CSV editable con usuarios a migrar |
| `source-inventory.json` | Inventario completo de teams y miembros del origen |
| `mapping-users.json` | email → descriptor/id en destino |
| `mapping-teams.json` | teamName → teamId en destino |

---

## 6. Endpoints REST utilizados

### Origen (TFS Server, API 5.0)
- `GET /_apis/projects`
- `GET /{project}/_apis/test/plans`
- `GET /{project}/_apis/test/plans/{id}/suites`
- `GET /{project}/_apis/test/plans/{id}/suites/{id}/testcases`
- `GET /{project}/_apis/test/plans/{id}/suites/{id}/points`
- `GET /{project}/_apis/test/runs`
- `POST /{project}/_apis/wit/wiql`
- `GET /{project}/_apis/wit/workitems?ids=…`

### Destino (ADO Services, API 7.1 — endpoint moderno `testplan/*`)
- `POST /{project}/_apis/wit/workitems/$Test Case` (crear Test Case)
- `POST /{project}/_apis/testplan/plans` (crear Test Plan)
- `POST /{project}/_apis/testplan/Plans/{id}/suites` (crear Suite)
- `POST /{project}/_apis/testplan/Plans/{planId}/Suites/{suiteId}/TestCase` (asociar TCs)
- `POST /{project}/_apis/test/configurations` (crear Configuration)
- `POST /{project}/_apis/wit/classificationnodes/{areas|iterations}/...` (crear Áreas/Iteraciones)
- `GET https://vssps.dev.azure.com/{org}/_apis/identities` (resolver identidades)

---

## 7. Limitaciones conocidas

- **Test Runs históricos no se recrean.** Se exportan a JSON como archivo
  histórico (la API destino no permite reinyectar runs preservando timestamps
  originales).
- **Áreas/Iteraciones deben existir en destino** antes de migrar plans/test
  cases (usar el Paso 2).
- **Suites query-based**: la WIQL se copia con un replace simple del nombre del
  proyecto. Si la query referencia rutas de área específicas, revisar manualmente.
- **Identidades**: si una identidad no existe en el cloud (usuarios deshabilitados
  o no invitados), queda con el owner del PAT. Pre-resolverlas en `identity-map.json`.
- **Adjuntos de Test Cases** (`Steps` con imágenes) se copian como referencia
  HTML. Las imágenes embebidas con URLs internas del TFS quedan rotas — habría
  que reemitirlas con el endpoint de attachments (no implementado).

---

## 8. Troubleshooting

| Síntoma | Causa probable | Solución |
|---|---|---|
| `404 No se puede acceder al proyecto destino` | Slug de organización o nombre de proyecto incorrecto | Abrir `https://dev.azure.com/{org}/{project}` en el navegador y ajustar `.env` |
| `404 al crear Plan` con `/test/plans` | Endpoint legacy | Verificar que estás en la última versión (usa `/testplan/plans`) |
| `403 Forbidden` | PAT sin scope correcto | Regenerar PAT con todos los scopes del punto 2 |
| Test Cases creados pero sin asignar a suites | Mapping de TCs no cargado | Verificar `mapping-testcases.json` y reanudar con `-Execute` |
| `unresolved` en `identity-map.json` | Usuario no existe en el cloud | Invitarlo a la organización o usar `-Interactive` para resolver manualmente |

---

## 9. Seguridad

- **Nunca** subir `.env` al repo (ya está en `.gitignore`).
- Si un PAT queda expuesto en logs/screenshots, **revocarlo inmediatamente** en
  `https://dev.azure.com/{org}/_usersSettings/tokens`.
- Los archivos de mapping (`mapping-*.json`, `identity-map.json`) **sí** deberían
  versionarse o respaldarse: permiten reanudar y auditar la migración.
