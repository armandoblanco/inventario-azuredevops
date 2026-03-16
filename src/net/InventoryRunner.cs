using System;
using System.Collections.Generic;
using System.Linq;
using Newtonsoft.Json.Linq;

namespace AzureDevOpsInventory
{
    /// <summary>
    /// Orchestrates inventory execution across selected categories
    /// Compatible with .NET Framework 4.0
    /// </summary>
    public class InventoryRunner
    {
        private readonly AzureDevOpsClient _client;
        private readonly List<string> _categories;
        private readonly bool _verbose;
        private JObject _results;

        public InventoryRunner(AzureDevOpsClient client, List<string> categoriesToRun, bool verbose)
        {
            _client = client;
            _categories = categoriesToRun;
            _verbose = verbose;
            
            _results = new JObject();
            _results["metadata"] = new JObject();
            _results["metadata"]["timestamp"] = DateTime.Now.ToString("O");
            _results["metadata"]["server"] = Config.ServerUrl;
            _results["metadata"]["collection"] = Config.Collection;
            _results["metadata"]["categories_included"] = new JArray(categoriesToRun.ToArray());
            _results["inventory"] = new JObject();
        }

        private void PrintStatus(string message, string level)
        {
            if (!_verbose)
                return;

            var icon = "ℹ️ ";
            if (level == "success") icon = "✅";
            else if (level == "warning") icon = "⚠️ ";
            else if (level == "error") icon = "❌";
            else if (level == "processing") icon = "🔄";

            Console.WriteLine(string.Format("{0} {1}", icon, message));
        }

        private bool ShouldInclude(string category)
        {
            return _categories.Contains(category) || _categories.Contains("all");
        }

        public JObject RunInventory()
        {
            Console.WriteLine("\n" + new string('=', 70));
            Console.WriteLine("🔍 AZURE DEVOPS SERVER 2022 - INVENTORY");
            Console.WriteLine(new string('=', 70));

            // Get projects (always needed as foundation)
            PrintStatus("Getting project list...", "processing");
            var projects = _client.GetProjects();

            if (projects["error"] != null)
            {
                PrintStatus(string.Format("Connection error: {0}", projects["error"]), "error");
                return null;
            }

            var projectList = projects["value"] as JArray ?? new JArray();
            PrintStatus(string.Format("Projects found: {0}", projectList.Count), "success");

            _results["inventory"]["projects"] = new JObject();
            _results["inventory"]["projects"]["count"] = projectList.Count;
            _results["inventory"]["projects"]["items"] = new JArray();

            var projectItems = _results["inventory"]["projects"]["items"] as JArray;

            // Process each project
            for (int idx = 0; idx < projectList.Count; idx++)
            {
                var project = projectList[idx];
                var projectName = project["name"].ToString();
                var projectId = project["id"].ToString();

                Console.WriteLine(string.Format("\n{0}", new string('─', 70)));
                Console.WriteLine(string.Format("📁 [{0}/{1}] Project: {2}", idx + 1, projectList.Count, projectName));
                Console.WriteLine(new string('─', 70));

                var projectData = new JObject();
                projectData["id"] = projectId;
                projectData["name"] = projectName;
                projectData["description"] = project["description"] != null ? project["description"].ToString() : "";
                projectData["state"] = project["state"] != null ? project["state"].ToString() : "";
                projectData["url"] = project["url"] != null ? project["url"].ToString() : "";

                // Core & Projects
                if (ShouldInclude("core"))
                {
                    projectData["teams"] = InventoryTeams(projectName);
                }

                // Work Items
                if (ShouldInclude("work_items"))
                {
                    projectData["work_items"] = InventoryWorkItems(projectName);
                }

                // Boards
                if (ShouldInclude("boards"))
                {
                    projectData["boards"] = InventoryBoards(projectName);
                }

                // Repositories
                if (ShouldInclude("repos"))
                {
                    projectData["repositories"] = InventoryRepositories(projectName);
                }

                // Pipelines
                if (ShouldInclude("pipelines"))
                {
                    projectData["pipelines"] = InventoryPipelines(projectName);
                }

                // Artifacts
                if (ShouldInclude("artifacts"))
                {
                    projectData["artifacts"] = InventoryArtifacts(projectName);
                }

                // Test
                if (ShouldInclude("test"))
                {
                    projectData["test"] = InventoryTest(projectName);
                }

                // Integrations
                if (ShouldInclude("extensions"))
                {
                    projectData["integrations"] = InventoryIntegrations(projectName);
                }

                projectItems.Add(projectData);
            }

            // Collection-level inventory
            Console.WriteLine(string.Format("\n{0}", new string('=', 70)));
            Console.WriteLine("🌐 Collection-Level Inventory");
            Console.WriteLine(new string('=', 70));

            if (ShouldInclude("infrastructure"))
            {
                _results["inventory"]["infrastructure"] = InventoryInfrastructure();
            }

            if (ShouldInclude("extensions"))
            {
                _results["inventory"]["extensions"] = InventoryExtensions();
            }

            if (ShouldInclude("security"))
            {
                _results["inventory"]["organization_security"] = InventoryOrgSecurity();
            }

            Console.WriteLine(string.Format("\n{0}", new string('=', 70)));
            PrintStatus("Inventory completed successfully!", "success");
            Console.WriteLine(string.Format("{0}\n", new string('=', 70)));

            return _results;
        }

