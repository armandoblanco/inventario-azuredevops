using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using Newtonsoft.Json.Linq;

namespace AzureDevOpsInventory
{
    /// <summary>
    /// CSV Exporter Module for Azure DevOps Inventory
    /// Creates timestamped folders with organized CSV files
    /// Compatible with .NET Framework 4.0
    /// </summary>
    public class CsvExporter
    {
        private readonly string _baseOutputDir;
        private readonly string _timestamp;
        private readonly string _outputDir;

        public string OutputDirectory
        {
            get { return _outputDir; }
        }

        public CsvExporter(string baseOutputDir)
        {
            _baseOutputDir = baseOutputDir;
            _timestamp = DateTime.Now.ToString("yyyyMMdd_HHmmss");
            _outputDir = Path.Combine(baseOutputDir, string.Format("inventory_{0}", _timestamp));
        }

        public void CreateDirectoryStructure()
        {
            var directories = new string[]
            {
                _outputDir,
                Path.Combine(_outputDir, "01_projects"),
                Path.Combine(_outputDir, "02_work_items"),
                Path.Combine(_outputDir, "03_boards"),
                Path.Combine(_outputDir, "04_repositories"),
                Path.Combine(_outputDir, "05_pipelines"),
                Path.Combine(_outputDir, "06_artifacts"),
                Path.Combine(_outputDir, "07_test"),
                Path.Combine(_outputDir, "08_security"),
                Path.Combine(_outputDir, "09_infrastructure"),
                Path.Combine(_outputDir, "10_extensions")
            };

            foreach (var directory in directories)
            {
                Directory.CreateDirectory(directory);
            }

            Console.WriteLine(string.Format("✅ Directory structure created: {0}", _outputDir));
        }

        public void WriteCsv(string filePath, List<Dictionary<string, string>> data, List<string> headers)
        {
            if (data == null || data.Count == 0)
            {
                // Create empty file with headers
                if (headers != null && headers.Count > 0)
                {
                    using (var writer = new StreamWriter(filePath, false, Encoding.UTF8))
                    {
                        writer.WriteLine(string.Join(",", headers.Select(new Func<string, string>(EscapeCsvValue)).ToArray()));
                    }
                }
                return;
            }

            // Infer headers if not provided
            if (headers == null || headers.Count == 0)
            {
                headers = data[0].Keys.ToList();
            }

            using (var writer = new StreamWriter(filePath, false, Encoding.UTF8))
            {
                // Write BOM for Excel UTF-8 compatibility
                writer.Write('\ufeff');
                
                // Write headers
                writer.WriteLine(string.Join(",", headers.Select(new Func<string, string>(EscapeCsvValue)).ToArray()));

                // Write data rows
                foreach (var row in data)
                {
                    var values = headers.Select(delegate(string h)
                    {
                        return row.ContainsKey(h) ? EscapeCsvValue(row[h]) : "";
                    }).ToArray();
                    writer.WriteLine(string.Join(",", values));
                }
            }
        }

        private string EscapeCsvValue(string value)
        {
            if (string.IsNullOrEmpty(value))
                return "";

            // If contains comma, quote, or newline, wrap in quotes and escape internal quotes
            if (value.Contains(",") || value.Contains("\"") || value.Contains("\n") || value.Contains("\r"))
            {
                return "\"" + value.Replace("\"", "\"\"") + "\"";
            }

            return value;
        }

