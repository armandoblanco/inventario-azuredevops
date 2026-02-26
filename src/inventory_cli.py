"""
Azure DevOps Server 2022 - Inventory CLI
Command-line interface for flexible inventory execution
"""

import argparse
import sys
from datetime import datetime
from main import AzureDevOpsServer2022Inventory
from config import AZURE_DEVOPS_SERVER_CONFIG, INVENTORY_CATEGORIES
from csv_exporter import CSVExporter
import json


class InventoryRunner:
    """
    Orchestrates inventory execution across selected categories
    """
    
    def __init__(self, ado_instance, categories_to_run, verbose=True):
        """
        Initialize inventory runner
        
        Args:
            ado_instance: AzureDevOpsServer2022Inventory instance
            categories_to_run: List of categories to inventory
            verbose: Show detailed progress output
        """
        self.ado = ado_instance
        self.categories = categories_to_run
        self.verbose = verbose
        self.results = {
            'metadata': {
                'timestamp': datetime.now().isoformat(),
                'server': self.ado.server_url,
                'collection': self.ado.collection,
                'categories_included': categories_to_run
            },
            'inventory': {}
        }
    
    def print_status(self, message, level='info'):
        """Print status messages with icons"""
        if not self.verbose:
            return
        
        icons = {
            'info': 'ℹ️ ',
            'success': '✅',
            'warning': '⚠️ ',
            'error': '❌',
            'processing': '🔄'
        }
        print(f"{icons.get(level, 'ℹ️ ')} {message}")
    
    def should_include(self, category):
        """Check if category should be included in inventory"""
        return category in self.categories or 'all' in self.categories
    
    def run_inventory(self):
        """Execute complete inventory based on selected categories"""
        print("\n" + "="*70)
        print("🔍 AZURE DEVOPS SERVER 2022 - INVENTORY")
        print("="*70)
        
        # Get projects (always needed as foundation)
        self.print_status("Getting project list...", 'processing')
        projects = self.ado.get_projects()
        
        if 'error' in projects:
            self.print_status(f"Connection error: {projects['error']}", 'error')
            return None
        
        project_list = projects.get('value', [])
        self.print_status(f"Projects found: {len(project_list)}", 'success')
        
        self.results['inventory']['projects'] = {
            'count': len(project_list),
            'items': []
        }
        
        # Process each project
        for idx, project in enumerate(project_list, 1):
            project_name = project['name']
            project_id = project['id']
            
            print(f"\n{'─'*70}")
            print(f"📁 [{idx}/{len(project_list)}] Project: {project_name}")
            print(f"{'─'*70}")
            
            project_data = {
                'id': project_id,
                'name': project_name,
                'description': project.get('description', ''),
                'state': project.get('state', ''),
                'url': project.get('url', '')
            }
            
            # Core & Projects
            if self.should_include('core'):
                project_data['teams'] = self._inventory_teams(project_name)
            
            # Work Items
            if self.should_include('work_items'):
                project_data['work_items'] = self._inventory_work_items(project_name)
            
            # Boards
            if self.should_include('boards'):
                project_data['boards'] = self._inventory_boards(project_name)
            
            # Repositories
            if self.should_include('repos'):
                project_data['repositories'] = self._inventory_repos(project_name)
            
            # Pipelines
            if self.should_include('pipelines'):
                project_data['pipelines'] = self._inventory_pipelines(project_name)
            
            # Artifacts
            if self.should_include('artifacts'):
                project_data['artifacts'] = self._inventory_artifacts(project_name)
            
            # Test
            if self.should_include('test'):
                project_data['test'] = self._inventory_test(project_name)
            
            # Integrations
            if self.should_include('extensions'):
                project_data['integrations'] = self._inventory_integrations(project_name)
            
            self.results['inventory']['projects']['items'].append(project_data)
        
        # Collection-level inventory
        print(f"\n{'='*70}")
        print("🌐 Collection-Level Inventory")
        print(f"{'='*70}")
        
        if self.should_include('infrastructure'):
            self.results['inventory']['infrastructure'] = self._inventory_infrastructure()
        
        if self.should_include('artifacts'):
            self.results['inventory']['organization_feeds'] = self._inventory_org_feeds()
        
        if self.should_include('extensions'):
            self.results['inventory']['extensions'] = self._inventory_extensions()
        
        if self.should_include('security'):
            self.results['inventory']['organization_security'] = self._inventory_org_security()
        
        print(f"\n{'='*70}")
        self.print_status("Inventory completed successfully!", 'success')
        print(f"{'='*70}\n")
        
        return self.results
    
    # ===== Category Inventory Methods =====
    
    def _inventory_teams(self, project):
        """Inventory teams"""
        self.print_status(f"  Getting teams...", 'processing')
        teams = self.ado.get_teams(project)
        count = teams.get('count', 0)
        self.print_status(f"  Teams: {count}", 'info')
        return {
            'count': count,
            'items': teams.get('value', [])
        }
    
    def _inventory_work_items(self, project):
        """Inventory work items configuration"""
        self.print_status(f"  Getting Work Items...", 'processing')
        data = {}
        
        # Work Item Types
        wit_types = self.ado.get_work_item_types(project)
        data['work_item_types'] = {
            'count': len(wit_types.get('value', [])),
            'items': wit_types.get('value', [])
        }
        
        # Fields
        fields = self.ado.get_work_item_fields(project)
        data['fields'] = {
            'count': fields.get('count', 0),
            'items': fields.get('value', [])
        }
        
        # Areas
        areas = self.ado.get_area_paths(project)
        data['area_paths'] = areas
        
        # Iterations
        iterations = self.ado.get_iteration_paths(project)
        data['iteration_paths'] = iterations
        
        # Queries
        queries = self.ado.get_queries(project)
        data['queries'] = {
            'count': queries.get('count', 0),
            'items': queries.get('value', [])
        }
        
        self.print_status(f"    ├─ WIT Types: {data['work_item_types']['count']}", 'info')
        self.print_status(f"    ├─ Fields: {data['fields']['count']}", 'info')
        self.print_status(f"    └─ Queries: {data['queries']['count']}", 'info')
        
        return data
    
    def _inventory_boards(self, project):
        """Inventory boards and planning tools"""
        self.print_status(f"  Getting Boards...", 'processing')
        data = {}
        
        # Get teams first
        teams = self.ado.get_teams(project)
        team_list = teams.get('value', [])
        
        all_boards = []
        all_backlogs = []
        
        # Limit to first 5 teams to avoid overwhelming API
        for team in team_list[:5]:
            team_name = team['name']
            
            # Boards
            boards = self.ado.get_boards(project, team_name)
            for board in boards.get('value', []):
                board['team'] = team_name
                all_boards.append(board)
            
            # Backlogs
            backlogs = self.ado.get_backlogs(project, team_name)
            for backlog in backlogs.get('value', []):
                backlog['team'] = team_name
                all_backlogs.append(backlog)
        
        data['boards'] = {
            'count': len(all_boards),
            'items': all_boards
        }
        
        data['backlogs'] = {
            'count': len(all_backlogs),
            'items': all_backlogs
        }
        
        # Delivery Plans
        plans = self.ado.get_delivery_plans(project)
        data['delivery_plans'] = {
            'count': plans.get('count', 0),
            'items': plans.get('value', [])
        }
        
        # Dashboards (from first team)
        if team_list:
            dashboards = self.ado.get_dashboards(project, team_list[0]['name'])
            data['dashboards'] = {
                'count': dashboards.get('count', 0),
                'items': dashboards.get('value', [])
            }
        
        self.print_status(f"    ├─ Boards: {data['boards']['count']}", 'info')
        self.print_status(f"    ├─ Backlogs: {data['backlogs']['count']}", 'info')
        self.print_status(f"    └─ Delivery Plans: {data['delivery_plans']['count']}", 'info')
        
        return data
    
    def _inventory_repos(self, project):
        """Inventory repositories"""
        self.print_status(f"  Getting Repositories...", 'processing')
        data = {}
        
        repos = self.ado.get_repositories(project)
        repo_list = repos.get('value', [])
        
        data['repositories'] = {
            'count': len(repo_list),
            'items': []
        }
        
        for repo in repo_list:
            repo_data = repo.copy()
            repo_id = repo['id']
            
            # Branches
            branches = self.ado.get_branches(project, repo_id)
            repo_data['branches_count'] = len(branches.get('value', []))
            
            # Pull Requests
            prs = self.ado.get_pull_requests(project, repo_id)
            repo_data['pull_requests_count'] = prs.get('count', 0)
            
            data['repositories']['items'].append(repo_data)
        
        # Branch Policies
        policies = self.ado.get_branch_policies(project)
        data['branch_policies'] = {
            'count': policies.get('count', 0),
            'items': policies.get('value', [])
        }
        
        self.print_status(f"    ├─ Repositories: {data['repositories']['count']}", 'info')
        self.print_status(f"    └─ Branch Policies: {data['branch_policies']['count']}", 'info')
        
        return data
    
    def _inventory_pipelines(self, project):
        """Inventory pipelines"""
        self.print_status(f"  Getting Pipelines...", 'processing')
        data = {}
        
        # Build Pipelines
        builds = self.ado.get_build_definitions(project)
        data['build_pipelines'] = {
            'count': builds.get('count', 0),
            'items': builds.get('value', [])
        }
        
        # Release Pipelines
        releases = self.ado.get_release_definitions(project)
        data['release_pipelines'] = {
            'count': releases.get('count', 0),
            'items': releases.get('value', [])
        }
        
        # Variable Groups
        var_groups = self.ado.get_variable_groups(project)
        data['variable_groups'] = {
            'count': var_groups.get('count', 0),
            'items': var_groups.get('value', [])
        }
        
        # Service Connections
        endpoints = self.ado.get_service_endpoints(project)
        data['service_connections'] = {
            'count': endpoints.get('count', 0),
            'items': endpoints.get('value', [])
        }
        
        # Environments
        environments = self.ado.get_environments(project)
        data['environments'] = {
            'count': environments.get('count', 0),
            'items': environments.get('value', [])
        }
        
        # Deployment Groups
        dep_groups = self.ado.get_deployment_groups(project)
        data['deployment_groups'] = {
            'count': dep_groups.get('count', 0),
            'items': dep_groups.get('value', [])
        }
        
        # Secure Files
        secure_files = self.ado.get_secure_files(project)
        data['secure_files'] = {
            'count': secure_files.get('count', 0),
            'items': secure_files.get('value', [])
        }
        
        self.print_status(f"    ├─ Build Pipelines: {data['build_pipelines']['count']}", 'info')
        self.print_status(f"    ├─ Release Pipelines: {data['release_pipelines']['count']}", 'info')
        self.print_status(f"    ├─ Variable Groups: {data['variable_groups']['count']}", 'info')
        self.print_status(f"    ├─ Service Connections: {data['service_connections']['count']}", 'info')
        self.print_status(f"    └─ Environments: {data['environments']['count']}", 'info')
        
        return data
    
    def _inventory_artifacts(self, project):
        """Inventory artifacts"""
        self.print_status(f"  Getting Artifacts...", 'processing')
        data = {}
        
        feeds = self.ado.get_feeds(project)
        data['feeds'] = {
            'count': feeds.get('count', 0),
            'items': feeds.get('value', [])
        }
        
        self.print_status(f"    └─ Feeds: {data['feeds']['count']}", 'info')
        
        return data
    
    def _inventory_test(self, project):
        """Inventory test management"""
        self.print_status(f"  Getting Test Plans...", 'processing')
        data = {}
        
        # Test Plans
        test_plans = self.ado.get_test_plans(project)
        data['test_plans'] = {
            'count': test_plans.get('count', 0),
            'items': test_plans.get('value', [])
        }
        
        # Test Runs
        test_runs = self.ado.get_test_runs(project)
        data['test_runs'] = {
            'count': test_runs.get('count', 0),
            'items': test_runs.get('value', [])
        }
        
        self.print_status(f"    ├─ Test Plans: {data['test_plans']['count']}", 'info')
        self.print_status(f"    └─ Test Runs: {data['test_runs']['count']}", 'info')
        
        return data
    
    def _inventory_integrations(self, project):
        """Inventory integrations"""
        self.print_status(f"  Getting Integrations...", 'processing')
        data = {}
        
        # Service Hooks
        hooks = self.ado.get_service_hooks(project)
        data['service_hooks'] = {
            'count': hooks.get('count', 0),
            'items': hooks.get('value', [])
        }
        
        self.print_status(f"    └─ Service Hooks: {data['service_hooks']['count']}", 'info')
        
        return data
    
    def _inventory_infrastructure(self):
        """Inventory infrastructure"""
        self.print_status("Getting Agent Pools...", 'processing')
        data = {}
        
        pools = self.ado.get_agent_pools()
        pool_list = pools.get('value', [])
        
        data['agent_pools'] = {
            'count': len(pool_list),
            'items': []
        }
        
        for pool in pool_list:
            pool_data = pool.copy()
            pool_id = pool['id']
            
            agents = self.ado.get_agents(pool_id)
            pool_data['agents'] = {
                'count': len(agents.get('value', [])),
                'items': agents.get('value', [])
            }
            
            data['agent_pools']['items'].append(pool_data)
        
        self.print_status(f"  Agent Pools: {data['agent_pools']['count']}", 'info')
        
        return data
    
    def _inventory_org_feeds(self):
        """Inventory organization-level feeds"""
        self.print_status("Getting Organization Feeds...", 'processing')
        feeds = self.ado.get_feeds()
        
        data = {
            'count': feeds.get('count', 0),
            'items': feeds.get('value', [])
        }
        
        self.print_status(f"  Organization Feeds: {data['count']}", 'info')
        
        return data
    
    def _inventory_extensions(self):
        """Inventory extensions"""
        self.print_status("Getting Extensions...", 'processing')
        extensions = self.ado.get_installed_extensions()
        
        data = {
            'count': extensions.get('count', 0),
            'items': extensions.get('value', [])
        }
        
        self.print_status(f"  Installed Extensions: {data['count']}", 'info')
        
        return data
    
    def _inventory_org_security(self):
        """Inventory organization security"""
        self.print_status("Getting Users and Groups...", 'processing')
        data = {}
        
        # Users
        users = self.ado.get_users()
        data['users'] = {
            'count': users.get('count', 0),
            'items': users.get('value', [])
        }
        
        # Security Groups
        groups = self.ado.get_security_groups()
        data['security_groups'] = {
            'count': groups.get('count', 0),
            'items': groups.get('value', [])
        }
        
        self.print_status(f"  Users: {data['users']['count']}", 'info')
        self.print_status(f"  Security Groups: {data['security_groups']['count']}", 'info')
        
        return data