        private JObject InventoryTeams(string project)
        {
            PrintStatus("  Getting teams...", "processing");
            var teams = _client.GetTeams(project);
            var count = teams["count"] != null ? (int)teams["count"] : 0;
            PrintStatus(string.Format("  Teams: {0}", count), "info");
            
            var result = new JObject();
            result["count"] = count;
            result["items"] = teams["value"] ?? new JArray();
            return result;
        }

        private JObject InventoryWorkItems(string project)
        {
            PrintStatus("  Getting Work Items...", "processing");
            var data = new JObject();

            // Work Item Types
            var witTypes = _client.GetWorkItemTypes(project);
            var witArray = witTypes["value"] as JArray ?? new JArray();
            data["work_item_types"] = new JObject();
            data["work_item_types"]["count"] = witArray.Count;
            data["work_item_types"]["items"] = witArray;

            // Fields
            var fields = _client.GetWorkItemFields(project);
            var fieldsCount = fields["count"] != null ? (int)fields["count"] : 0;
            data["fields"] = new JObject();
            data["fields"]["count"] = fieldsCount;
            data["fields"]["items"] = fields["value"] ?? new JArray();

            // Areas
            data["area_paths"] = _client.GetAreaPaths(project, 10);

            // Iterations
            data["iteration_paths"] = _client.GetIterationPaths(project, 10);

            // Queries
            var queries = _client.GetQueries(project, 2);
            var queriesCount = queries["count"] != null ? (int)queries["count"] : 0;
            data["queries"] = new JObject();
            data["queries"]["count"] = queriesCount;
            data["queries"]["items"] = queries["value"] ?? new JArray();

            PrintStatus(string.Format("    ├─ WIT Types: {0}", witArray.Count), "info");
            PrintStatus(string.Format("    ├─ Fields: {0}", fieldsCount), "info");
            PrintStatus(string.Format("    └─ Queries: {0}", queriesCount), "info");

            return data;
        }

