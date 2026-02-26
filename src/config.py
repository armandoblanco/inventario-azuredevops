"""
Configuration management for Azure DevOps Server 2022 Inventory Tool
Loads environment variables and defines inventory categories
"""

import os
from dotenv import load_dotenv

# Load environment variables from .env file
load_dotenv()

# Azure DevOps Server Configuration
AZURE_DEVOPS_SERVER_CONFIG = {
    'server_url': os.getenv('AZDO_SERVER_URL', 'https://your-server.company.com/tfs'),
    'collection': os.getenv('AZDO_COLLECTION', 'DefaultCollection'),
    'pat_token': os.getenv('AZDO_PAT', ''),
    'verify_ssl': os.getenv('AZDO_VERIFY_SSL', 'True').lower() in ('true', '1', 'yes'),
    'api_version': os.getenv('AZDO_API_VERSION', '7.0'),
    'timeout': 30
}

# Inventory Categories Definition
# Each category groups related Azure DevOps objects
INVENTORY_CATEGORIES = {
    'core': {
        'name': 'Core & Projects',
        'description': 'Team Projects, Teams, Process Templates',
        'items': ['projects', 'teams', 'process_templates']
    },
    'work_items': {
        'name': 'Work Items',
        'description': 'Work Item Types, Fields, States, Areas, Iterations, Queries',
        'items': ['work_item_types', 'fields', 'states', 'areas', 'iterations', 'queries', 'rules']
    },
    'boards': {
        'name': 'Boards & Planning',
        'description': 'Kanban Boards, Backlogs, Delivery Plans, Dashboards',
        'items': ['boards', 'backlogs', 'delivery_plans', 'dashboards']
    },
    'repos': {
        'name': 'Repositories',
        'description': 'Git Repositories, Branches, Branch Policies, Pull Requests',
        'items': ['repositories', 'branches', 'branch_policies', 'pull_requests']
    },
    'pipelines': {
        'name': 'Pipelines',
        'description': 'Build Pipelines, Release Pipelines, Variables, Service Connections, Environments',
        'items': ['build_pipelines', 'release_pipelines', 'variable_groups', 
                 'service_connections', 'environments', 'deployment_groups', 'secure_files']
    },
    'artifacts': {
        'name': 'Artifacts & Packages',
        'description': 'Artifact Feeds, NuGet/npm/Maven/Python Packages',
        'items': ['feeds', 'packages']
    },
    'test': {
        'name': 'Test Management',
        'description': 'Test Plans, Test Suites, Test Cases, Test Runs',
        'items': ['test_plans', 'test_suites', 'test_cases', 'test_runs']
    },
    'security': {
        'name': 'Security & Users',
        'description': 'Security Groups, Users, Permissions',
        'items': ['security_groups', 'users', 'permissions']
    },
    'extensions': {
        'name': 'Extensions & Integrations',
        'description': 'Marketplace Extensions, Service Hooks, Webhooks',
        'items': ['extensions', 'service_hooks']
    },
    'infrastructure': {
        'name': 'Infrastructure',
        'description': 'Agent Pools, Self-hosted Agents',
        'items': ['agent_pools', 'agents']
    }
}

# Output directory
OUTPUT_DIR = os.getenv('OUTPUT_DIR', './inventarios')