def parse_arguments():
    """Parse command-line arguments"""
    parser = argparse.ArgumentParser(
        description='Azure DevOps Server 2022 - Inventory Tool',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  
  # Complete inventory in CSV
  python inventory_cli.py --all --format csv
  
  # Everything except boards
  python inventory_cli.py --all --exclude boards --format csv
  
  # Everything except boards and test
  python inventory_cli.py --all --exclude boards test --format csv
  
  # Only specific categories
  python inventory_cli.py --include core work_items repos --format csv
  
  # Custom configuration
  python inventory_cli.py --all --server https://tfs.company.com --collection MyCollection --token YOUR_PAT
  
  # Both JSON and CSV output
  python inventory_cli.py --all --format both
  
  # Custom CSV directory
  python inventory_cli.py --all --format csv --csv-dir my_inventories

Available categories:
  core          - Projects and teams
  work_items    - Work items, fields, areas, iterations, queries
  boards        - Boards, backlogs, delivery plans, dashboards
  repos         - Repositories, branches, policies, pull requests
  pipelines     - Build, release, variables, service connections
  artifacts     - Feeds and packages
  test          - Test plans, suites, cases, runs
  security      - Users, groups, permissions
  extensions    - Extensions and service hooks
  infrastructure- Agent pools and agents
        """
    )
    
    # Inventory options
    inventory_group = parser.add_mutually_exclusive_group(required=True)
    inventory_group.add_argument(
        '--all',
        action='store_true',
        help='Inventory everything'
    )
    inventory_group.add_argument(
        '--include',
        nargs='+',
        choices=list(INVENTORY_CATEGORIES.keys()),
        help='Include only these categories'
    )
    
    parser.add_argument(
        '--exclude',
        nargs='+',
        choices=list(INVENTORY_CATEGORIES.keys()),
        help='Exclude these categories (use with --all)'
    )
    
    # Connection configuration
    parser.add_argument(
        '--server',
        help='Azure DevOps Server URL (e.g., https://tfs.company.com/tfs)'
    )
    parser.add_argument(
        '--collection',
        help='Collection name (default: DefaultCollection)'
    )
    parser.add_argument(
        '--token',
        help='Personal Access Token (PAT)'
    )
    parser.add_argument(
        '--no-ssl-verify',
        action='store_true',
        help='Disable SSL certificate verification (for self-signed certificates)'
    )
    
    # Output options
    parser.add_argument(
        '--output',
        '-o',
        default=f'inventory_{datetime.now().strftime("%Y%m%d_%H%M%S")}.json',
        help='JSON output file (default: inventory_TIMESTAMP.json)'
    )
    parser.add_argument(
        '--format',
        choices=['json', 'csv', 'both'],
        default='both',
        help='Output format: json, csv, or both (default: both)'
    )
    parser.add_argument(
        '--csv-dir',
        default='inventarios',
        help='Base directory for CSV exports (default: inventarios)'
    )
    parser.add_argument(
        '--quiet',
        '-q',
        action='store_true',
        help='Quiet mode (minimal output)'
    )
    parser.add_argument(
        '--pretty',
        action='store_true',
        help='Pretty-print JSON output (more readable but larger)'
    )
    
    return parser.parse_args()


def main():
    """Main entry point"""
    args = parse_arguments()
    
    # Determine categories to include
    if args.all:
        categories = ['all']
        if args.exclude:
            categories = [cat for cat in INVENTORY_CATEGORIES.keys() if cat not in args.exclude]
    else:
        categories = args.include
    
    # Configuration
    server_url = args.server or AZURE_DEVOPS_SERVER_CONFIG['server_url']
    collection = args.collection or AZURE_DEVOPS_SERVER_CONFIG['collection']
    pat_token = args.token or AZURE_DEVOPS_SERVER_CONFIG['pat_token']
    verify_ssl = not args.no_ssl_verify
    
    # Validate required parameters
    if not pat_token:
        print("❌ Error: Personal Access Token (PAT) is required")
        print("   Use --token YOUR_PAT or configure it in .env file")
        sys.exit(1)
    
    if not server_url or server_url == 'https://your-server.company.com/tfs':
        print("❌ Error: Server URL is required")
        print("   Use --server https://your-server/tfs or configure it in .env file")
        sys.exit(1)
    
    # Show configuration
    if not args.quiet:
        print("\n📋 Configuration:")
        print(f"   Server: {server_url}")
        print(f"   Collection: {collection}")
        print(f"   SSL Verify: {verify_ssl}")
        print(f"   Categories: {', '.join(categories)}")
        if args.exclude:
            print(f"   Excluded: {', '.join(args.exclude)}")
        print(f"   Output Format: {args.format}")
        if args.format in ['csv', 'both']:
            print(f"   CSV Directory: {args.csv_dir}")
        if args.format in ['json', 'both']:
            print(f"   JSON File: {args.output}")
    
    try:
        # Create Azure DevOps client
        ado = AzureDevOpsServer2022Inventory(
            server_url=server_url,
            pat_token=pat_token,
            collection=collection,
            verify_ssl=verify_ssl
        )
        
        # Run inventory
        runner = InventoryRunner(
            ado_instance=ado,
            categories_to_run=categories,
            verbose=not args.quiet
        )
        
        results = runner.run_inventory()
        
        if results:
            output_files = []
            
            # Save JSON if requested
            if args.format in ['json', 'both']:
                with open(args.output, 'w', encoding='utf-8') as f:
                    if args.pretty:
                        json.dump(results, f, indent=2, ensure_ascii=False)
                    else:
                        json.dump(results, f, ensure_ascii=False)
                
                json_size = round(len(json.dumps(results)) / 1024, 2)
                print(f"\n💾 JSON saved: {args.output}")
                print(f"📊 Size: {json_size} KB")
                output_files.append(args.output)
            
            # Save CSV if requested
            if args.format in ['csv', 'both']:
                exporter = CSVExporter(base_output_dir=args.csv_dir)
                csv_dir = exporter.export_all(results)
                output_files.append(csv_dir)
            
            # Final summary
            print(f"\n{'='*70}")
            print(f"✅ INVENTORY COMPLETED SUCCESSFULLY")
            print(f"{'='*70}")
            print(f"\n📁 Generated files:")
            for file in output_files:
                print(f"   • {file}")
            print()
            
            return 0
        else:
            print("\n❌ Inventory could not be completed")
            return 1
            
    except KeyboardInterrupt:
        print("\n\n⚠️  Inventory interrupted by user")
        return 130
    except Exception as e:
        print(f"\n❌ Fatal error: {str(e)}")
        import traceback
        traceback.print_exc()
        return 1


if __name__ == "__main__":
    sys.exit(main())
