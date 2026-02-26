# Azure DevOps Server 2022 - Inventory Tool

Herramienta completa para inventariar todos los objetos de Azure DevOps Server 2022 On-Premise con exportación flexible a CSV y JSON.

## Características

- Conexión directa a Azure DevOps Server 2022 On-Prem via REST API
- Inventario completo de todos los objetos (proyectos, repos, pipelines, work items, etc.)
- Selección flexible mediante CLI: inventariar todo, categorías específicas, o excluir categorías
- Exportación a CSV en carpetas organizadas con timestamp para análisis en Excel/PowerBI
- Exportación a JSON para procesamiento programático
- Soporte SSL configurable para certificados autofirmados
- Progreso en tiempo real con feedback detallado

## Objetos Inventariados

### Core & Projects
- Team Projects
- Teams
- Process Templates

### Work Items
- Work Item Types (WIT)
- Work Item Fields (Custom/System)
- Work Item States & Transitions
- Area Paths
- Iteration Paths
- Queries (Shared & Personal)

### Boards & Planning
- Kanban Boards
- Backlogs
- Delivery Plans
- Dashboards & Widgets

### Repositories
- Git Repositories
- Branches
- Branch Policies
- Pull Requests

### Pipelines
- Build Pipelines (Classic & YAML)
- Release Pipelines (Classic)
- Variable Groups
- Service Connections
- Environments
- Deployment Groups
- Secure Files

### Artifacts
- Artifact Feeds (Azure Artifacts)
- Package Feeds (NuGet/npm/Maven/Python)

### Test Management
- Test Plans
- Test Suites
- Test Runs & Results

### Security
- Users & Access Levels
- Security Groups
- Permissions

### Extensions & Integrations
- Installed Extensions (Marketplace)
- Service Hooks
- Webhooks

### Infrastructure
- Agent Pools
- Self-hosted Agents

## Instalación

### Requisitos

- Python 3.8 o superior
- Azure DevOps Server 2022 On-Premise
- Personal Access Token (PAT) con permisos de lectura

### Pasos de Instalación

```bash
# Clonar el repositorio
git clone https://github.com/armblaorg/inventario-azuredevops.git
cd inventario-azuredevops

# Cambiar al directorio src
cd src

# Instalar dependencias
pip install -r requirements.txt

# Copiar archivo de configuración
cp .env.example .env

# Editar .env con tus credenciales
nano .env  # o usar tu editor preferido
```

## Estructura del Proyecto

```
inventario-azuredevops/
├── .gitignore
├── README.md
└── src/
    ├── __init__.py
    ├── .env.example
    ├── requirements.txt
    ├── config.py
    ├── main.py
    ├── csv_exporter.py
    ├── inventory_cli.py
    └── run_examples.sh
```

## Configuración del PAT Token

1. Accede a tu Azure DevOps Server: `https://your-server/_usersSettings/tokens`
2. Crear nuevo Personal Access Token con permisos de LECTURA en:
   - Code (Read)
   - Work Items (Read)
   - Build (Read)
   - Release (Read)
   - Test Management (Read)
   - Graph (Read)
   - Project and Team (Read)
   - Packaging (Read)
3. Copiar el token y guardarlo en el archivo `.env`

### Archivo `.env`

```env
AZDO_SERVER_URL=https://your-azuredevops-server.com/tfs
AZDO_PAT=your_personal_access_token_here
AZDO_COLLECTION=DefaultCollection
AZDO_API_VERSION=7.0
OUTPUT_DIR=./inventarios
AZDO_VERIFY_SSL=True
```

## Uso

### Modo Básico

```bash
# Desde el directorio src/
cd src

# Inventario completo en CSV (recomendado)
python inventory_cli.py --all --format csv

# O usando el script interactivo
./run_examples.sh
```

### Inventario Selectivo

```bash
# Desde el directorio src/

# Todo EXCEPTO Boards
python inventory_cli.py --all --exclude boards --format csv

# Todo EXCEPTO Boards y Test Plans
python inventory_cli.py --all --exclude boards test --format csv

# Solo categorías específicas
python inventory_cli.py --include core work_items repos --format csv

# Solo pipelines
python inventory_cli.py --include pipelines --format csv

# Solo infraestructura y seguridad
python inventory_cli.py --include infrastructure security --format csv
```

### Formatos de Salida

```bash
# Solo CSV (carpeta con archivos organizados)
python inventory_cli.py --all --format csv

# Solo JSON (un archivo)
python inventory_cli.py --all --format json

# Ambos formatos (default)
python inventory_cli.py --all --format both

# JSON con formato legible
python inventory_cli.py --all --format json --pretty
```

### Configuración Personalizada

```bash
# Especificar servidor y credenciales directamente
python inventory_cli.py --all \
  --server https://tfs.company.com/tfs \
  --collection MyCollection \
  --token YOUR_PAT_HERE \
  --format csv

# Para servidores con certificados autofirmados
python inventory_cli.py --all --no-ssl-verify --format csv

# Carpeta personalizada para CSV
python inventory_cli.py --all --format csv --csv-dir mis_inventarios

# Archivo JSON personalizado
python inventory_cli.py --all --format json --output mi_inventario.json

# Modo silencioso
python inventory_cli.py --all --quiet --format csv
```

## Estructura de Salida CSV

Cuando se genera un inventario en CSV, se crea una carpeta con timestamp:

```
inventarios/
└── inventory_20260226_143022/
    ├── inventory_metadata.csv
    ├── 01_projects/
    │   ├── projects_summary.csv
    │   └── teams.csv
    ├── 02_work_items/
    │   ├── work_item_types.csv
    │   ├── fields.csv
    │   └── queries.csv
    ├── 03_boards/
    │   ├── boards.csv
    │   └── backlogs.csv
    ├── 04_repositories/
    │   ├── repositories.csv
    │   └── branch_policies.csv
    ├── 05_pipelines/
    │   ├── build_pipelines.csv
    │   ├── release_pipelines.csv
    │   ├── variable_groups.csv
    │   ├── service_connections.csv
    │   └── environments.csv
    ├── 06_artifacts/
    │   └── feeds.csv
    ├── 07_test/
    │   └── test_plans.csv
    ├── 08_security/
    │   ├── users.csv
    │   └── security_groups.csv
    ├── 09_infrastructure/
    │   ├── agent_pools.csv
    │   └── agents.csv
    └── 10_extensions/
        └── installed_extensions.csv
```

### Ventajas del Formato CSV

- Compatible con Excel: Abre directamente en Microsoft Excel con encoding UTF-8-BOM
- Importable a bases de datos: MySQL, PostgreSQL, SQL Server, SQLite
- Análisis con PowerBI: Importación directa para dashboards
- Organización clara: Archivos separados por categoría
- Historial: Carpetas con timestamp permiten comparar inventarios

## Categorías Disponibles

| Categoría | Descripción | Objetos Incluidos |
|-----------|-------------|-------------------|
| `core` | Proyectos y Teams | Projects, Teams, Process Templates |
| `work_items` | Work Items | WIT Types, Fields, States, Areas, Iterations, Queries |
| `boards` | Boards y Planificación | Boards, Backlogs, Delivery Plans, Dashboards |
| `repos` | Repositorios | Repos, Branches, Policies, Pull Requests |
| `pipelines` | Pipelines | Build, Release, Variables, Connections, Environments |
| `artifacts` | Artifacts | Feeds, Packages |
| `test` | Test Management | Test Plans, Suites, Cases, Runs |
| `security` | Seguridad | Users, Groups, Permissions |
| `extensions` | Extensiones | Extensions, Service Hooks |
| `infrastructure` | Infraestructura | Agent Pools, Agents |

## Troubleshooting

### Error: SSL Certificate Verify Failed

**Solución**: Usar `--no-ssl-verify` para certificados autofirmados

```bash
python inventory_cli.py --all --no-ssl-verify --format csv
```

### Error: Unauthorized (401)

**Causa**: PAT token inválido o sin permisos

**Solución**:
1. Verificar que el PAT token sea válido
2. Verificar que tenga permisos de lectura en todas las áreas
3. Regenerar el token si es necesario

### Error: Not Found (404)

**Causa**: URL del servidor o colección incorrecta

**Solución**:
```bash
# Verificar URL (debe incluir /tfs para on-prem)
python inventory_cli.py --all \
  --server https://your-server/tfs \
  --collection DefaultCollection
```

### CSV no abre correctamente en Excel

**Solución**: Los archivos usan UTF-8 con BOM para compatibilidad con Excel

Si tienes problemas:
1. Abrir Excel
2. Data → From Text/CSV
3. Seleccionar archivo
4. File Origin: UTF-8

### Caracteres especiales aparecen incorrectamente

**Solución**: Asegúrate de que tu editor soporte UTF-8. Los CSVs incluyen BOM (Byte Order Mark) para compatibilidad automática con Excel.

### Inventario muy lento

**Optimizaciones**:
```bash
# Excluir boards (hace muchas llamadas API por team)
python inventory_cli.py --all --exclude boards --format csv

# Inventariar solo lo necesario
python inventory_cli.py --include core work_items repos pipelines --format csv
```

## Contribuir

Las contribuciones son bienvenidas:

1. Fork el proyecto
2. Crear una rama para tu feature (`git checkout -b feature/AmazingFeature`)
3. Commit tus cambios (`git commit -m 'Add some AmazingFeature'`)
4. Push a la rama (`git push origin feature/AmazingFeature`)
5. Abrir un Pull Request

## Licencia

MIT License - ver archivo [LICENSE](LICENSE) para detalles

## Autor

**Armando Blanco** (@armblaorg)

## Agradecimientos

- Equipo de Azure DevOps por la excelente documentación de APIs
- Comunidad de Azure DevOps Server

## Soporte

Si encuentras problemas o tienes preguntas:

1. Revisar la sección [Troubleshooting](#troubleshooting)
2. Abrir un [Issue](https://github.com/armblaorg/inventario-azuredevops/issues)
3. Consultar la [documentación de Azure DevOps REST API](https://learn.microsoft.com/en-us/rest/api/azure/devops/)

## Roadmap

- Soporte para Azure DevOps Services (Cloud)
- Exportación a Excel (xlsx) con formato
- Dashboard web interactivo
- Comparación de inventarios (diff entre fechas)
- Filtros avanzados (por fecha, estado, etc.)
- Paralelización de llamadas API
- Base de datos SQLite opcional
- Reportes en HTML/PDF

---

**Nota**: Esta herramienta es para inventario de lectura únicamente. No modifica ningún objeto en Azure DevOps Server.