        private JObject InventoryBoards(string project)
        {
            PrintStatus("  Getting Boards...", "processing");
            var data = new JObject();

            // Get teams first
            var teams = _client.GetTeams(project);
            var teamList = teams["value"] as JArray ?? new JArray();

            var allBoards = new JArray();
            var allBacklogs = new JArray();

            // Limit to first 5 teams to avoid overwhelming API
            var maxTeams = Math.Min(5, teamList.Count);
            for (int i = 0; i < maxTeams; i++)
            {
                var team = teamList[i];
                var teamName = team["name"] != null ? team["name"].ToString() : "";
                if (string.IsNullOrEmpty(teamName))
                    continue;

                // Boards
                var boards = _client.GetBoards(project, teamName);
                var boardArray = boards["value"] as JArray ?? new JArray();
                foreach (var board in boardArray)
                {
                    var boardObj = board as JObject;
                    if (boardObj != null)
                    {
                        boardObj["team"] = teamName;
                        allBoards.Add(boardObj);
                    }
                }

                // Backlogs
                var backlogs = _client.GetBacklogs(project, teamName);
                var backlogArray = backlogs["value"] as JArray ?? new JArray();
                foreach (var backlog in backlogArray)
                {
                    var backlogObj = backlog as JObject;
                    if (backlogObj != null)
                    {
                        backlogObj["team"] = teamName;
                        allBacklogs.Add(backlogObj);
                    }
                }
            }

            data["boards"] = new JObject();
            data["boards"]["count"] = allBoards.Count;
            data["boards"]["items"] = allBoards;

            data["backlogs"] = new JObject();
            data["backlogs"]["count"] = allBacklogs.Count;
            data["backlogs"]["items"] = allBacklogs;

            // Delivery Plans
            var plans = _client.GetDeliveryPlans(project);
            var plansCount = plans["count"] != null ? (int)plans["count"] : 0;
            data["delivery_plans"] = new JObject();
            data["delivery_plans"]["count"] = plansCount;
            data["delivery_plans"]["items"] = plans["value"] ?? new JArray();

            PrintStatus(string.Format("    ├─ Boards: {0}", allBoards.Count), "info");
            PrintStatus(string.Format("    ├─ Backlogs: {0}", allBacklogs.Count), "info");
            PrintStatus(string.Format("    └─ Delivery Plans: {0}", plansCount), "info");

            return data;
        }

        private JObject InventoryRepositories(string project)
        {
            PrintStatus("  Getting Repositories...", "processing");
            var data = new JObject();

            var repos = _client.GetRepositories(project);
            var repoList = repos["value"] as JArray ?? new JArray();

            var repoItems = new JArray();

            foreach (var repo in repoList)
            {
                var repoData = (JObject)((JToken)repo).DeepClone();
                var repoId = repo["id"] != null ? repo["id"].ToString() : "";

                if (!string.IsNullOrEmpty(repoId))
                {
                    // Branches
                    var branches = _client.GetBranches(project, repoId);
                    var branchArray = branches["value"] as JArray ?? new JArray();
                    repoData["branches_count"] = branchArray.Count;

                    // Pull Requests
                    var prs = _client.GetPullRequests(project, repoId, "all");
                    repoData["pull_requests_count"] = prs["count"] != null ? (int)prs["count"] : 0;
                }

                repoItems.Add(repoData);
            }

            data["repositories"] = new JObject();
            data["repositories"]["count"] = repoItems.Count;
            data["repositories"]["items"] = repoItems;

            // Branch Policies
            var policies = _client.GetBranchPolicies(project);
            var policiesCount = policies["count"] != null ? (int)policies["count"] : 0;
            data["branch_policies"] = new JObject();
            data["branch_policies"]["count"] = policiesCount;
            data["branch_policies"]["items"] = policies["value"] ?? new JArray();

            PrintStatus(string.Format("    ├─ Repositories: {0}", repoItems.Count), "info");
            PrintStatus(string.Format("    └─ Branch Policies: {0}", policiesCount), "info");

            return data;
        }

        private JObject InventoryPipelines(string project)
        {
            PrintStatus("  Getting Pipelines...", "processing");
            var data = new JObject();

            // Build Pipelines
            var buildDefs = _client.GetBuildDefinitions(project);
            var buildArray = buildDefs["value"] as JArray ?? new JArray();
            data["build_pipelines"] = new JObject();
            data["build_pipelines"]["count"] = buildArray.Count;
            data["build_pipelines"]["items"] = buildArray;

            // Release Pipelines
            var releaseDefs = _client.GetReleaseDefinitions(project);
            var releaseArray = releaseDefs["value"] as JArray ?? new JArray();
            data["release_pipelines"] = new JObject();
            data["release_pipelines"]["count"] = releaseArray.Count;
            data["release_pipelines"]["items"] = releaseArray;

            // Variable Groups
            var varGroups = _client.GetVariableGroups(project);
            var varGroupsCount = varGroups["count"] != null ? (int)varGroups["count"] : 0;
            data["variable_groups"] = new JObject();
            data["variable_groups"]["count"] = varGroupsCount;
            data["variable_groups"]["items"] = varGroups["value"] ?? new JArray();

            // Service Connections
            var serviceEndpoints = _client.GetServiceEndpoints(project);
            var serviceEndpointsArray = serviceEndpoints["value"] as JArray ?? new JArray();
            data["service_connections"] = new JObject();
            data["service_connections"]["count"] = serviceEndpointsArray.Count;
            data["service_connections"]["items"] = serviceEndpointsArray;

            PrintStatus(string.Format("    ├─ Build Pipelines: {0}", buildArray.Count), "info");
            PrintStatus(string.Format("    ├─ Release Pipelines: {0}", releaseArray.Count), "info");
            PrintStatus(string.Format("    ├─ Variable Groups: {0}", varGroupsCount), "info");
            PrintStatus(string.Format("    └─ Service Connections: {0}", serviceEndpointsArray.Count), "info");

            return data;
        }

