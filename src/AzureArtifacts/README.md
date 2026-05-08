# AzureArtifacts — Inventario y Migración de Feeds

Scripts PowerShell para inventariar y migrar **Azure Artifacts Feeds** (NuGet, npm)
desde Azure DevOps Server **OnPrem** hacia Azure DevOps Services **Cloud**.

Soporta topología **hub-spoke**: un feed **principal** con upstream a registros
públicos (nuget.org, npmjs.com) y feeds **satélite** que usan el principal como upstream.

> Compatible con Windows PowerShell 5.1+ y PowerShell 7+.

---

## 1. Scripts incluidos

| Script | Propósito |
|---|---|
| `Get-ArtifactFeeds.ps1` | Inventario de feeds, paquetes y upstreams. Genera CSV + JSON. **Solo lectura.** |
| `Migrate-ArtifactFeeds.ps1` | Migración por fases: crear feeds, configurar upstreams (hub-spoke), descargar y publicar paquetes. **Dry-run por defecto.** |

---

## 2. Configuración: `src/.env`

Mismas variables que los scripts de `AzureBoard/`:

```env
# === ORIGEN: Azure DevOps Server OnPrem ===
ADO_BASE=https://bcrtfs/tfs/BCRCollection
ADO_PAT=<PAT-del-TFS-onprem>

# === DESTINO: Azure DevOps Services (Cloud) ===
ADO_TARGET_ORG_URL=https://dev.azure.com/MiOrg
ADO_TARGET_PAT=<PAT-del-cloud>
ADO_TARGET_PROJECT=NombreDelProyectoDestino
```

### Scopes del PAT destino

- **Packaging** → Read, Write & Manage

### Scopes del PAT origen

- **Packaging** → Read

### Requisitos opcionales

- **NuGet**: `dotnet` CLI o `nuget.exe` en PATH (para `nuget push`)
- **npm**: Node.js + npm en PATH (para `npm publish`)
- Si no están disponibles, NuGet se sube vía REST API directamente.

---

## 3. Topología Hub-Spoke

```
                    ┌─────────────────┐
                    │   Internet      │
                    │  nuget.org      │
                    │  npmjs.com      │
                    │  Maven Central  │
                    └────────┬────────┘
                             │ upstream
                    ┌────────▼────────┐
                    │  BCRArtefactos  │   ← Feed PRINCIPAL (hub)
                    │  _feed          │
                    └──┬─────────┬────┘
                       │         │ upstream (interno)
              ┌────────▼──┐  ┌──▼────────────┐
              │ BCRValores │  │ TPBCRComercial │   ← Feeds SATÉLITE
              │ _feed      │  │ _feed          │
              └────────────┘  └────────────────┘
```

El script identifica automáticamente cuál es el feed principal (vía `-PrincipalFeed`)
y configura los demás como satélites apuntando a él.

---

## 4. Flujo de migración