        public void ExportProjectsSummary(JObject inventoryData)
        {
            var projects = inventoryData["inventory"]["projects"]["items"] as JArray;
            if (projects == null)
                return;

            var summaryData = new List<Dictionary<string, string>>();

            foreach (var project in projects)
            {
                var row = new Dictionary<string, string>();
                row["Project_ID"] = project["id"] != null ? project["id"].ToString() : "";
                row["Project_Name"] = project["name"] != null ? project["name"].ToString() : "";
                row["Description"] = project["description"] != null ? project["description"].ToString() : "";
                row["State"] = project["state"] != null ? project["state"].ToString() : "";
                row["Teams_Count"] = project["teams"] != null && project["teams"]["count"] != null ? project["teams"]["count"].ToString() : "0";
                row["WIT_Types_Count"] = project["work_items"] != null && project["work_items"]["work_item_types"] != null && project["work_items"]["work_item_types"]["count"] != null ? project["work_items"]["work_item_types"]["count"].ToString() : "0";
                row["Fields_Count"] = project["work_items"] != null && project["work_items"]["fields"] != null && project["work_items"]["fields"]["count"] != null ? project["work_items"]["fields"]["count"].ToString() : "0";
                row["Queries_Count"] = project["work_items"] != null && project["work_items"]["queries"] != null && project["work_items"]["queries"]["count"] != null ? project["work_items"]["queries"]["count"].ToString() : "0";
                row["Repositories_Count"] = project["repositories"] != null && project["repositories"]["repositories"] != null && project["repositories"]["repositories"]["count"] != null ? project["repositories"]["repositories"]["count"].ToString() : "0";
                row["Build_Pipelines_Count"] = project["pipelines"] != null && project["pipelines"]["build_pipelines"] != null && project["pipelines"]["build_pipelines"]["count"] != null ? project["pipelines"]["build_pipelines"]["count"].ToString() : "0";
                row["Release_Pipelines_Count"] = project["pipelines"] != null && project["pipelines"]["release_pipelines"] != null && project["pipelines"]["release_pipelines"]["count"] != null ? project["pipelines"]["release_pipelines"]["count"].ToString() : "0";
                row["Test_Plans_Count"] = project["test"] != null && project["test"]["test_plans"] != null && project["test"]["test_plans"]["count"] != null ? project["test"]["test_plans"]["count"].ToString() : "0";

                summaryData.Add(row);
            }

            var filePath = Path.Combine(_outputDir, "01_projects", "projects_summary.csv");
            WriteCsv(filePath, summaryData, null);
            Console.WriteLine(string.Format("✅ Exported: projects_summary.csv ({0} items)", summaryData.Count));
        }

        public void ExportTeams(JObject inventoryData)
        {
            var projects = inventoryData["inventory"]["projects"]["items"] as JArray;
            if (projects == null)
                return;

            var teamsData = new List<Dictionary<string, string>>();

            foreach (var project in projects)
            {
                var projectName = project["name"] != null ? project["name"].ToString() : "";
                var teams = project["teams"] != null ? project["teams"]["items"] as JArray : null;

                if (teams != null)
                {
                    foreach (var team in teams)
                    {
                        var row = new Dictionary<string, string>();
                        row["Project"] = projectName;
                        row["Team_ID"] = team["id"] != null ? team["id"].ToString() : "";
                        row["Team_Name"] = team["name"] != null ? team["name"].ToString() : "";
                        row["Description"] = team["description"] != null ? team["description"].ToString() : "";
                        row["URL"] = team["url"] != null ? team["url"].ToString() : "";

                        teamsData.Add(row);
                    }
                }
            }

            var filePath = Path.Combine(_outputDir, "01_projects", "teams.csv");
            WriteCsv(filePath, teamsData, null);
            Console.WriteLine(string.Format("✅ Exported: teams.csv ({0} items)", teamsData.Count));
        }

        public void ExportWorkItemTypes(JObject inventoryData)
        {
            var projects = inventoryData["inventory"]["projects"]["items"] as JArray;
            if (projects == null)
                return;

            var witData = new List<Dictionary<string, string>>();

            foreach (var project in projects)
            {
                var projectName = project["name"] != null ? project["name"].ToString() : "";
                var witTypes = project["work_items"] != null && project["work_items"]["work_item_types"] != null 
                    ? project["work_items"]["work_item_types"]["items"] as JArray 
                    : null;

                if (witTypes != null)
                {
                    foreach (var wit in witTypes)
                    {
                        var row = new Dictionary<string, string>();
                        row["Project"] = projectName;
                        row["Name"] = wit["name"] != null ? wit["name"].ToString() : "";
                        row["Reference_Name"] = wit["referenceName"] != null ? wit["referenceName"].ToString() : "";
                        row["Description"] = wit["description"] != null ? wit["description"].ToString() : "";
                        row["Color"] = wit["color"] != null ? wit["color"].ToString() : "";
                        row["Icon"] = wit["icon"] != null ? wit["icon"].ToString() : "";

                        witData.Add(row);
                    }
                }
            }

            var filePath = Path.Combine(_outputDir, "02_work_items", "work_item_types.csv");
            WriteCsv(filePath, witData, null);
            Console.WriteLine(string.Format("✅ Exported: work_item_types.csv ({0} items)", witData.Count));
        }

