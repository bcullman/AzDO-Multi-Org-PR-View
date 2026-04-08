# PR-actical-Tools

`PR-actical-Tools` is a repo of PowerShell utilities for Azure DevOps pull request workflows.

The first tool in the repo is `PR-ospector.ps1`, a cross-organization pull request dashboard that helps you answer:
- What PRs did I create?
- What PRs are waiting on me?
- What PRs are waiting on one of my reviewer groups?

By default, it reads `config.yml` and only scans the projects you list there.

## Who This Is For
This repo is really only useful for Azure DevOps users. If you do not actively work in Azure DevOps repos and pull requests, this repo probably will not be very helpful.

It is aimed at people who:
- work across multiple Azure DevOps organizations
- need a single view of created and requested-review PRs
- want a lightweight script instead of opening each org and project manually

## Current Tools
- `PR-ospector.ps1`: cross-org PR discovery and dashboarding for created and requested-review pull requests

## `PR-ospector.ps1`
The rest of this README covers how to use `PR-ospector.ps1`.

## Prerequisites
- PowerShell 7 recommended
- Access to the Azure DevOps organizations you want to query
- A Personal Access Token with permission to read pull requests and project metadata
- `ConvertFrom-Yaml` available in your PowerShell session if using `.yml` or `.yaml` config files

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

## Quick Start
1. Copy [sample-config.yml](/mnt/c/source/github/bcullman/AzDO-Multi-Org-PR-View/sample-config.yml) to `config.yml`.
2. Set your Azure DevOps PAT in an environment variable.
3. Add your organizations, PATs, and reviewer groups to `config.yml`.
4. Run the script in discover mode first. For why this is recommended, see [Performance Considerations](#performance-considerations):

```powershell
.\PR-ospector.ps1 -Mode Discover
```

5. Review the output. In YAML config mode, `Discover` also writes any newly found `projects:` entries into `config.yml` automatically.
6. After that, run the script normally:

```powershell
.\PR-ospector.ps1
```

By default, the script looks for `config.yml` in the current directory.

If you want to point at a different file:

```powershell
.\PR-ospector.ps1 -ConfigPath .\config.yml
```

## Performance Considerations
Searching all supplied Azure DevOps organizations and projects for PRs assigned to you can take time. To keep normal runs faster, `PR-ospector.ps1` only searches the projects listed in `config.yml`.

That creates a first-run problem if you are not yet sure which projects you are being called out in. `Discover` mode is meant to solve that. It performs an exhaustive project search across each configured organization, finds projects with matching PR activity, and adds those projects to `config.yml` for future configured-mode runs.

In other words, `Discover` is the slower bootstrap pass, and normal configured mode is the faster day-to-day view.

Group discovery is not exhaustive today. The script assumes you will manage the reviewer groups in `config.yml` yourself. A future version may expand discovery for groups as well, but right now `Discover` helps build your project list, not your group list.

## Usage
Set your PAT in PowerShell:

```powershell
$env:PAT_AZDO = "your-pat-here"
```

Then run:

```powershell
.\PR-ospector.ps1
```

Useful options:
- `-ConfigPath .\config.yml` to use a different config file
- `-Mode Discover` to scan all visible projects and write newly found `projects:` entries back into YAML config
- `-View Both` to show both created and requested-review sections
- `-View Created` to show only PRs created by the authenticated user
- `-View ReviewRequested` to show only PRs where review is requested from the authenticated user or configured groups

Direct usage without config is also supported:

```powershell
.\PR-ospector.ps1 -Org org1 -Pat "$env:PAT_AZDO" -Groups AD-Group
```

When `-Org` is provided, the script uses direct parameters instead of `config.yml`.

Normal output is grouped above the org level like this:

```text
CREATED
=======
...

REQUESTED
=========
...
```
