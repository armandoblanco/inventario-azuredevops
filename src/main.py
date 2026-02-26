"""
Azure DevOps Server 2022 API Client
Provides methods to interact with Azure DevOps Server REST APIs
"""

import requests
from requests.auth import HTTPBasicAuth
import urllib3

# Disable SSL warnings for self-signed certificates
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)


class AzureDevOpsServer2022Inventory:
    """
    Client for Azure DevOps Server 2022 REST API
    Supports authentication, pagination, and comprehensive resource inventory
    """
    
    def __init__(self, server_url, pat_token, collection='DefaultCollection', verify_ssl=True):
        """
        Initialize Azure DevOps Server connection
        
        Args:
            server_url: Server URL (e.g., https://azuredevops.company.com/tfs)
            pat_token: Personal Access Token for authentication
            collection: Collection name (default: DefaultCollection)
            verify_ssl: Verify SSL certificates (default: True)
        """
        self.server_url = server_url.rstrip('/')
        self.collection = collection
        self.base_url = f"{self.server_url}/{self.collection}"
        self.auth = HTTPBasicAuth('', pat_token)  # PAT uses empty username
        self.headers = {
            'Content-Type': 'application/json',
            'Accept': 'application/json'
        }
        self.verify_ssl = verify_ssl
        self.api_version = '7.0'
        
    def _make_request(self, endpoint, api_version=None, use_vsrm=False):
        """
        Make HTTP GET request to Azure DevOps API
        
        Args:
            endpoint: API endpoint (without base URL)
            api_version: API version to use (default: self.api_version)
            use_vsrm: Use vsrm subdomain for Release Management (default: False)
            
        Returns:
            dict: JSON response or error dict
        """
        api_ver = api_version or self.api_version
        url = f"{self.base_url}/{endpoint}?api-version={api_ver}"
        
        try:
            response = requests.get(
                url,
                auth=self.auth,
                headers=self.headers,
                verify=self.verify_ssl,
                timeout=30
            )
            response.raise_for_status()
            return response.json()
        except requests.exceptions.HTTPError as e:
            return {'error': str(e), 'value': [], 'count': 0}
        except Exception as e:
            return {'error': str(e), 'value': [], 'count': 0}
    
    # ==================== PROJECTS ====================
    
    def get_projects(self):
        """Get all team projects"""
        return self._make_request('_apis/projects', api_version='7.0')
    
    def get_project_properties(self, project_id):
        """Get project properties"""
        return self._make_request(f'_apis/projects/{project_id}/properties', api_version='7.0')
    
    # ==================== TEAMS ====================
    
    def get_teams(self, project):
        """Get all teams in a project"""
        return self._make_request(f'_apis/projects/{project}/teams', api_version='7.0')
    
    # ==================== PROCESS TEMPLATES ====================
    
    def get_processes(self):
        """Get process templates"""
        return self._make_request('_apis/work/processes', api_version='7.0')
    
    def get_project_process(self, project):
        """Get the process used by a project"""
        return self._make_request(f'{project}/_apis/work/processadmin', api_version='7.0-preview.1')
    
    # ==================== WORK ITEMS ====================
    
    def get_work_item_types(self, project):
        """Get work item types for a project"""
        return self._make_request(f'{project}/_apis/wit/workitemtypes', api_version='7.0')
    
    def get_work_item_type_details(self, project, wit_name):
        """Get detailed information about a work item type including layout"""
        return self._make_request(f'{project}/_apis/wit/workitemtypes/{wit_name}', api_version='7.0')
    
    def get_work_item_fields(self, project):
        """Get all work item fields (custom and system)"""
        return self._make_request(f'{project}/_apis/wit/fields', api_version='7.0')
    
    def get_work_item_states(self, project, wit_name):
        """Get states for a work item type"""
        return self._make_request(f'{project}/_apis/wit/workitemtypes/{wit_name}/states', api_version='7.0')
    
    def get_work_item_rules(self, project):
        """Get work item rules"""
        return self._make_request(f'{project}/_apis/wit/workitemtyperules', api_version='7.0-preview.1')
    
    # ==================== CLASSIFICATION NODES ====================
    
    def get_area_paths(self, project, depth=10):
        """Get area paths for a project"""
        return self._make_request(f'{project}/_apis/wit/classificationnodes/areas?$depth={depth}', api_version='7.0')
    
    def get_iteration_paths(self, project, depth=10):
        """Get iteration paths for a project"""
        return self._make_request(f'{project}/_apis/wit/classificationnodes/iterations?$depth={depth}', api_version='7.0')
    
    # ==================== QUERIES ====================
    
    def get_queries(self, project, depth=2):
        """Get shared and personal queries"""
        return self._make_request(f'{project}/_apis/wit/queries?$depth={depth}&$expand=all', api_version='7.0')
    
    # ==================== BOARDS & BACKLOGS ====================
    
    def get_boards(self, project, team):
        """Get Kanban boards for a team"""
        return self._make_request(f'{project}/{team}/_apis/work/boards', api_version='7.0')
    
    def get_board_columns(self, project, team, board_id):
        """Get columns for a board"""
        return self._make_request(f'{project}/{team}/_apis/work/boards/{board_id}/columns', api_version='7.0')
    
    def get_backlogs(self, project, team):
        """Get backlogs for a team"""
        return self._make_request(f'{project}/{team}/_apis/work/backlogs', api_version='7.0')
    
    def get_delivery_plans(self, project):
        """Get delivery plans"""
        return self._make_request(f'{project}/_apis/work/plans', api_version='7.0-preview.1')
    
    # ==================== REPOSITORIES ====================
    
    def get_repositories(self, project):
        """Get Git repositories in a project"""
        return self._make_request(f'{project}/_apis/git/repositories', api_version='7.0')
    
    def get_branches(self, project, repo_id):
        """Get branches for a repository"""
        return self._make_request(f'{project}/_apis/git/repositories/{repo_id}/refs?filter=heads/', api_version='7.0')
    
    def get_branch_policies(self, project):
        """Get branch policies for a project"""
        return self._make_request(f'{project}/_apis/policy/configurations', api_version='7.0')
    
    def get_pull_requests(self, project, repo_id, status='all'):
        """Get pull requests for a repository"""
        return self._make_request(
            f'{project}/_apis/git/repositories/{repo_id}/pullrequests?searchCriteria.status={status}',
            api_version='7.0'
        )
    
    # ==================== BUILD PIPELINES ====================
    
    def get_build_definitions(self, project):
        """Get build pipeline definitions (Classic and YAML)"""
        return self._make_request(f'{project}/_apis/build/definitions', api_version='7.0')
    
    def get_build_definition_details(self, project, definition_id):
        """Get detailed information about a build pipeline"""
        return self._make_request(f'{project}/_apis/build/definitions/{definition_id}', api_version='7.0')
    
    def get_builds(self, project, top=100):
        """Get recent builds"""
        return self._make_request(f'{project}/_apis/build/builds?$top={top}', api_version='7.0')
    
    # ==================== RELEASE PIPELINES ====================
    
    def get_release_definitions(self, project):
        """Get release pipeline definitions (Classic)"""
        return self._make_request(f'{project}/_apis/release/definitions', api_version='7.0', use_vsrm=True)
    
    def get_release_definition_details(self, project, definition_id):
        """Get detailed information about a release pipeline"""
        return self._make_request(f'{project}/_apis/release/definitions/{definition_id}', api_version='7.0', use_vsrm=True)
    
    def get_releases(self, project, top=50):
        """Get recent releases"""
        return self._make_request(f'{project}/_apis/release/releases?$top={top}', api_version='7.0', use_vsrm=True)
    
    # ==================== VARIABLES & LIBRARY ====================
    
    def get_variable_groups(self, project):
        """Get variable groups"""
        return self._make_request(f'{project}/_apis/distributedtask/variablegroups', api_version='7.0-preview.2')
    
    def get_secure_files(self, project):
        """Get secure files"""
        return self._make_request(f'{project}/_apis/distributedtask/securefiles', api_version='7.0-preview.1')
    
    # ==================== SERVICE CONNECTIONS ====================
    
    def get_service_endpoints(self, project):
        """Get service connections/endpoints"""
        return self._make_request(f'{project}/_apis/serviceendpoint/endpoints', api_version='7.0')
    
    # ==================== AGENTS ====================
    
    def get_agent_pools(self):
        """Get agent pools"""
        return self._make_request('_apis/distributedtask/pools', api_version='7.0')
    
    def get_agents(self, pool_id):
        """Get agents in a pool"""
        return self._make_request(f'_apis/distributedtask/pools/{pool_id}/agents', api_version='7.0')
    
    # ==================== ENVIRONMENTS ====================
    
    def get_environments(self, project):
        """Get environments for YAML pipelines"""
        return self._make_request(f'{project}/_apis/distributedtask/environments', api_version='7.0-preview.1')
    
    def get_deployment_groups(self, project):
        """Get deployment groups"""
        return self._make_request(f'{project}/_apis/distributedtask/deploymentgroups', api_version='7.0')
    
    # ==================== ARTIFACTS ====================
    
    def get_feeds(self, project=None):
        """Get artifact feeds (organization or project level)"""
        if project:
            return self._make_request(f'{project}/_apis/packaging/feeds', api_version='7.0-preview.1')
        else:
            return self._make_request('_apis/packaging/feeds', api_version='7.0-preview.1')
    
    def get_feed_packages(self, feed_id, project=None):
        """Get packages in a feed"""
        if project:
            return self._make_request(f'{project}/_apis/packaging/feeds/{feed_id}/packages', api_version='7.0-preview.1')
        else:
            return self._make_request(f'_apis/packaging/feeds/{feed_id}/packages', api_version='7.0-preview.1')
    
    # ==================== TEST MANAGEMENT ====================
    
    def get_test_plans(self, project):
        """Get test plans"""
        return self._make_request(f'{project}/_apis/test/plans', api_version='7.0')
    
    def get_test_suites(self, project, plan_id):
        """Get test suites for a test plan"""
        return self._make_request(f'{project}/_apis/test/plans/{plan_id}/suites', api_version='7.0')
    
    def get_test_cases(self, project, suite_id):
        """Get test cases for a test suite"""
        return self._make_request(f'{project}/_apis/test/suites/{suite_id}/testcases', api_version='7.0')
    
    def get_test_runs(self, project):
        """Get test runs"""
        return self._make_request(f'{project}/_apis/test/runs', api_version='7.0')
    
    # ==================== EXTENSIONS ====================
    
    def get_installed_extensions(self):
        """Get installed marketplace extensions"""
        return self._make_request('_apis/extensionmanagement/installedextensions', api_version='7.0-preview.1')
    
    # ==================== SERVICE HOOKS ====================
    
    def get_service_hooks(self, project):
        """Get service hook subscriptions"""
        return self._make_request(f'{project}/_apis/hooks/subscriptions', api_version='7.0')
    
    # ==================== SECURITY ====================
    
    def get_security_groups(self, scope_descriptor=None):
        """Get security groups"""
        endpoint = '_apis/graph/groups'
        if scope_descriptor:
            endpoint += f'?scopeDescriptor={scope_descriptor}'
        return self._make_request(endpoint, api_version='7.0-preview.1')
    
    def get_users(self):
        """Get users in the collection"""
        return self._make_request('_apis/graph/users', api_version='7.0-preview.1')
    
    def get_group_members(self, group_descriptor):
        """Get members of a security group"""
        return self._make_request(f'_apis/graph/groups/{group_descriptor}/members', api_version='7.0-preview.1')
    
    # ==================== DASHBOARDS ====================
    
    def get_dashboards(self, project, team):
        """Get dashboards for a team"""
        return self._make_request(f'{project}/{team}/_apis/dashboard/dashboards', api_version='7.0')
    
    def get_dashboard_widgets(self, project, team, dashboard_id):
        """Get widgets for a dashboard"""
        return self._make_request(f'{project}/{team}/_apis/dashboard/dashboards/{dashboard_id}/widgets', api_version='7.0')
    
    # ==================== WIKI ====================
    
    def get_wikis(self, project):
        """Get wikis for a project"""
        return self._make_request(f'{project}/_apis/wiki/wikis', api_version='7.0')
