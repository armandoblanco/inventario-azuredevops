using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Newtonsoft.Json;

namespace AzureDevOpsInventory
{
    /// <summary>
    /// Azure DevOps Server 2022 - Inventory CLI
    /// Command-line interface for flexible inventory execution
    /// Compatible with .NET Framework 4.0
    /// </summary>
    class Program
    {
        static int Main(string[] args)
        {
            Console.WriteLine(@"
╔══════════════════════════════════════════════════════════════════════╗
║                                                                      ║
║      Azure DevOps Server 2022 - Inventory Tool (.NET 4.0)          ║
║                                                                      ║
╚══════════════════════════════════════════════════════════════════════╝
");

            // Parse command-line arguments
            var options = ParseArguments(args);

            if (options.ShowHelp)
            {
                ShowHelp();
                return 0;
            }

            // Validate configuration
            if (string.IsNullOrEmpty(Config.PatToken))
            {
                Console.WriteLine("❌ ERROR: Personal Access Token (PAT) not configured.");
                Console.WriteLine("   Please set AZDO_PAT in App.config");
                return 1;
            }

            // Display configuration
            Console.WriteLine("Configuration:");
            Console.WriteLine(string.Format("  Server:     {0}", Config.ServerUrl));
            Console.WriteLine(string.Format("  Collection: {0}", Config.Collection));
            Console.WriteLine(string.Format("  Categories: {0}", string.Join(", ", options.Categories.ToArray())));
            Console.WriteLine(string.Format("  Verify SSL: {0}", Config.VerifySsl));
            Console.WriteLine();

            try
            {
                // Create Azure DevOps client
                using (var client = new AzureDevOpsClient(
                    Config.ServerUrl,
                    Config.PatToken,
                    Config.Collection,
                    Config.VerifySsl,
                    Config.ApiVersion))
                {
                    // Create inventory runner
                    var runner = new InventoryRunner(client, options.Categories, options.Verbose);

                    // Run inventory
                    var results = runner.RunInventory();

                    if (results == null)
                    {
                        Console.WriteLine("❌ Inventory failed. Please check your configuration and network connection.");
                        return 1;
                    }

                    // Export to JSON
                    if (options.ExportJson)
                    {
                        var jsonPath = Path.Combine(Config.OutputDir, string.Format("inventory_{0}.json", DateTime.Now.ToString("yyyyMMdd_HHmmss")));
                        Directory.CreateDirectory(Config.OutputDir);
                        File.WriteAllText(jsonPath, results.ToString(Formatting.Indented));
                        Console.WriteLine(string.Format("✅ JSON export: {0}", jsonPath));
                    }

                    // Export to CSV
                    if (options.ExportCsv)
                    {
                        var csvExporter = new CsvExporter(Config.OutputDir);
                        csvExporter.CreateDirectoryStructure();
                        csvExporter.ExportAllReports(results);
                    }

                    Console.WriteLine("\n✅ Inventory completed successfully!");
                    return 0;
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine(string.Format("\n❌ ERROR: {0}", ex.Message));
                if (options.Verbose)
                {
                    Console.WriteLine(string.Format("\nStack Trace:\n{0}", ex.StackTrace));
                }
                return 1;
            }
        }

        private static CommandLineOptions ParseArguments(string[] args)
        {
            var options = new CommandLineOptions();
            options.Categories = new List<string>();
            options.Categories.Add("all");
            options.Verbose = true;
            options.ExportJson = false;
            options.ExportCsv = true;
            options.ShowHelp = false;

            for (int i = 0; i < args.Length; i++)
            {
                var arg = args[i].ToLower();
                
                if (arg == "-h" || arg == "--help")
                {
                    options.ShowHelp = true;
                }
                else if (arg == "-c" || arg == "--categories")
                {
                    if (i + 1 < args.Length)
                    {
                        options.Categories = new List<string>(args[++i].Split(','));
                        for (int j = 0; j < options.Categories.Count; j++)
                        {
                            options.Categories[j] = options.Categories[j].Trim();
                        }
                    }
                }
                else if (arg == "-q" || arg == "--quiet")
                {
                    options.Verbose = false;
                }
                else if (arg == "--json")
                {
                    options.ExportJson = true;
                }
                else if (arg == "--no-csv")
                {
                    options.ExportCsv = false;
                }
                else if (arg == "--csv-only")
                {
                    options.ExportCsv = true;
                    options.ExportJson = false;
                }
            }

            return options;
        }

        private static void ShowHelp()
        {
            Console.WriteLine(@"
USAGE:
    AzureDevOpsInventory.exe [OPTIONS]

OPTIONS:
    -h, --help              Show this help message
    -c, --categories LIST   Comma-separated list of categories to inventory
                            Options: all, core, work_items, boards, repos,
                                     pipelines, artifacts, test, security,
                                     extensions, infrastructure
                            Default: all
    -q, --quiet             Suppress verbose output
    --json                  Also export inventory to JSON file
    --no-csv                Don't export CSV files (only JSON if --json is specified)
    --csv-only              Export only CSV files (default)

EXAMPLES:
    # Full inventory with CSV export (default)
    AzureDevOpsInventory.exe

    # Inventory specific categories
    AzureDevOpsInventory.exe --categories core,repos,pipelines

    # Export to both JSON and CSV
    AzureDevOpsInventory.exe --json

    # Quiet mode with JSON only
    AzureDevOpsInventory.exe --quiet --json --no-csv

CONFIGURATION:
    Configure the following settings in App.config:
    - AZDO_SERVER_URL: Azure DevOps Server URL
    - AZDO_COLLECTION: Collection name (default: DefaultCollection)
    - AZDO_PAT: Personal Access Token (required)
    - AZDO_VERIFY_SSL: Verify SSL certificates (default: True)
    - OUTPUT_DIR: Output directory for reports (default: ./inventarios)

CATEGORIES:
    all            - All categories (default)
    core           - Team Projects, Teams, Process Templates
    work_items     - Work Item Types, Fields, States, Areas, Iterations, Queries
    boards         - Kanban Boards, Backlogs, Delivery Plans, Dashboards
    repos          - Git Repositories, Branches, Branch Policies, Pull Requests
    pipelines      - Build Pipelines, Release Pipelines, Variables, Service Connections
    artifacts      - Artifact Feeds, Packages
    test           - Test Plans, Test Suites, Test Cases
    security       - Security Groups, Users, Permissions
    extensions     - Marketplace Extensions, Service Hooks
    infrastructure - Agent Pools, Self-hosted Agents
");
        }
    }

    internal class CommandLineOptions
    {
        public List<string> Categories { get; set; }
        public bool Verbose { get; set; }
        public bool ExportJson { get; set; }
        public bool ExportCsv { get; set; }
        public bool ShowHelp { get; set; }
    }
}
