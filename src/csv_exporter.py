"""
CSV Exporter Module for Azure DevOps Inventory
Creates timestamped folders with organized CSV files
"""

import os
import csv
from datetime import datetime
from pathlib import Path


class CSVExporter:
    """
    Exports Azure DevOps inventory data to CSV files
    Creates organized folder structure with timestamped directories
    """
    
    def __init__(self, base_output_dir='inventarios'):
        """
        Initialize CSV exporter
        
        Args:
            base_output_dir: Base directory for inventory exports
        """
        self.base_output_dir = base_output_dir
        self.timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        self.output_dir = os.path.join(base_output_dir, f'inventory_{self.timestamp}')
        
    def create_directory_structure(self):
        """Create organized directory structure for CSV exports"""
        directories = [
            self.output_dir,
            os.path.join(self.output_dir, '01_projects'),
            os.path.join(self.output_dir, '02_work_items'),
            os.path.join(self.output_dir, '03_boards'),
            os.path.join(self.output_dir, '04_repositories'),
            os.path.join(self.output_dir, '05_pipelines'),
            os.path.join(self.output_dir, '06_artifacts'),
            os.path.join(self.output_dir, '07_test'),
            os.path.join(self.output_dir, '08_security'),
            os.path.join(self.output_dir, '09_infrastructure'),
            os.path.join(self.output_dir, '10_extensions')
        ]
        
        for directory in directories:
            Path(directory).mkdir(parents=True, exist_ok=True)
        
        print(f"✅ Directory structure created: {self.output_dir}")
        return self.output_dir
    
    def write_csv(self, filepath, data, headers=None):
        """
        Write data to CSV file with UTF-8 BOM encoding for Excel compatibility
        
        Args:
            filepath: Full path to CSV file
            data: List of dictionaries containing data
            headers: Optional list of header names
        """
        if not data:
            # Create empty file with headers
            with open(filepath, 'w', newline='', encoding='utf-8-sig') as f:
                if headers:
                    writer = csv.DictWriter(f, fieldnames=headers)
                    writer.writeheader()
            return
        
        # Infer headers if not provided
        if not headers:
            headers = list(data[0].keys()) if isinstance(data[0], dict) else []
        
        with open(filepath, 'w', newline='', encoding='utf-8-sig') as f:
            if headers:
                writer = csv.DictWriter(f, fieldnames=headers, extrasaction='ignore')
                writer.writeheader()
                writer.writerows(data)
            else:
                writer = csv.writer(f)
                writer.writerows(data)
    
    def export_projects_summary(self, inventory_data):
        """Export projects summary with key metrics"""
        projects = inventory_data.get('inventory', {}).get('projects', {}).get('items', [])
        
        summary_data = []
        for project in projects:
            row = {
                'Project_ID': project.get('id', ''),
                'Project_Name': project.get('name', ''),
                'Description': project.get('description', ''),
                'State': project.get('state', ''),
                'Teams_Count': project.get('teams', {}).get('count', 0),
                'WIT_Types_Count': project.get('work_items', {}).get('work_item_types', {}).get('count', 0),
                'Fields_Count': project.get('work_items', {}).get('fields', {}).get('count', 0),
                'Queries_Count': project.get('work_items', {}).get('queries', {}).get('count', 0),
                'Repositories_Count': project.get('repositories', {}).get('repositories', {}).get('count', 0),
                'Build_Pipelines_Count': project.get('pipelines', {}).get('build_pipelines', {}).get('count', 0),
                'Release_Pipelines_Count': project.get('pipelines', {}).get('release_pipelines', {}).get('count', 0),
                'Test_Plans_Count': project.get('test', {}).get('test_plans', {}).get('count', 0)
            }
            summary_data.append(row)
        
        filepath = os.path.join(self.output_dir, '01_projects', 'projects_summary.csv')
        self.write_csv(filepath, summary_data)
        print(f"  ✓ {filepath}")
    
    def export_teams(self, inventory_data):
        """Export teams information"""
        projects = inventory_data.get('inventory', {}).get('projects', {}).get('items', [])
        
        teams_data = []
        for project in projects:
            project_name = project.get('name', '')
            teams = project.get('teams', {}).get('items', [])
            
            for team in teams:
                row = {
                    'Project': project_name,
                    'Team_ID': team.get('id', ''),
                    'Team_Name': team.get('name', ''),
                    'Description': team.get('description', ''),
                    'URL': team.get('url', '')
                }
                teams_data.append(row)
        
        filepath = os.path.join(self.output_dir, '01_projects', 'teams.csv')
        self.write_csv(filepath, teams_data)
        print(f"  ✓ {filepath}")
    
    def export_work_item_types(self, inventory_data):
        """Export work item types"""
        projects = inventory_data.get('inventory', {}).get('projects', {}).get('items', [])
        
        wit_data = []
        for project in projects:
            project_name = project.get('name', '')
            wit_types = project.get('work_items', {}).get('work_item_types', {}).get('items', [])
            
            for wit in wit_types:
                row = {
                    'Project': project_name,
                    'WIT_Name': wit.get('name', ''),
                    'Reference_Name': wit.get('referenceName', ''),
                    'Description': wit.get('description', ''),
                    'Color': wit.get('color', ''),
                    'Icon': wit.get('icon', ''),
                    'Is_Disabled': wit.get('isDisabled', False)
                }
                wit_data.append(row)
        
        filepath = os.path.join(self.output_dir, '02_work_items', 'work_item_types.csv')
        self.write_csv(filepath, wit_data)
        print(f"  ✓ {filepath}")
    
    def export_fields(self, inventory_data):
        """Export work item fields"""
        projects = inventory_data.get('inventory', {}).get('projects', {}).get('items', [])
        
        fields_data = []
        for project in projects:
            project_name = project.get('name', '')
            fields = project.get('work_items', {}).get('fields', {}).get('items', [])
            
            for field in fields:
                row = {
                    'Project': project_name,
                    'Field_Name': field.get('name', ''),
                    'Reference_Name': field.get('referenceName', ''),
                    'Type': field.get('type', ''),
                    'Usage': field.get('usage', ''),
                    'Is_Identity': field.get('isIdentity', False),
                    'Is_Picklist': field.get('isPicklist', False),
                    'Is_Queryable': field.get('isQueryable', False),
                    'Description': field.get('description', '')
                }
                fields_data.append(row)
        
        filepath = os.path.join(self.output_dir, '02_work_items', 'fields.csv')
        self.write_csv(filepath, fields_data)
        print(f"  ✓ {filepath}")
    
    def export_queries(self, inventory_data):
        """Export queries"""
        projects = inventory_data.get('inventory', {}).get('projects', {}).get('items', [])
        
        queries_data = []
        
        def process_query_folder(project_name, query, parent_path=''):
            """Process query folders recursively"""
            if query.get('isFolder'):
                folder_path = f"{parent_path}/{query.get('name', '')}" if parent_path else query.get('name', '')
                for child in query.get('children', []):
                    process_query_folder(project_name, child, folder_path)
            else:
                row = {
                    'Project': project_name,
                    'Query_ID': query.get('id', ''),
                    'Query_Name': query.get('name', ''),
                    'Path': parent_path,
                    'Query_Type': query.get('queryType', ''),
                    'Created_By': query.get('createdBy', {}).get('displayName', ''),
                    'Created_Date': query.get('createdDate', ''),
                    'Last_Modified_By': query.get('lastModifiedBy', {}).get('displayName', ''),
                    'Last_Modified_Date': query.get('lastModifiedDate', '')
                }
                queries_data.append(row)
        
        for project in projects:
            project_name = project.get('name', '')
            queries = project.get('work_items', {}).get('queries', {}).get('items', [])
            
            for query in queries:
                process_query_folder(project_name, query)
        
        filepath = os.path.join(self.output_dir, '02_work_items', 'queries.csv')
        self.write_csv(filepath, queries_data)
        print(f"  ✓ {filepath}")
    
    def export_boards(self, inventory_data):
        """Export Kanban boards"""
        projects = inventory_data.get('inventory', {}).get('projects', {}).get('items', [])
        
        boards_data = []
        for project in projects:
            project_name = project.get('name', '')
            boards = project.get('boards', {}).get('boards', {}).get('items', [])
            
            for board in boards:
                row = {
                    'Project': project_name,
                    'Team': board.get('team', ''),
                    'Board_ID': board.get('id', ''),
                    'Board_Name': board.get('name', ''),
                    'URL': board.get('url', '')
                }
                boards_data.append(row)
        
        filepath = os.path.join(self.output_dir, '03_boards', 'boards.csv')
        self.write_csv(filepath, boards_data)
        print(f"  ✓ {filepath}")
    
    def export_backlogs(self, inventory_data):
        """Export backlogs"""
        projects = inventory_data.get('inventory', {}).get('projects', {}).get('items', [])
        
        backlogs_data = []
        for project in projects:
            project_name = project.get('name', '')
            backlogs = project.get('boards', {}).get('backlogs', {}).get('items', [])
            
            for backlog in backlogs:
                row = {
                    'Project': project_name,
                    'Team': backlog.get('team', ''),
                    'Backlog_ID': backlog.get('id', ''),
                    'Backlog_Name': backlog.get('name', ''),
                    'Type': backlog.get('type', ''),
                    'URL': backlog.get('url', '')
                }
                backlogs_data.append(row)
        
        filepath = os.path.join(self.output_dir, '03_boards', 'backlogs.csv')
        self.write_csv(filepath, backlogs_data)
        print(f"  ✓ {filepath}")
    
    def export_repositories(self, inventory_data):
        """Export Git repositories"""
        projects = inventory_data.get('inventory', {}).get('projects', {}).get('items', [])
        
        repos_data = []
        for project in projects:
            project_name = project.get('name', '')
            repos = project.get('repositories', {}).get('repositories', {}).get('items', [])
            
            for repo in repos:
                row = {
                    'Project': project_name,
                    'Repository_ID': repo.get('id', ''),
                    'Repository_Name': repo.get('name', ''),
                    'Default_Branch': repo.get('defaultBranch', ''),
                    'Size': repo.get('size', 0),
                    'Branches_Count': repo.get('branches_count', 0),
                    'Pull_Requests_Count': repo.get('pull_requests_count', 0),
                    'URL': repo.get('webUrl', ''),
                    'Remote_URL': repo.get('remoteUrl', '')
                }
                repos_data.append(row)
        
        filepath = os.path.join(self.output_dir, '04_repositories', 'repositories.csv')
        self.write_csv(filepath, repos_data)
        print(f"  ✓ {filepath}")
    
    def export_branch_policies(self, inventory_data):
        """Export branch policies"""
        projects = inventory_data.get('inventory', {}).get('projects', {}).get('items', [])
        
        policies_data = []
        for project in projects:
            project_name = project.get('name', '')
            policies = project.get('repositories', {}).get('branch_policies', {}).get('items', [])
            
            for policy in policies:
                row = {
                    'Project': project_name,
                    'Policy_ID': policy.get('id', ''),
                    'Type': policy.get('type', {}).get('displayName', ''),
                    'Is_Enabled': policy.get('isEnabled', False),
                    'Is_Blocking': policy.get('isBlocking', False),
                    'Is_Deleted': policy.get('isDeleted', False),
                    'Created_By': policy.get('createdBy', {}).get('displayName', ''),
                    'Created_Date': policy.get('createdDate', '')
                }
                policies_data.append(row)
        
        filepath = os.path.join(self.output_dir, '04_repositories', 'branch_policies.csv')
        self.write_csv(filepath, policies_data)
        print(f"  ✓ {filepath}")
    
    def export_build_pipelines(self, inventory_data):
        """Export build pipelines"""
        projects = inventory_data.get('inventory', {}).get('projects', {}).get('items', [])
        
        builds_data = []
        for project in projects:
            project_name = project.get('name', '')
            builds = project.get('pipelines', {}).get('build_pipelines', {}).get('items', [])
            
            for build in builds:
                row = {
                    'Project': project_name,
                    'Pipeline_ID': build.get('id', ''),
                    'Pipeline_Name': build.get('name', ''),
                    'Type': build.get('type', ''),
                    'Quality': build.get('quality', ''),
                    'Queue_Status': build.get('queueStatus', ''),
                    'Revision': build.get('revision', ''),
                    'Created_Date': build.get('createdDate', ''),
                    'Path': build.get('path', ''),
                    'URL': build.get('url', '')
                }
                builds_data.append(row)
        
        filepath = os.path.join(self.output_dir, '05_pipelines', 'build_pipelines.csv')
        self.write_csv(filepath, builds_data)
        print(f"  ✓ {filepath}")
    
    def export_release_pipelines(self, inventory_data):
        """Export release pipelines"""
        projects = inventory_data.get('inventory', {}).get('projects', {}).get('items', [])
        
        releases_data = []
        for project in projects:
            project_name = project.get('name', '')
            releases = project.get('pipelines', {}).get('release_pipelines', {}).get('items', [])
            
            for release in releases:
                row = {
                    'Project': project_name,
                    'Pipeline_ID': release.get('id', ''),
                    'Pipeline_Name': release.get('name', ''),
                    'Path': release.get('path', ''),
                    'Created_By': release.get('createdBy', {}).get('displayName', ''),
                    'Created_On': release.get('createdOn', ''),
                    'Modified_By': release.get('modifiedBy', {}).get('displayName', ''),
                    'Modified_On': release.get('modifiedOn', ''),
                    'Environments_Count': len(release.get('environments', [])),
                    'URL': release.get('url', '')
                }
                releases_data.append(row)
        
        filepath = os.path.join(self.output_dir, '05_pipelines', 'release_pipelines.csv')
        self.write_csv(filepath, releases_data)
        print(f"  ✓ {filepath}")
    
    def export_variable_groups(self, inventory_data):
        """Export variable groups"""
        projects = inventory_data.get('inventory', {}).get('projects', {}).get('items', [])
        
        var_groups_data = []
        for project in projects:
            project_name = project.get('name', '')
            var_groups = project.get('pipelines', {}).get('variable_groups', {}).get('items', [])
            
            for vg in var_groups:
                row = {
                    'Project': project_name,
                    'Variable_Group_ID': vg.get('id', ''),
                    'Variable_Group_Name': vg.get('name', ''),
                    'Description': vg.get('description', ''),
                    'Type': vg.get('type', ''),
                    'Variables_Count': len(vg.get('variables', {})),
                    'Created_By': vg.get('createdBy', {}).get('displayName', ''),
                    'Created_On': vg.get('createdOn', ''),
                    'Is_Shared': vg.get('isShared', False)
                }
                var_groups_data.append(row)
        
        filepath = os.path.join(self.output_dir, '05_pipelines', 'variable_groups.csv')
        self.write_csv(filepath, var_groups_data)
        print(f"  ✓ {filepath}")
    
    def export_service_connections(self, inventory_data):
        """Export service connections"""
        projects = inventory_data.get('inventory', {}).get('projects', {}).get('items', [])
        
        connections_data = []
        for project in projects:
            project_name = project.get('name', '')
            connections = project.get('pipelines', {}).get('service_connections', {}).get('items', [])
            
            for conn in connections:
                row = {
                    'Project': project_name,
                    'Connection_ID': conn.get('id', ''),
                    'Connection_Name': conn.get('name', ''),
                    'Type': conn.get('type', ''),
                    'Description': conn.get('description', ''),
                    'Authorization': conn.get('authorization', {}).get('scheme', ''),
                    'Is_Shared': conn.get('isShared', False),
                    'Is_Ready': conn.get('isReady', False),
                    'Owner': conn.get('owner', ''),
                    'URL': conn.get('url', '')
                }
                connections_data.append(row)
        
        filepath = os.path.join(self.output_dir, '05_pipelines', 'service_connections.csv')
        self.write_csv(filepath, connections_data)
        print(f"  ✓ {filepath}")
    
    def export_environments(self, inventory_data):
        """Export environments"""
        projects = inventory_data.get('inventory', {}).get('projects', {}).get('items', [])
        
        environments_data = []
        for project in projects:
            project_name = project.get('name', '')
            environments = project.get('pipelines', {}).get('environments', {}).get('items', [])
            
            for env in environments:
                row = {
                    'Project': project_name,
                    'Environment_ID': env.get('id', ''),
                    'Environment_Name': env.get('name', ''),
                    'Description': env.get('description', ''),
                    'Created_By': env.get('createdBy', {}).get('displayName', ''),
                    'Created_On': env.get('createdOn', ''),
                    'Resources_Count': len(env.get('resources', []))
                }
                environments_data.append(row)
        
        filepath = os.path.join(self.output_dir, '05_pipelines', 'environments.csv')
        self.write_csv(filepath, environments_data)
        print(f"  ✓ {filepath}")
    
    def export_artifacts(self, inventory_data):
        """Export artifact feeds"""
        projects = inventory_data.get('inventory', {}).get('projects', {}).get('items', [])
        
        feeds_data = []
        for project in projects:
            project_name = project.get('name', '')
            feeds = project.get('artifacts', {}).get('feeds', {}).get('items', [])
            
            for feed in feeds:
                row = {
                    'Project': project_name,
                    'Feed_ID': feed.get('id', ''),
                    'Feed_Name': feed.get('name', ''),
                    'Description': feed.get('description', ''),
                    'URL': feed.get('url', ''),
                    'Upstream_Enabled': feed.get('upstreamEnabled', False),
                    'Capabilities': ','.join(feed.get('capabilities', []))
                }
                feeds_data.append(row)
        
        filepath = os.path.join(self.output_dir, '06_artifacts', 'feeds.csv')
        self.write_csv(filepath, feeds_data)
        print(f"  ✓ {filepath}")
    
    def export_test_plans(self, inventory_data):
        """Export test plans"""
        projects = inventory_data.get('inventory', {}).get('projects', {}).get('items', [])
        
        test_plans_data = []
        for project in projects:
            project_name = project.get('name', '')
            test_plans = project.get('test', {}).get('test_plans', {}).get('items', [])
            
            for plan in test_plans:
                row = {
                    'Project': project_name,
                    'Test_Plan_ID': plan.get('id', ''),
                    'Test_Plan_Name': plan.get('name', ''),
                    'State': plan.get('state', ''),
                    'Area_Path': plan.get('area', {}).get('name', ''),
                    'Iteration': plan.get('iteration', ''),
                    'Owner': plan.get('owner', {}).get('displayName', ''),
                    'Start_Date': plan.get('startDate', ''),
                    'End_Date': plan.get('endDate', ''),
                    'URL': plan.get('url', '')
                }
                test_plans_data.append(row)
        
        filepath = os.path.join(self.output_dir, '07_test', 'test_plans.csv')
        self.write_csv(filepath, test_plans_data)
        print(f"  ✓ {filepath}")
    
    def export_agent_pools(self, inventory_data):
        """Export agent pools and agents"""
        infrastructure = inventory_data.get('inventory', {}).get('infrastructure', {})
        pools = infrastructure.get('agent_pools', {}).get('items', [])
        
        pools_data = []
        agents_data = []
        
        for pool in pools:
            pool_row = {
                'Pool_ID': pool.get('id', ''),
                'Pool_Name': pool.get('name', ''),
                'Pool_Type': pool.get('poolType', ''),
                'Is_Hosted': pool.get('isHosted', False),
                'Size': pool.get('size', 0),
                'Agents_Count': pool.get('agents', {}).get('count', 0),
                'Is_Legacy': pool.get('isLegacy', False)
            }
            pools_data.append(pool_row)
            
            # Export agents
            for agent in pool.get('agents', {}).get('items', []):
                agent_row = {
                    'Pool_Name': pool.get('name', ''),
                    'Agent_ID': agent.get('id', ''),
                    'Agent_Name': agent.get('name', ''),
                    'Version': agent.get('version', ''),
                    'Enabled': agent.get('enabled', False),
                    'Status': agent.get('status', ''),
                    'OS_Description': agent.get('osDescription', ''),
                    'Created_On': agent.get('createdOn', '')
                }
                agents_data.append(agent_row)
        
        # Save pools
        filepath = os.path.join(self.output_dir, '09_infrastructure', 'agent_pools.csv')
        self.write_csv(filepath, pools_data)
        print(f"  ✓ {filepath}")
        
        # Save agents
        filepath = os.path.join(self.output_dir, '09_infrastructure', 'agents.csv')
        self.write_csv(filepath, agents_data)
        print(f"  ✓ {filepath}")
    
    def export_extensions(self, inventory_data):
        """Export installed extensions"""
        extensions = inventory_data.get('inventory', {}).get('extensions', {}).get('items', [])
        
        extensions_data = []
        for ext in extensions:
            row = {
                'Extension_ID': ext.get('extensionId', ''),
                'Extension_Name': ext.get('extensionName', ''),
                'Publisher_ID': ext.get('publisherId', ''),
                'Publisher_Name': ext.get('publisherName', ''),
                'Version': ext.get('version', ''),
                'Flags': ext.get('flags', ''),
                'Install_State': ext.get('installState', {}).get('flags', ''),
                'Last_Published': ext.get('lastPublished', '')
            }
            extensions_data.append(row)
        
        filepath = os.path.join(self.output_dir, '10_extensions', 'installed_extensions.csv')
        self.write_csv(filepath, extensions_data)
        print(f"  ✓ {filepath}")
    
    def export_users(self, inventory_data):
        """Export users"""
        security = inventory_data.get('inventory', {}).get('organization_security', {})
        users = security.get('users', {}).get('items', [])
        
        users_data = []
        for user in users:
            row = {
                'User_Descriptor': user.get('descriptor', ''),
                'Display_Name': user.get('displayName', ''),
                'Principal_Name': user.get('principalName', ''),
                'Mail_Address': user.get('mailAddress', ''),
                'Origin': user.get('origin', ''),
                'Origin_ID': user.get('originId', ''),
                'Domain': user.get('domain', ''),
                'URL': user.get('url', '')
            }
            users_data.append(row)
        
        filepath = os.path.join(self.output_dir, '08_security', 'users.csv')
        self.write_csv(filepath, users_data)
        print(f"  ✓ {filepath}")
    
    def export_security_groups(self, inventory_data):
        """Export security groups"""
        security = inventory_data.get('inventory', {}).get('organization_security', {})
        groups = security.get('security_groups', {}).get('items', [])
        
        groups_data = []
        for group in groups:
            row = {
                'Group_Descriptor': group.get('descriptor', ''),
                'Display_Name': group.get('displayName', ''),
                'Principal_Name': group.get('principalName', ''),
                'Mail_Address': group.get('mailAddress', ''),
                'Origin': group.get('origin', ''),
                'Origin_ID': group.get('originId', ''),
                'Domain': group.get('domain', ''),
                'URL': group.get('url', '')
            }
            groups_data.append(row)
        
        filepath = os.path.join(self.output_dir, '08_security', 'security_groups.csv')
        self.write_csv(filepath, groups_data)
        print(f"  ✓ {filepath}")
    
    def export_metadata(self, inventory_data):
        """Export inventory metadata"""
        metadata = inventory_data.get('metadata', {})
        
        metadata_rows = [
            {'Key': 'Timestamp', 'Value': metadata.get('timestamp', '')},
            {'Key': 'Server', 'Value': metadata.get('server', '')},
            {'Key': 'Collection', 'Value': metadata.get('collection', '')},
            {'Key': 'Categories', 'Value': ', '.join(metadata.get('categories_included', []))}
        ]
        
        filepath = os.path.join(self.output_dir, 'inventory_metadata.csv')
        self.write_csv(filepath, metadata_rows)
        print(f"  ✓ {filepath}")
    
    def export_all(self, inventory_data):
        """Export complete inventory to CSV files"""
        print(f"\n📊 Exporting inventory to CSV...")
        print(f"{'='*70}")
        
        # Create directory structure
        self.create_directory_structure()
        
        # Export metadata
        print(f"\n📋 Exporting Metadata...")
        self.export_metadata(inventory_data)
        
        # Export projects
        print(f"\n📦 Exporting Projects...")
        self.export_projects_summary(inventory_data)
        self.export_teams(inventory_data)
        
        # Export work items
        print(f"\n🔧 Exporting Work Items...")
        self.export_work_item_types(inventory_data)
        self.export_fields(inventory_data)
        self.export_queries(inventory_data)
        
        # Export boards (if available)
        if any(p.get('boards') for p in inventory_data.get('inventory', {}).get('projects', {}).get('items', [])):
            print(f"\n📊 Exporting Boards...")
            self.export_boards(inventory_data)
            self.export_backlogs(inventory_data)
        
        # Export repositories
        print(f"\n📚 Exporting Repositories...")
        self.export_repositories(inventory_data)
        self.export_branch_policies(inventory_data)
        
        # Export pipelines
        print(f"\n🔄 Exporting Pipelines...")
        self.export_build_pipelines(inventory_data)
        self.export_release_pipelines(inventory_data)
        self.export_variable_groups(inventory_data)
        self.export_service_connections(inventory_data)
        self.export_environments(inventory_data)
        
        # Export artifacts (if available)
        if any(p.get('artifacts') for p in inventory_data.get('inventory', {}).get('projects', {}).get('items', [])):
            print(f"\n📦 Exporting Artifacts...")
            self.export_artifacts(inventory_data)
        
        # Export test plans (if available)
        if any(p.get('test') for p in inventory_data.get('inventory', {}).get('projects', {}).get('items', [])):
            print(f"\n🧪 Exporting Test Plans...")
            self.export_test_plans(inventory_data)
        
        # Export infrastructure (if available)
        if 'infrastructure' in inventory_data.get('inventory', {}):
            print(f"\n🖥️  Exporting Infrastructure...")
            self.export_agent_pools(inventory_data)
        
        # Export extensions (if available)
        if 'extensions' in inventory_data.get('inventory', {}):
            print(f"\n🔌 Exporting Extensions...")
            self.export_extensions(inventory_data)
        
        # Export security (if available)
        if 'organization_security' in inventory_data.get('inventory', {}):
            print(f"\n🔐 Exporting Security...")
            self.export_users(inventory_data)
            self.export_security_groups(inventory_data)
        
        print(f"\n{'='*70}")
        print(f"✅ CSV export completed!")
        print(f"📁 Directory: {self.output_dir}")
        print(f"{'='*70}\n")
        
        return self.output_dir