> Ejecutar desde `D:\develop\inventario-azuredevops\src\AzureArtifacts\`.

### Paso 1 — Inventario (solo lectura)

```powershell
.\Get-ArtifactFeeds.ps1
```

O para un solo proyecto:

```powershell
.\Get-ArtifactFeeds.ps1 -TeamProject "TPBCRComercial" -IncludeVersions
```

### Paso 2 — Dry-run de migración

```powershell
.\Migrate-ArtifactFeeds.ps1 -PrincipalFeed "BCRArtefactos_feed"
```

Revise el output para verificar qué feeds se crearán y qué paquetes se migrarán.

### Paso 3 — Crear feeds y configurar upstreams (sin paquetes)

```powershell
.\Migrate-ArtifactFeeds.ps1 -PrincipalFeed "BCRArtefactos_feed" -SkipPackagePush -Execute
```

### Paso 4 — Migración completa con paquetes

```powershell
.\Migrate-ArtifactFeeds.ps1 -PrincipalFeed "BCRArtefactos_feed" -Execute
```

---

## 5. Variantes útiles

### Solo última versión de cada paquete (más rápido)

```powershell
.\Migrate-ArtifactFeeds.ps1 -PrincipalFeed "BCRArtefactos_feed" -OnlyLatestVersion -Execute
```

### Solo paquetes NuGet

```powershell
.\Migrate-ArtifactFeeds.ps1 -PrincipalFeed "BCRArtefactos_feed" -PackageTypes NuGet -Execute
```

### Solo un feed específico

```powershell
.\Migrate-ArtifactFeeds.ps1 -PrincipalFeed "BCRArtefactos_feed" -FeedFilter "TPBCRComercial_feed" -Execute
```

### Reanudar después de un fallo

Los mappings en `mapping-feeds.json` y `mapping-packages.json` permiten reanudar.
Simplemente vuelva a ejecutar el mismo comando.

---

## 6. Outputs

### En `artifacts-inventory/` (inventario)

| Archivo | Contenido |
|---|---|
| `artifact_feeds_*.csv` | Feeds con conteo de paquetes por protocolo |
| `artifact_packages_*.csv` | Detalle de cada paquete (nombre, versión, tipo) |
| `artifact_inventory_*.json` | Inventario completo en JSON |

### En `artifacts-migration/` (migración)

| Archivo | Contenido |
|---|---|
| `source-feeds-inventory.json` | Inventario de feeds origen |
| `mapping-feeds.json` | feedName → feedId en destino |
| `mapping-packages.json` | `protocol:package@version` → status |
| `migrate_artifacts_*.log` | Log detallado de la corrida |

### En `artifacts-staging/` (temporal)

Paquetes descargados (.nupkg, .tgz) pendientes de publicar. Puede eliminarse
después de una migración exitosa.

---

## 7. Endpoints REST utilizados

### Origen (TFS Server, API 5.0)

- `GET /_apis/packaging/feeds` — listar feeds (org-scoped)
- `GET /{project}/_apis/packaging/feeds` — listar feeds (project-scoped)
- `GET /_apis/packaging/feeds/{id}/packages?protocolType=NuGet|Npm` — listar paquetes
- `GET /_apis/packaging/feeds/{id}/packages/{pkgId}/versions` — versiones
- `GET /_apis/packaging/feeds/{id}/nuget/packages/{name}/versions/{ver}/content` — descargar .nupkg
- `GET /_apis/packaging/feeds/{id}/npm/packages/{name}/versions/{ver}/content` — descargar .tgz

### Destino (ADO Services, API 7.1)

- `POST /_apis/packaging/feeds` — crear feed
- `PATCH /_apis/packaging/feeds/{id}` — configurar upstream sources
- `PUT https://pkgs.dev.azure.com/{org}/_packaging/{feed}/nuget/v2` — push NuGet
- `PUT https://pkgs.dev.azure.com/{org}/_packaging/{feed}/npm/registry/` — push npm

---

## 8. Limitaciones

- **Maven y Universal Packages** no soportados en esta versión.
- **Paquetes upstream cacheados** (de nuget.org/npmjs.com) no se descargan del origen:
  se re-cachearán automáticamente cuando se consuman en destino via upstream.
- **Permisos de feed** (contributors, readers) no se migran. Asignar manualmente
  en `https://dev.azure.com/{org}/_packaging?_a=settings&feed={feed}`.
- **Views** (@Release, @Prerelease) se crean por defecto, pero la promoción de
  paquetes a views debe rehacerse.
- Los paquetes con versiones pre-release pueden requerir `--prerelease` en el consume.

---

## 9. Troubleshooting

| Síntoma | Causa | Solución |
|---|---|---|
| `403` al crear feed | PAT sin scope Packaging | Regenerar con Packaging Read, Write & Manage |
| `409 Conflict` al push | Paquete ya existe | Normal si re-ejecuta (idempotente) |
| npm publish falla | Node.js no instalado | Instalar Node.js o migrar solo NuGet con `-PackageTypes NuGet` |
| Upstream "internal" falla | Feed principal aún no creado | Ejecutar con `-SkipPackagePush` primero para crear feeds |
| Paquetes no aparecen en satélite | Upstream no configurado | Verificar en Settings > Upstream Sources del feed destino |
