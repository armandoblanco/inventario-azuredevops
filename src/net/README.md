# Azure DevOps Server 2022 - Inventory Tool (.NET Framework 4.0)

## Overview
This is the .NET Framework 4.0 implementation of the Azure DevOps Server 2022 Inventory Tool. It provides comprehensive inventory capabilities for Azure DevOps Server instances, with support for projects, repositories, pipelines, work items, and more.

**Compatible with .NET Framework 4.0 and higher** - No async/await, runs on legacy systems!

## Features
- 🔍 **Complete Inventory**: Projects, Teams, Repos, Pipelines, Work Items, Boards, Artifacts, Tests, Security
- 📊 **CSV Export**: Organized CSV reports with UTF-8 BOM encoding for Excel compatibility
- 📝 **JSON Export**: Full JSON dump of inventory data
- 🎯 **Category Selection**: Choose specific categories to inventory
- 🔐 **PAT Authentication**: Secure authentication using Personal Access Tokens
- ⚙️ **Configurable**: Easy configuration via App.config

## Prerequisites
- .NET Framework 4.0 or higher (compatible with 4.0, 4.5, 4.6, 4.7, 4.8)
- Azure DevOps Server 2022 (or compatible version)
- Personal Access Token (PAT) with appropriate permissions

## Technical Details
- **Target Framework**: .NET Framework 4.0
- **No async/await**: Fully synchronous implementation for maximum compatibility
- **HttpWebRequest**: Uses classic WebRequest instead of HttpClient
- **Compatible with**: Windows Server 2008 R2 and newer


## Configuration

Edit `App.config` to set your Azure DevOps Server connection details:

```xml
<appSettings>
  <add key="AZDO_SERVER_URL" value="https://your-server.company.com/tfs"/>
  <add key="AZDO_COLLECTION" value="DefaultCollection"/>
  <add key="AZDO_PAT" value="your-personal-access-token-here"/>
  <add key="AZDO_VERIFY_SSL" value="True"/>
  <add key="AZDO_API_VERSION" value="7.0"/>
  <add key="OUTPUT_DIR" value="./inventarios"/>
</appSettings>
```

## Building the Project

```bash
# Restore NuGet packages and build
dotnet build

# Build in Release mode
dotnet build -c Release
```

## Usage

### Basic Usage (Full Inventory)
```bash
dotnet run
# or after building:
./bin/Debug/net48/AzureDevOpsInventory.exe
```

### Category-Specific Inventory
```bash
# Inventory only repositories and pipelines
dotnet run -- --categories repos,pipelines

# Inventory core project information
dotnet run -- --categories core,work_items
```

### Export Options
```bash
# Export to both CSV and JSON
dotnet run -- --json

# Export only to JSON (no CSV)
dotnet run -- --json --no-csv

# Quiet mode with JSON export
dotnet run -- --quiet --json
```

## Available Categories

| Category | Description |
|----------|-------------|
| `all` | All categories (default) |
| `core` | Team Projects, Teams, Process Templates |
| `work_items` | Work Item Types, Fields, States, Areas, Iterations, Queries |
| `boards` | Kanban Boards, Backlogs, Delivery Plans, Dashboards |
| `repos` | Git Repositories, Branches, Branch Policies, Pull Requests |
| `pipelines` | Build Pipelines, Release Pipelines, Variables, Service Connections |
| `artifacts` | Artifact Feeds, Packages |
| `test` | Test Plans, Test Suites, Test Cases |
| `security` | Security Groups, Users, Permissions |
| `extensions` | Marketplace Extensions, Service Hooks |
| `infrastructure` | Agent Pools, Self-hosted Agents |

## Output Structure

The tool creates a timestamped directory with organized CSV files:

```
inventarios/
└── inventory_20260316_153045/
    ├── 01_projects/
    │   ├── projects_summary.csv
    │   └── teams.csv
    ├── 02_work_items/
    │   └── work_item_types.csv
    ├── 04_repositories/
    │   └── repositories.csv
    ├── 05_pipelines/
    │   └── build_pipelines.csv
    └── ...
```

## Command-Line Options

```
-h, --help              Show help message
-c, --categories LIST   Comma-separated list of categories to inventory
-q, --quiet             Suppress verbose output
--json                  Also1): JSON serialization
- **System.Configuration**: Configuration management (included in .NET Framework 4.0)
--csv-only              Export only CSV files (default)
```

## Dependencies

- **Newtonsoft.Json** (13.0.3): JSON serialization
- **System.Configuration.ConfigurationManager** (8.0.0): Configuration management

## Project Structure

```
src/net/
├── AzureDevOpsInventory.csproj  # Project file
├── App.config                    # Configuration file
├── Program.cs                    # Entry point and CLI
├── Config.cs                     # Configuration management
├── AzureDevOpsClient.cs         # API client
├── InventoryRunner.cs           # Inventory orchestration
├── CsvExporter.cs               # CSV export functionality
└── README.md                     # This file
```

## Migration Notes

This .NET implementation is functionally equivalent to the Python version with the following characteristics:

- **Maximum Compatibility**: Targets .NET Framework 4.0 for legacy system support
- **Synchronous Execution**: No async/await for compatibility with .NET 4.0
- **Type Safety**: Strong typing with C# classes
- **Classic Networking**: Uses HttpWebRequest instead of HttpClient
- **Configuration**: App.config for easy deployment configuration
- **Error Handling**: Comprehensive exception handling
- **Windows Integration**: Native Windows executable

## Troubleshooting

### SSL Certificate Errors
If you're using self-signed certificates, set `AZDO_VERIFY_SSL` to `False` in App.config.

### Authentication Errors
Ensure your Personal Access Token (PAT) has the following scopes:
- Project and Team: Read
- Work Items: Read
- Code: Read
- Build: Read
- Release: Read
- Test Management: Read
- Graph: Read

### Connection Timeouts
The default timeout is 30 seconds. For large inventories, consider running category-specific inventories.

## License
This project follows the same license as the Python implementation.
