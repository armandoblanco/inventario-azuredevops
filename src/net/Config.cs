using System;
using System.Configuration;

namespace AzureDevOpsInventory
{
    /// <summary>
    /// Configuration management for Azure DevOps Server 2022 Inventory Tool
    /// Loads settings from App.config
    /// Compatible with .NET Framework 4.0
    /// </summary>
    public static class Config
    {
        public static string ServerUrl
        {
            get { return GetAppSetting("AZDO_SERVER_URL", "https://your-server.company.com/tfs"); }
        }

        public static string Collection
        {
            get { return GetAppSetting("AZDO_COLLECTION", "DefaultCollection"); }
        }

        public static string PatToken
        {
            get { return GetAppSetting("AZDO_PAT", ""); }
        }

        public static bool VerifySsl
        {
            get { return GetAppSetting("AZDO_VERIFY_SSL", "True").ToLower() == "true"; }
        }

        public static string ApiVersion
        {
            get { return GetAppSetting("AZDO_API_VERSION", "7.0"); }
        }

        public static string OutputDir
        {
            get { return GetAppSetting("OUTPUT_DIR", "./inventarios"); }
        }

        public static int Timeout
        {
            get { return 30; }
        }

        private static string GetAppSetting(string key, string defaultValue)
        {
            var value = ConfigurationManager.AppSettings[key];
            return string.IsNullOrEmpty(value) ? defaultValue : value;
        }

        /// <summary>
        /// Inventory Categories Definition
        /// Each category groups related Azure DevOps objects
        /// </summary>
        public static readonly string[] AllCategories = new string[]
        {
            "core",
            "work_items",
            "boards",
            "repos",
            "pipelines",
            "artifacts",
            "test",
            "security",
            "extensions",
            "infrastructure"
        };
    }
}