        private JObject InventoryArtifacts(string project)
        {
            PrintStatus("  Getting Artifacts...", "processing");
            var data = new JObject();

            var feeds = _client.GetFeeds(project);
            var feedsCount = feeds["count"] != null ? (int)feeds["count"] : 0;
            data["feeds"] = new JObject();
            data["feeds"]["count"] = feedsCount;
            data["feeds"]["items"] = feeds["value"] ?? new JArray();

            PrintStatus(string.Format("    └─ Feeds: {0}", feedsCount), "info");

            return data;
        }

        private JObject InventoryTest(string project)
        {
            PrintStatus("  Getting Test Plans...", "processing");
            var data = new JObject();

            var testPlans = _client.GetTestPlans(project);
            var testPlansArray = testPlans["value"] as JArray ?? new JArray();
            data["test_plans"] = new JObject();
            data["test_plans"]["count"] = testPlansArray.Count;
            data["test_plans"]["items"] = testPlansArray;

            PrintStatus(string.Format("    └─ Test Plans: {0}", testPlansArray.Count), "info");

            return data;
        }

        private JObject InventoryIntegrations(string project)
        {
            PrintStatus("  Getting Service Hooks...", "processing");
            var data = new JObject();

            var hooks = _client.GetServiceHooks(project);
            var hooksCount = hooks["count"] != null ? (int)hooks["count"] : 0;
            data["service_hooks"] = new JObject();
            data["service_hooks"]["count"] = hooksCount;
            data["service_hooks"]["items"] = hooks["value"] ?? new JArray();

            PrintStatus(string.Format("    └─ Service Hooks: {0}", hooksCount), "info");

            return data;
        }

        private JObject InventoryInfrastructure()
        {
            PrintStatus("Getting Agent Pools...", "processing");
            var data = new JObject();

            var pools = _client.GetAgentPools();
            var poolsArray = pools["value"] as JArray ?? new JArray();
            data["agent_pools"] = new JObject();
            data["agent_pools"]["count"] = poolsArray.Count;
            data["agent_pools"]["items"] = poolsArray;

            PrintStatus(string.Format("  └─ Agent Pools: {0}", poolsArray.Count), "info");

            return data;
        }

        private JObject InventoryExtensions()
        {
            PrintStatus("Getting Installed Extensions...", "processing");
            var data = new JObject();

            var extensions = _client.GetInstalledExtensions();
            var extensionsArray = extensions["value"] as JArray ?? new JArray();
            data["installed_extensions"] = new JObject();
            data["installed_extensions"]["count"] = extensionsArray.Count;
            data["installed_extensions"]["items"] = extensionsArray;

            PrintStatus(string.Format("  └─ Extensions: {0}", extensionsArray.Count), "info");

            return data;
        }

        private JObject InventoryOrgSecurity()
        {
            PrintStatus("Getting Security Groups...", "processing");
            var data = new JObject();

            var groups = _client.GetSecurityGroups(null);
            var groupsCount = groups["count"] != null ? (int)groups["count"] : 0;
            data["security_groups"] = new JObject();
            data["security_groups"]["count"] = groupsCount;
            data["security_groups"]["items"] = groups["value"] ?? new JArray();

            var users = _client.GetUsers();
            var usersCount = users["count"] != null ? (int)users["count"] : 0;
            data["users"] = new JObject();
            data["users"]["count"] = usersCount;
            data["users"]["items"] = users["value"] ?? new JArray();

            PrintStatus(string.Format("  ├─ Security Groups: {0}", groupsCount), "info");
            PrintStatus(string.Format("  └─ Users: {0}", usersCount), "info");

            return data;
        }
    }
}
