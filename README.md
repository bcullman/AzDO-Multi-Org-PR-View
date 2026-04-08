# AzDO Multi-Org PR View

`Get-AzDOPullDashboard.ps1` scans Azure DevOps pull requests across one or more organizations and shows:
- PRs you created
- PRs where review was requested from you or one of your configured groups

By default, it reads `config.yml` and only scans the projects you list there.

## Prerequisites
- PowerShell 7 recommended
- Access to the Azure DevOps organizations you want to query
- A Personal Access Token with permission to read pull requests and project metadata
- `ConvertFrom-Yaml` available in your PowerShell session if using `.yml` or `.yaml` config files

## Quick Start
1. Copy [sample-config.yml](/mnt/c/source/github/bcullman/AzDO-Multi-Org-PR-View/sample-config.yml) to `config.yml`.
2. Set your Azure DevOps PAT in an environment variable.
3. Add your organizations, PATs, and reviewer groups to `config.yml`.
4. Run discover mode once to find active projects:

```powershell
.\Get-AzDOPullDashboard.ps1 -Mode Discover
```

5. Run the script normally:

```powershell
.\Get-AzDOPullDashboard.ps1
```

By default, the script looks for `config.yml` in the current directory.

If you want to point at a different file:

```powershell
.\Get-AzDOPullDashboard.ps1 -ConfigPath .\config.yml
```

## Config Format
Example:

```yml
organizations:
  - name: org1
    pat: "$env:PAT_AZDO"
    groups:
      - AD-Group
    projects:
      - ProjectA
      - ProjectB

  - name: org2
    pat: pat-as-string
    groups:
      - Another-Group
    projects:
      - SharedPlatform
```

Fields:
- `name`: Azure DevOps organization name
- `pat`: PAT string or environment variable reference like `"$env:PAT_AZDO"`
- `groups`: reviewer groups to match when using requested-review views
- `projects`: projects to scan in normal configured mode

## Usage
Set your PAT in PowerShell:

```powershell
$env:PAT_AZDO = "your-pat-here"
```

Then run:

```powershell
.\Get-AzDOPullDashboard.ps1
```

Useful options:
- `-ConfigPath .\config.yml` to use a different config file
- `-Mode Discover` to scan all visible projects and write newly found `projects:` entries back into YAML config
- `-View Created`, `-View ReviewRequested`, or `-View Both` to control which sections are shown

Direct usage without config is also supported:

```powershell
.\Get-AzDOPullDashboard.ps1 -Org org1 -Pat "$env:PAT_AZDO" -Groups AD-Group
```

When `-Org` is provided, the script uses direct parameters instead of `config.yml`.

## Notes
- In configured mode, organizations without `projects:` are skipped.
- Discover mode only updates `.yml` and `.yaml` config files.
- YAML config support requires `ConvertFrom-Yaml`, and discover mode auto-write also requires `ConvertTo-Yaml`.

## License
MIT. See [LICENSE](/mnt/c/source/github/bcullman/AzDO-Multi-Org-PR-View/LICENSE).

## Files
- [Get-AzDOPullDashboard.ps1](/mnt/c/source/github/bcullman/AzDO-Multi-Org-PR-View/Get-AzDOPullDashboard.ps1)
- [LICENSE](/mnt/c/source/github/bcullman/AzDO-Multi-Org-PR-View/LICENSE)
- [sample-config.yml](/mnt/c/source/github/bcullman/AzDO-Multi-Org-PR-View/sample-config.yml)
