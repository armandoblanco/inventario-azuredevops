# Quick Start Guide - .NET Framework 4.0 Version

## 🚀 Inicio Rápido

**Compatible con .NET Framework 4.0 y superior** - ¡Funciona en sistemas legacy!

### 1. Configuración Inicial

Edita el archivo `src/net/App.config`:

```xml
<appSettings>
  <add key="AZDO_SERVER_URL" value="https://tu-servidor.empresa.com/tfs"/>
  <add key="AZDO_COLLECTION" value="DefaultCollection"/>
  <add key="AZDO_PAT" value="TU-TOKEN-AQUI"/>
  <add key="AZDO_VERIFY_SSL" value="True"/>
</appSettings>
```

### 2. Compilar

```bash
cd src/net
dotnet build -c Release
```

### 3. Ejecutar

```bash
# Opción 1: Con dotnet
dotnet run

# Opción 2: Ejecutable directo
./bin/Release/net48/AzureDevOpsInventory.exe
```

### 4. Ver Resultados

Los reportes se generan en:
```
inventarios/inventory_YYYYMMDD_HHMMSS/
```

## 📋 Comandos Útiles

### Inventario Completo (Por Defecto)
```bash
dotnet run
```

### Inventario de Repositorios y Pipelines
```bash
dotnet run -- --categories repos,pipelines
```

### Exportar a JSON y CSV
```bash
dotnet run -- --json
```

### Modo Silencioso
```bash
dotnet run -- --quiet
```

### Ver Ayuda
```bash
dotnet run -- --help
```

## 🔑 Obtener Personal Access Token (PAT)

1. Ve a Azure DevOps Server
2. Click en tu perfil → Security → Personal Access Tokens
3. Crea un nuevo token con los siguientes scopes:
   - Project and Team: Read
   - Work Items: Read
   - Code: Read
   - Build: Read
   - Release: Read
   - Test Management: Read
   - Graph: Read

## ⚙️ Opciones de Línea de Comandos

```
-h, --help              Mostrar ayuda
-c, --categories LIST   Categorías a inventariar (separadas por coma)
-q, --quiet             Modo silencioso
--json                  También exportar a JSON
--no-csv                No exportar CSV
--csv-only              Solo exportar CSV (por defecto)
```

## 📂 Categorías Disponibles

- `all` - Todas (por defecto)
- `core` - Proyectos y equipos
- `work_items` - Work items y fields
- `boards` - Boards y backlogs
- `repos` - Repositorios
- `pipelines` - Build y Release pipelines
- `artifacts` - Feeds y paquetes
- `test` - Test plans
- `security` - Grupos y usuarios
- `extensions` - Extensiones instaladas
- `infrastructure` - Agent pools

## ❗ Solución de Problemas

### Error de SSL
```xml
<add key="AZDO_VERIFY_SSL" value="False"/>
```

### Error de Autenticación
Verifica que tu PAT tenga los permisos necesarios y no haya expirado.

### Timeout
Para inventarios grandes, ejecuta por categorías específicas:
```bash
dotnet run -- --categories core
dotnet run -- --categories repos
dotnet run -- --categories pipelines
```

## 📖 Más Información

- [src/net/README.md](src/net/README.md) - Documentación detallada del proyecto .NET
- **Requisitos**: .NET Framework 4.0 o superior
- **Compatibilidad**: Windows Server 2008 R2+ / Windows 7+
