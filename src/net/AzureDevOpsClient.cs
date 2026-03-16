using System;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using Newtonsoft.Json.Linq;

namespace AzureDevOpsInventory
{
    /// <summary>
    /// Azure DevOps Server 2022 API Client
    /// Provides methods to interact with Azure DevOps Server REST APIs
    /// Compatible with .NET Framework 4.0
    /// </summary>
    public class AzureDevOpsClient : IDisposable
    {
        private readonly string _serverUrl;
        private readonly string _collection;
        private readonly string _baseUrl;
        private readonly string _apiVersion;
        private readonly string _authorizationHeader;

        public AzureDevOpsClient(string serverUrl, string patToken, string collection, bool verifySsl, string apiVersion)
        {
            _serverUrl = serverUrl.TrimEnd('/');
            _collection = collection;
            _baseUrl = string.Format("{0}/{1}", _serverUrl, _collection);
            _apiVersion = apiVersion;

            // Configure PAT authentication (empty username)
            var credentials = Convert.ToBase64String(Encoding.ASCII.GetBytes(string.Format(":{0}", patToken)));
            _authorizationHeader = string.Format("Basic {0}", credentials);

            // Disable SSL verification if requested
            if (!verifySsl)
            {
                ServicePointManager.ServerCertificateValidationCallback = AcceptAllCertificates;
            }

            // Enable TLS 1.2 and older versions
            ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072 |  // TLS 1.2
                                                   (SecurityProtocolType)768 |   // TLS 1.1
                                                   (SecurityProtocolType)192;    // TLS 1.0
        }

        private static bool AcceptAllCertificates(object sender, X509Certificate certificate, X509Chain chain, SslPolicyErrors sslPolicyErrors)
        {
            return true;
        }

        private JObject MakeRequest(string endpoint, string apiVersion)
        {
            var apiVer = apiVersion ?? _apiVersion;
            var url = string.Format("{0}/{1}?api-version={2}", _baseUrl, endpoint, apiVer);

            try
            {
                var request = (HttpWebRequest)WebRequest.Create(url);
                request.Method = "GET";
                request.Headers.Add("Authorization", _authorizationHeader);
                request.Accept = "application/json";
                request.Timeout = 30000; // 30 seconds

                using (var response = (HttpWebResponse)request.GetResponse())
                using (var stream = response.GetResponseStream())
                using (var reader = new StreamReader(stream))
                {
                    var content = reader.ReadToEnd();
                    return JObject.Parse(content);
                }
            }
            catch (WebException)
            {
                return new JObject
                {
                    {"error", "Request failed"},
                    {"value", new JArray()},
                    {"count", 0}
                };
            }
            catch (Exception)
            {
                return new JObject
                {
                    {"error", "Unexpected error"},
                    {"value", new JArray()},
                    {"count", 0}
                };
            }
        }

        // ==================== PROJECTS ====================
        public JObject GetProjects()
        {
            return MakeRequest("_apis/projects", "7.0");
        }

        public JObject GetProjectProperties(string projectId)
        {
            return MakeRequest(string.Format("_apis/projects/{0}/properties", projectId), "7.0");
        }

        // ==================== TEAMS ====================
        public JObject GetTeams(string project)
        {
            return MakeRequest(string.Format("_apis/projects/{0}/teams", project), "7.0");
        }

        // ==================== WORK ITEMS ====================
        public JObject GetWorkItemTypes(string project)
        {
            return MakeRequest(string.Format("{0}/_apis/wit/workitemtypes", project), "7.0");
        }

        public JObject GetWorkItemFields(string project)
        {
            return MakeRequest(string.Format("{0}/_apis/wit/fields", project), "7.0");
        }

        public JObject GetAreaPaths(string project, int depth)
        {
            return MakeRequest(string.Format("{0}/_apis/wit/classificationnodes/areas?$depth={1}", project, depth), "7.0");
        }

        public JObject GetIterationPaths(string project, int depth)
        {
            return MakeRequest(string.Format("{0}/_apis/wit/classificationnodes/iterations?$depth={1}", project, depth), "7.0");
        }

