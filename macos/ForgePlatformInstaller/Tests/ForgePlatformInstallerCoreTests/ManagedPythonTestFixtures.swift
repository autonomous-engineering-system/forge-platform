import ForgePlatformInstallerCore

let managedPythonTestRuntime: ManagedPythonRuntimeIdentity = try! ManagedPythonRuntimeIdentity(
    version: InstallerVersion("3.14.7"),
    minimumMacOSVersion: InstallerVersion("26.0.0"),
    pythonTag: "cp314",
    abiTag: "cp314",
    artifact: ManagedPythonDownloadIdentity(
        url: "https://example.com/python.tar.gz",
        sha256: "sha256:" + String(repeating: "11", count: 32)
    ),
    source: ManagedPythonDownloadIdentity(
        url: "https://example.com/source.tar.gz",
        sha256: "sha256:" + String(repeating: "22", count: 32)
    ),
    sourceProvenance: ManagedPythonDownloadIdentity(
        url: "https://example.com/source.json",
        sha256: "sha256:" + String(repeating: "33", count: 32)
    ),
    buildProvenance: ManagedPythonDownloadIdentity(
        url: "https://example.com/build.json",
        sha256: "sha256:" + String(repeating: "44", count: 32)
    ),
    policyRevision: "test-policy/v1",
    identitySHA256: "sha256:a396aaf9695ae52f7a2f3a8cd4044212eae90f47bf5f4c54fa94ec736ac92846"
)

let managedPythonTestVenvs: [ManagedProductVirtualEnvironmentIdentity] = [
    try! ManagedProductVirtualEnvironmentIdentity(
        componentIdentity: "engineering-platform-server",
        venvIdentity: "ep-test-v1",
        pythonRuntimeIdentitySHA256: managedPythonTestRuntime.identitySHA256
    ),
    try! ManagedProductVirtualEnvironmentIdentity(
        componentIdentity: "forge-runtime",
        venvIdentity: "forge-test-v1",
        pythonRuntimeIdentitySHA256: managedPythonTestRuntime.identitySHA256
    ),
]