        public void ExportRepositories(JObject inventoryData)
        {
            var projects = inventoryData["inventory"]["projects"]["items"] as JArray;
            if (projects == null)
                return;

            var repoData = new List<Dictionary<string, string>>();

            foreach (var project in projects)
            {
                var projectName = project["name"] != null ? project["name"].ToString() : "";
                var repos = project["repositories"] != null && project["repositories"]["repositories"] != null 
                    ? project["repositories"]["repositories"]["items"] as JArray 
                    : null;

                if (repos != null)
                {
                    foreach (var repo in repos)
                    {
                        var row = new Dictionary<string, string>();
                        row["Project"] = projectName;
                        row["Repository_ID"] = repo["id"] != null ? repo["id"].ToString() : "";
                        row["Repository_Name"] = repo["name"] != null ? repo["name"].ToString() : "";
                        row["Default_Branch"] = repo["defaultBranch"] != null ? repo["defaultBranch"].ToString() : "";
                        row["Size"] = repo["size"] != null ? repo["size"].ToString() : "";
                        row["Branches_Count"] = repo["branches_count"] != null ? repo["branches_count"].ToString() : "0";
                        row["Pull_Requests_Count"] = repo["pull_requests_count"] != null ? repo["pull_requests_count"].ToString() : "0";
                        row["Remote_URL"] = repo["remoteUrl"] != null ? repo["remoteUrl"].ToString() : "";
                        row["Web_URL"] = repo["webUrl"] != null ? repo["webUrl"].ToString() : "";

                        repoData.Add(row);
                    }
                }
            }

            var filePath = Path.Combine(_outputDir, "04_repositories", "repositories.csv");
            WriteCsv(filePath, repoData, null);
            Console.WriteLine(string.Format("✅ Exported: repositories.csv ({0} items)", repoData.Count));
        }

        public void ExportBuildPipelines(JObject inventoryData)
        {
            var projects = inventoryData["inventory"]["projects"]["items"] as JArray;
            if (projects == null)
                return;

            var pipelineData = new List<Dictionary<string, string>>();

            foreach (var project in projects)
            {
                var projectName = project["name"] != null ? project["name"].ToString() : "";
                var pipelines = project["pipelines"] != null && project["pipelines"]["build_pipelines"] != null 
                    ? project["pipelines"]["build_pipelines"]["items"] as JArray 
                    : null;

                if (pipelines != null)
                {
                    foreach (var pipeline in pipelines)
                    {
                        var row = new Dictionary<string, string>();
                        row["Project"] = projectName;
                        row["Pipeline_ID"] = pipeline["id"] != null ? pipeline["id"].ToString() : "";
                        row["Pipeline_Name"] = pipeline["name"] != null ? pipeline["name"].ToString() : "";
                        row["Type"] = pipeline["type"] != null ? pipeline["type"].ToString() : "";
                        row["Path"] = pipeline["path"] != null ? pipeline["path"].ToString() : "";
                        row["Repository_Name"] = pipeline["repository"] != null && pipeline["repository"]["name"] != null ? pipeline["repository"]["name"].ToString() : "";
                        row["Repository_Type"] = pipeline["repository"] != null && pipeline["repository"]["type"] != null ? pipeline["repository"]["type"].ToString() : "";
                        row["Queue_Status"] = pipeline["queueStatus"] != null ? pipeline["queueStatus"].ToString() : "";
                        row["Revision"] = pipeline["revision"] != null ? pipeline["revision"].ToString() : "";

                        pipelineData.Add(row);
                    }
                }
            }

            var filePath = Path.Combine(_outputDir, "05_pipelines", "build_pipelines.csv");
            WriteCsv(filePath, pipelineData, null);
            Console.WriteLine(string.Format("✅ Exported: build_pipelines.csv ({0} items)", pipelineData.Count));
        }

        public void ExportAllReports(JObject inventoryData)
        {
            Console.WriteLine("\n" + new string('=', 70));
            Console.WriteLine("📊 EXPORTING CSV REPORTS");
            Console.WriteLine(new string('=', 70));

            ExportProjectsSummary(inventoryData);
            ExportTeams(inventoryData);
            ExportWorkItemTypes(inventoryData);
            ExportRepositories(inventoryData);
            ExportBuildPipelines(inventoryData);

            Console.WriteLine("\n✅ All CSV reports exported successfully!");
            Console.WriteLine(string.Format("📁 Output directory: {0}", _outputDir));
        }
    }
}