        public JObject GetQueries(string project, int depth)
        {
            return MakeRequest(string.Format("{0}/_apis/wit/queries?$depth={1}&$expand=all", project, depth), "7.0");
        }

        // ==================== BOARDS & BACKLOGS ====================
        public JObject GetBoards(string project, string team)
        {
            return MakeRequest(string.Format("{0}/{1}/_apis/work/boards", project, team), "7.0");
        }

        public JObject GetBacklogs(string project, string team)
        {
            return MakeRequest(string.Format("{0}/{1}/_apis/work/backlogs", project, team), "7.0");
        }

        public JObject GetDeliveryPlans(string project)
        {
            return MakeRequest(string.Format("{0}/_apis/work/plans", project), "7.0-preview.1");
        }

        // ==================== REPOSITORIES ====================
        public JObject GetRepositories(string project)
        {
            return MakeRequest(string.Format("{0}/_apis/git/repositories", project), "7.0");
        }

        public JObject GetBranches(string project, string repoId)
        {
            return MakeRequest(string.Format("{0}/_apis/git/repositories/{1}/refs?filter=heads/", project, repoId), "7.0");
        }

        public JObject GetBranchPolicies(string project)
        {
            return MakeRequest(string.Format("{0}/_apis/policy/configurations", project), "7.0");
        }

        public JObject GetPullRequests(string project, string repoId, string status)
        {
            return MakeRequest(string.Format("{0}/_apis/git/repositories/{1}/pullrequests?searchCriteria.status={2}", project, repoId, status), "7.0");
        }

        // ==================== BUILD PIPELINES ====================
        public JObject GetBuildDefinitions(string project)
        {
            return MakeRequest(string.Format("{0}/_apis/build/definitions", project), "7.0");
        }

        public JObject GetReleaseDefinitions(string project)
        {
            return MakeRequest(string.Format("{0}/_apis/release/definitions", project), "7.0");
        }

        public JObject GetVariableGroups(string project)
        {
            return MakeRequest(string.Format("{0}/_apis/distributedtask/variablegroups", project), "7.0-preview.2");
        }

        public JObject GetServiceEndpoints(string project)
        {
            return MakeRequest(string.Format("{0}/_apis/serviceendpoint/endpoints", project), "7.0");
        }

        // ==================== ARTIFACTS ====================
        public JObject GetFeeds(string project)
        {
            if (!string.IsNullOrEmpty(project))
            {
                return MakeRequest(string.Format("{0}/_apis/packaging/feeds", project), "7.0-preview.1");
            }
            return MakeRequest("_apis/packaging/feeds", "7.0-preview.1");
        }

        // ==================== TEST MANAGEMENT ====================
        public JObject GetTestPlans(string project)
        {
            return MakeRequest(string.Format("{0}/_apis/test/plans", project), "7.0");
        }

        // ==================== SERVICE HOOKS ====================
        public JObject GetServiceHooks(string project)
        {
            return MakeRequest(string.Format("{0}/_apis/hooks/subscriptions", project), "7.0");
        }

        // ==================== AGENTS ====================
        public JObject GetAgentPools()
        {
            return MakeRequest("_apis/distributedtask/pools", "7.0");
        }

        // ==================== EXTENSIONS ====================
        public JObject GetInstalledExtensions()
        {
            return MakeRequest("_apis/extensionmanagement/installedextensions", "7.0-preview.1");
        }

        // ==================== SECURITY ====================
        public JObject GetSecurityGroups(string scopeDescriptor)
        {
            var endpoint = "_apis/graph/groups";
            if (!string.IsNullOrEmpty(scopeDescriptor))
            {
                endpoint += string.Format("?scopeDescriptor={0}", scopeDescriptor);
            }
            return MakeRequest(endpoint, "7.0-preview.1");
        }

        public JObject GetUsers()
        {
            return MakeRequest("_apis/graph/users", "7.0-preview.1");
        }

        public void Dispose()
        {
            // Cleanup if needed
        }
    }
}
