[CmdletBinding(DefaultParameterSetName = 'ConfigPath')]
param(
    [Parameter(ParameterSetName = 'ConfigPath')]
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.yml'),

    [Parameter(Mandatory = $true, ParameterSetName = 'Direct')]
    [string]$Org,

    [Parameter(ParameterSetName = 'Direct')]
    [string]$Pat,

    [ValidateSet('Created', 'ReviewRequested', 'Both')]
    [string]$View = 'Both',

    [ValidateSet('active', 'completed', 'abandoned', 'all')]
    [string]$Status = 'active',

    [ValidateSet('Pending', 'All')]
    [string]$ReviewState = 'Pending',

    [ValidateSet('Configured', 'Discover')]
    [string]$Mode = 'Configured',

    [ValidateSet('Plain', 'Boxed')]
    [string]$Display = 'Plain',

    [Parameter(ParameterSetName = 'Direct')]
    [object[]]$Groups = @()
)

function Format-RelativeTime {
    param([datetime]$DateTime)

    if (-not $DateTime) { return 'unknown' }

    $now=Get-Date
    $span=$now-$DateTime

    if ($span.TotalSeconds -lt 0) {
        $span=$DateTime-$now

        if ($span.TotalMinutes -lt 1) { return 'in moments' }

        if ($span.TotalHours -lt 1) { return "in $([math]::Max(1,[math]::Floor($span.TotalMinutes)))m" }

        if ($span.TotalDays -lt 1) { return "in $([math]::Max(1,[math]::Floor($span.TotalHours)))h" }

        return "in $([math]::Max(1,[math]::Floor($span.TotalDays)))d"
    }

    if ($span.TotalMinutes -lt 1) { return 'just now' }

    if ($span.TotalHours -lt 1) { return "$([math]::Floor($span.TotalMinutes))m ago" }

    if ($span.TotalDays -lt 1) { return "$([math]::Floor($span.TotalHours))h ago" }

    if ($span.TotalDays -lt 30) { return "$([math]::Floor($span.TotalDays))d ago" }

    if ($span.TotalDays -lt 365) { return "$([math]::Floor($span.TotalDays/30))mo ago" }

    "$([math]::Floor($span.TotalDays/365))y ago"
}

function Format-AzDOReviewStatus {
    param([AllowNull()][string]$Status)

    if ([string]::IsNullOrWhiteSpace($Status)) { return $Status }

    $reset="$([char]27)[0m"
    $color=switch ($Status) {
        'Approved' { "$([char]27)[32m"; break }
        'Approved with suggestions' { "$([char]27)[32m"; break }
        'Needs review' { "$([char]27)[33m"; break }
        'Waiting for author' { "$([char]27)[33m"; break }
        'Re-review needed' { "$([char]27)[33m"; break }
        'Draft' { "$([char]27)[33m"; break }
        'Rejected' { "$([char]27)[31m"; break }
        'Declined' { "$([char]27)[31m"; break }
        default { $null }
    }

    if ($PSStyle) {
        $reset=$PSStyle.Reset
        $color=switch ($Status) {
            'Approved' { $PSStyle.Foreground.Green; break }
            'Approved with suggestions' { $PSStyle.Foreground.Green; break }
            'Needs review' { $PSStyle.Foreground.Yellow; break }
            'Waiting for author' { $PSStyle.Foreground.Yellow; break }
            'Re-review needed' { $PSStyle.Foreground.Yellow; break }
            'Draft' { $PSStyle.Foreground.Yellow; break }
            'Rejected' { $PSStyle.Foreground.Red; break }
            'Declined' { $PSStyle.Foreground.Red; break }
            default { $null }
        }
    }

    if ($null -eq $color) { return $Status }

    "$color$Status$reset"
}

function ConvertTo-AzDOPlainText {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) { return '' }

    $pattern=[regex]::Escape([string][char]27)+'\[[0-9;]*m'
    [regex]::Replace($Text,$pattern,'')
}

function Get-AzDOTerminalWidth {
    try {
        $width=$Host.UI.RawUI.WindowSize.Width

        if ($width -ge 40) { return [int]$width }
    } catch {}

    100
}

function Split-AzDOWrappedText {
    param(
        [AllowNull()][string]$Text,
        [int]$Width
    )

    if ($Width -lt 8) { return @([string]$Text) }

    $value=[string]$Text

    if ([string]::IsNullOrWhiteSpace($value)) { return @('') }

    $lines=[System.Collections.Generic.List[string]]::new()

    foreach ($paragraph in ($value -split "`r?`n")) {
        $remaining=$paragraph.Trim()

        if ([string]::IsNullOrEmpty($remaining)) {
            $lines.Add('') | Out-Null
            continue
        }

        while ($remaining.Length -gt $Width) {
            $breakIndex=$remaining.LastIndexOf(' ', [Math]::Min($Width, $remaining.Length - 1), $Width)

            if ($breakIndex -lt 1) { $breakIndex=$Width }

            $lines.Add($remaining.Substring(0, $breakIndex).TrimEnd()) | Out-Null
            $remaining=$remaining.Substring($breakIndex).TrimStart()
        }

        $lines.Add($remaining) | Out-Null
    }

    $lines.ToArray()
}

function Format-AzDOBox {
    param(
        [string]$Title,
        [string[]]$Lines,
        [int]$Width
    )

    $innerWidth=[Math]::Max(20, $Width - 2)
    $topLeft=[char]0x250C
    $topRight=[char]0x2510
    $bottomLeft=[char]0x2514
    $bottomRight=[char]0x2518
    $horizontal=[char]0x2500
    $vertical=[char]0x2502
    $label=" $Title "
    $topFill=[string]$horizontal * [Math]::Max(0, $innerWidth - $label.Length)
    $top="$topLeft$label$topFill$topRight"
    $bottom="$bottomLeft$([string]$horizontal * $innerWidth)$bottomRight"

    $body=@(
        foreach ($line in @($Lines)) {
            $content=" $line"
            $plain=ConvertTo-AzDOPlainText $content
            $padding=' ' * [Math]::Max(0, $innerWidth - $plain.Length)
            "$vertical$content$padding$vertical"
        }
    )

    @($top) + $body + @($bottom) -join [Environment]::NewLine
}

function Get-AzDOSectionBoxLines {
    param(
        [object[]]$Records,
        [int]$InnerWidth
    )

    $lines=[System.Collections.Generic.List[string]]::new()
    $styles=Get-AzDOThemeStyles

    foreach ($record in @($Records)) {
        $status=[string]$record.ReviewStatus
        $plainMeta=if ([string]::IsNullOrWhiteSpace($status)) {
            "$(Format-RelativeTime $record.CreationDate) by $($record.CreatedBy)"
        } else {
            "$(Format-RelativeTime $record.CreationDate) by $($record.CreatedBy)"
        }

        $metaLines=@(Split-AzDOWrappedText -Text $plainMeta -Width $InnerWidth)

        if ($metaLines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($status)) {
            $metaLines[0]="$(Format-AzDOReviewStatus -Status $status) $($styles.Dim)$($metaLines[0])$($styles.Reset)"
        } elseif ($metaLines.Count -gt 0) {
            $metaLines[0]="$($styles.Dim)$($metaLines[0])$($styles.Reset)"
        }

        for ($i=1; $i -lt $metaLines.Count; $i++) {
            $metaLines[$i]="$($styles.Dim)$($metaLines[$i])$($styles.Reset)"
        }

        foreach ($line in $metaLines) {
            $lines.Add($line) | Out-Null
        }

        foreach ($line in @(Split-AzDOWrappedText -Text "[#$($record.PullRequestId)] $($record.Title)" -Width $InnerWidth)) {
            $lines.Add("$($styles.Blue)$line$($styles.Reset)") | Out-Null
        }

        foreach ($line in @(Split-AzDOWrappedText -Text $record.PRUrl -Width $InnerWidth)) {
            $lines.Add("$($styles.Purple)$($styles.Underline)$line$($styles.Reset)") | Out-Null
        }

        $lines.Add('') | Out-Null
    }

    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
        $lines.RemoveAt($lines.Count - 1)
    }

    $lines.ToArray()
}

function Format-AzDOOutput {
    param(
        [string]$Section,
        [object]$Record,
        [object[]]$Records,
        [ValidateSet('Plain','Boxed')]
        [string]$Display='Plain',
        [int]$Width=100
    )

    if ($Section) {
        $title=switch($Section) {
            'Created' { 'CREATED' }
            'ReviewRequested' { 'REQUESTED' }
            default { $Section.ToUpperInvariant() }
        }

        if ($Display -eq 'Boxed') {
            $boxWidth=[Math]::Max(40, [Math]::Min($Width, 140))
            $lines=Get-AzDOSectionBoxLines -Records $Records -InnerWidth ($boxWidth - 2)
            return Format-AzDOBox -Title $title -Lines $lines -Width $boxWidth
        }

        $blue="$([char]27)[36m"
        $reset="$([char]27)[0m"

        if ($PSStyle) {
            $blue=$PSStyle.Foreground.Cyan
            $reset=$PSStyle.Reset
        }

        return @(
            "$blue$title$reset"
            "$blue$('='*$title.Length)$reset"
        ) -join [Environment]::NewLine
    }

    if ($Display -eq 'Boxed') {
        return $null
    }

    $styles=Get-AzDOThemeStyles

    @(
        "$(Format-AzDOReviewStatus -Status $Record.ReviewStatus) $($styles.Dim)$(Format-RelativeTime $Record.CreationDate) by $($Record.CreatedBy)$($styles.Reset)"
        "$($styles.Blue)[#$($Record.PullRequestId)] $($Record.Title)$($styles.Reset)"
        "$($styles.Purple)$($styles.Underline)$($Record.PRUrl)$($styles.Reset)"
        ''
    ) -join [Environment]::NewLine
}

function Get-AzDOThemeStyles {
    $styles=[ordered]@{
        Dim=''
        Blue="$([char]27)[36m"
        Purple="$([char]27)[35m"
        Underline=''
        Reset="$([char]27)[0m"
    }

    if ($PSStyle) {
        $styles.Dim=$PSStyle.Dim
        $styles.Blue=$PSStyle.Foreground.Cyan
        $styles.Purple=$PSStyle.Foreground.Magenta
        $styles.Underline=$PSStyle.Underline
        $styles.Reset=$PSStyle.Reset
    }

    [pscustomobject]$styles
}

function Get-AzDOComparable {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }

    $text=[string]$Value

    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    $text.Trim().ToLowerInvariant()
}

function Get-AzDOIdentityPropertyValue {
    param(
        [object]$Identity,
        [string]$PropertyName
    )

    if ($null -eq $Identity) { return $null }

    $propertiesProperty=$Identity.PSObject.Properties['properties']

    if ($null -eq $propertiesProperty -or $null -eq $propertiesProperty.Value) { return $null }

    $identityProperties=$propertiesProperty.Value
    $requestedProperty=$identityProperties.PSObject.Properties[$PropertyName]

    if ($null -eq $requestedProperty -or $null -eq $requestedProperty.Value) { return $null }

    $requestedValueProperty=$requestedProperty.Value.PSObject.Properties['value']

    if ($null -eq $requestedValueProperty) { return $null }

    $requestedValueProperty.Value
}

function Get-AzDOConfigCollection {
    param(
        [string]$ConfigPath,
        [string]$Org,
        [string]$Pat,
        [object[]]$Groups,
        [bool]$IsDirect
    )

    if ($IsDirect) {
        return @(
            [pscustomobject]@{
                Name = $Org;
                Pat = $Pat;
                Enabled = $true;
                Groups = @(@($Groups) | Where-Object {-not [string]::IsNullOrWhiteSpace([string]$_)});
                Projects = @();
                FromConfig = $false
            }
        )
    }

    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Config file '$ConfigPath' does not exist." }

    $ext=[IO.Path]::GetExtension($ConfigPath).ToLowerInvariant()

    $parsed=switch($ext) {
        '.json' {
            Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -Depth 100
            break
        }

        '.psd1' {
            Import-PowerShellDataFile -Path $ConfigPath
            break
        }

        {$_ -in '.yml', '.yaml'} {
            if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
                throw "YAML config requires ConvertFrom-Yaml to be available in this PowerShell session."
            }

            Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Yaml
            break
        }

        default {
            throw "Unsupported config file extension '$ext'. Supported extensions are .json, .psd1, .yml, and .yaml."
        }
    }

    $orgs=if ($parsed.organizations) {
        @($parsed.organizations)
    } elseif ($parsed -is [System.Collections.IEnumerable] -and $parsed -isnot [string]) {
        @($parsed)
    } else {
        @($parsed)
    }

    @(
        $orgs | ForEach-Object {
            [pscustomobject]@{
                Name = if ($_.name) { $_.name } else { $_.org };
                Pat = $_.pat;
                Enabled = if ($null -ne $_.enabled) { [bool]$_.enabled } else { $true };
                Groups = @(@($_.groups) | Where-Object {-not [string]::IsNullOrWhiteSpace([string]$_)});
                Projects = @(@($_.projects) | Where-Object {-not [string]::IsNullOrWhiteSpace([string]$_)});
                FromConfig = $true
            }
        }
    )
}

function Resolve-AzDOPat {
    param(
        [object]$PatSpec,
        [string]$OrganizationName
    )

    if ($PatSpec -is [string] -and -not [string]::IsNullOrWhiteSpace($PatSpec)) {
        if ($PatSpec -match '^(?:\$env:|env:)(.+)$') {
            $PatSpec=[pscustomobject]@{ env = $Matches[1] }
        } else {
            return $PatSpec
        }
    }

    if ($PatSpec.value) { return $PatSpec.value }

    if ($PatSpec.env) {
        $token=[Environment]::GetEnvironmentVariable($PatSpec.env)

        if ([string]::IsNullOrWhiteSpace($token)) {
            throw "PAT environment variable '$($PatSpec.env)' was not found or was empty for organization '$OrganizationName'."
        }

        return $token
    }

    throw "No PAT was provided for organization '$OrganizationName'. Supply -Pat or configure pat."
}

function Invoke-AzDOGet {
    param(
        [string]$Uri,
        [hashtable]$Headers
    )

    Invoke-RestMethod -Uri $Uri -Headers $Headers -Method Get
}

function Resolve-AzDOReviewerGroups {
    param(
        [string]$OrganizationName,
        [hashtable]$Headers,
        [object[]]$ConfiguredGroups
    )

    $resolved=[System.Collections.Generic.List[object]]::new()

    foreach ($group in @($ConfiguredGroups)) {
        $groupName=[string]$group

        if ([string]::IsNullOrWhiteSpace($groupName)) { continue }

        $identityMatches=@(
            (Invoke-AzDOGet -Uri "https://vssps.dev.azure.com/$OrganizationName/_apis/identities?searchFilter=General&filterValue=$([Uri]::EscapeDataString($groupName))&queryMembership=None&api-version=7.1-preview.1" -Headers $Headers).value
        )

        $needle=Get-AzDOComparable $groupName
        $best=$null

        foreach ($match in $identityMatches) {
            $candidates=@(
                Get-AzDOComparable $match.providerDisplayName
                Get-AzDOComparable $match.customDisplayName
                Get-AzDOComparable (Get-AzDOIdentityPropertyValue $match 'Account')
                Get-AzDOComparable (Get-AzDOIdentityPropertyValue $match 'Mail')
            ) | Where-Object {$_}

            if ($candidates -contains $needle) {
                $best=$match
                break
            }
        }

        if ($null -eq $best -and $identityMatches.Count -gt 0) {
            $best=$identityMatches[0]
        }

        if ($null -eq $best) {
            Write-Information "Configured group '$groupName' could not be resolved in organization '$OrganizationName'. Group review matching will fall back to generic reviewer data only."
            $resolved.Add([pscustomobject]@{
                Name = $groupName;
                Id = $null
            }) | Out-Null
            continue
        }

        $resolved.Add([pscustomobject]@{
            Name = $groupName;
            Id = $best.id
        }) | Out-Null
    }

    $resolved.ToArray()
}

function New-AzDORecord {
    param(
        [string]$OrganizationName,
        [string]$ProjectName,
        [object]$PullRequest,
        [string]$View,
        [string]$MatchedUser,
        [string]$MatchedGroup,
        [string]$Reviewer
    )

    $repo=[Uri]::EscapeDataString($PullRequest.repository.name)
    $projectPath=[Uri]::EscapeDataString($ProjectName)
    $url="https://dev.azure.com/$OrganizationName/$projectPath/_git/$repo/pullrequest/$($PullRequest.pullRequestId)"

    [pscustomobject]@{
        OrganizationName=$OrganizationName;
        ProjectName=$ProjectName;
        RepositoryName=$PullRequest.repository.name;
        PullRequestId=$PullRequest.pullRequestId;
        Title=$PullRequest.title;
        Status=$PullRequest.status;
        CreatedBy=$PullRequest.createdBy.displayName;
        CreationDate=if ($PullRequest.creationDate) {[datetime]$PullRequest.creationDate} else {$null};
        Url=$url;
        PRUrl=$url;
        ApiUrl=$PullRequest.url;
        SourceBranch=$PullRequest.sourceRefName;
        TargetBranch=$PullRequest.targetRefName;
        View=$View;
        MatchedUser=$MatchedUser;
        MatchedGroup=$MatchedGroup;
        Mention=$null;
        Reviewer=$Reviewer;
        ReviewStatus=$null;
        ReviewerVote=$null
    }
}

function Get-AzDOReviewerVote {
    param([object]$Reviewer)

    if ($null -eq $Reviewer) { return $null }

    $voteProperty=$Reviewer.PSObject.Properties['vote']

    if ($null -ne $voteProperty -and $null -ne $voteProperty.Value) {
        return [int]$voteProperty.Value
    }

    $votes=@(
        @($Reviewer.votedFor) |
            ForEach-Object {
                $memberVoteProperty=$_.PSObject.Properties['vote']

                if ($null -ne $memberVoteProperty -and $null -ne $memberVoteProperty.Value) {
                    [int]$memberVoteProperty.Value
                }
            } |
            Where-Object { $null -ne $_ }
    )

    if ($votes.Count -eq 0) { return $null }

    $nonZeroVote=@($votes | Where-Object { $_ -ne 0 } | Select-Object -First 1)

    if ($nonZeroVote.Count -gt 0) { return [int]$nonZeroVote[0] }

    if ($votes -contains 0) { return 0 }

    $votes[0]
}

function Get-AzDOReviewerStatus {
    param([object]$Reviewer)

    if ($null -eq $Reviewer) {
        return [pscustomobject]@{
            Status = 'Unknown';
            Vote = $null;
            IsActionable = $false
        }
    }

    $vote=Get-AzDOReviewerVote -Reviewer $Reviewer
    $candidates=@($Reviewer) + @($Reviewer.votedFor)
    $hasDeclined=$false
    $isFlagged=$false
    $isReapprove=$false

    foreach ($candidate in @($candidates | Where-Object { $null -ne $_ })) {
        if ($candidate.hasDeclined -eq $true) { $hasDeclined=$true }
        if ($candidate.isFlagged -eq $true) { $isFlagged=$true }
        if ($candidate.isReapprove -eq $true) { $isReapprove=$true }
    }

    $status=switch ($vote) {
        { $hasDeclined } { 'Declined'; break }
        { $_ -eq $null -or $_ -eq 0 } { 'Needs review'; break }
        -5 { 'Waiting for author'; break }
        -10 { 'Rejected'; break }
        5 {
            if ($isReapprove -or $isFlagged) { 'Re-review needed' } else { 'Approved with suggestions' }
            break
        }
        10 {
            if ($isReapprove -or $isFlagged) { 'Re-review needed' } else { 'Approved' }
            break
        }
        default { "Vote $vote" }
    }

    [pscustomobject]@{
        Status = $status;
        Vote = $vote;
        IsActionable = $status -in @('Needs review','Waiting for author','Re-review needed')
    }
}

function Get-AzDOPullRequestReviewStatus {
    param(
        [object]$PullRequest,
        [object]$AuthenticatedUser
    )

    if ($PullRequest.isDraft -eq $true) {
        return [pscustomobject]@{
            Status = 'Draft';
            Vote = $null
        }
    }

    $reviewers=@(
        @($PullRequest.reviewers) |
            Where-Object {
                $_ -and
                $_.id -and
                (-not $AuthenticatedUser.Id -or [string]$_.id -ne [string]$AuthenticatedUser.Id)
            }
    )

    if ($reviewers.Count -eq 0) {
        return [pscustomobject]@{
            Status = 'No reviewers';
            Vote = $null
        }
    }

    $statuses=@($reviewers | ForEach-Object { Get-AzDOReviewerStatus -Reviewer $_ })
    $statusNames=@($statuses.Status)

    $aggregate=switch ($true) {
        { $statusNames -contains 'Rejected' } { 'Rejected'; break }
        { $statusNames -contains 'Re-review needed' } { 'Re-review needed'; break }
        { $statusNames -contains 'Waiting for author' } { 'Waiting for author'; break }
        { $statusNames -contains 'Needs review' } { 'Needs review'; break }
        { $statusNames -contains 'Approved with suggestions' } { 'Approved with suggestions'; break }
        { $statusNames -contains 'Approved' } { 'Approved'; break }
        { $statusNames -contains 'Declined' } { 'Declined'; break }
        default { ($statusNames | Select-Object -First 1) }
    }

    [pscustomobject]@{
        Status = $aggregate;
        Vote = $null
    }
}

function Get-AzDOCreatedRecords {
    param(
        [string]$OrganizationName,
        [string]$ProjectName,
        [hashtable]$Headers,
        [object]$AuthenticatedUser,
        [string]$Status
    )

    $results=[System.Collections.Generic.List[object]]::new()
    $uri="https://dev.azure.com/$OrganizationName/$([Uri]::EscapeDataString($ProjectName))/_apis/git/pullrequests?searchCriteria.status=$([Uri]::EscapeDataString($Status))&api-version=7.1&searchCriteria.creatorId=$([Uri]::EscapeDataString($AuthenticatedUser.Id))"

    foreach ($pr in @((Invoke-AzDOGet -Uri $uri -Headers $Headers).value)) {
        $record=New-AzDORecord -OrganizationName $OrganizationName -ProjectName $ProjectName -PullRequest $pr -View 'Created' -MatchedUser $AuthenticatedUser.Name
        $reviewStatus=Get-AzDOPullRequestReviewStatus -PullRequest $pr -AuthenticatedUser $AuthenticatedUser
        $record.ReviewStatus=$reviewStatus.Status
        $record.ReviewerVote=$reviewStatus.Vote
        $results.Add($record) | Out-Null
    }

    $results.ToArray()
}

function Get-AzDORequestedReviewRecords {
    param(
        [string]$OrganizationName,
        [string]$ProjectName,
        [hashtable]$Headers,
        [object]$AuthenticatedUser,
        [string]$Status,
        [object[]]$ResolvedGroups,
        [string]$ReviewState
    )

    $results=@{}
    $me=Get-AzDOComparable $AuthenticatedUser.Name

    $targets=@(
        if ($AuthenticatedUser.Id) {
            [pscustomobject]@{
                Id=$AuthenticatedUser.Id;
                Name=$AuthenticatedUser.Name;
                Kind='User'
            }
        }

        @($ResolvedGroups) | Where-Object Id | ForEach-Object {
            [pscustomobject]@{
                Id=$_.Id;
                Name=$_.Name;
                Kind='Group'
            }
        }
    )

    foreach ($target in $targets) {
        $uri="https://dev.azure.com/$OrganizationName/$([Uri]::EscapeDataString($ProjectName))/_apis/git/pullrequests?searchCriteria.status=$([Uri]::EscapeDataString($Status))&api-version=7.1&searchCriteria.reviewerId=$([Uri]::EscapeDataString($target.Id))"

        foreach ($pr in @((Invoke-AzDOGet -Uri $uri -Headers $Headers).value)) {
            $creatorId=[string]$pr.createdBy.id
            $creatorName=Get-AzDOComparable $pr.createdBy.displayName

            if (($AuthenticatedUser.Id -and $creatorId -eq $AuthenticatedUser.Id) -or ($me -and $creatorName -eq $me)) {
                continue
            }

            $matched=@($pr.reviewers) | Where-Object {$_.id -eq $target.Id} | Select-Object -First 1

            if (-not $matched) { continue }

            $reviewStatus=Get-AzDOReviewerStatus -Reviewer $matched

            if ($pr.isDraft -eq $true) {
                $reviewStatus=[pscustomobject]@{
                    Status = 'Draft';
                    Vote = $null;
                    IsActionable = $true
                }
            }

            if ($ReviewState -eq 'Pending' -and -not $reviewStatus.IsActionable) {
                continue
            }

            if ($results.ContainsKey($pr.pullRequestId)) { continue }

            $record=New-AzDORecord `
                -OrganizationName $OrganizationName `
                -ProjectName $ProjectName `
                -PullRequest $pr `
                -View 'ReviewRequested' `
                -MatchedUser $(if ($target.Kind -eq 'User') {$target.Name} else {$null}) `
                -MatchedGroup $(if ($target.Kind -eq 'Group') {$target.Name} else {$null}) `
                -Reviewer $(if ($matched -and $matched.displayName) {$matched.displayName} else {$target.Name})

            $record.ReviewStatus=$reviewStatus.Status
            $record.ReviewerVote=$reviewStatus.Vote
            $results[$pr.pullRequestId]=$record
        }
    }

    @($results.Values | Sort-Object CreationDate -Descending)
}

function Get-AzDOProjectViewRecords {
    param(
        [string]$OrganizationName,
        [string]$ProjectName,
        [hashtable]$Headers,
        [object]$AuthenticatedUser,
        [string]$View,
        [string]$Status,
        [object[]]$ResolvedGroups,
        [string]$ReviewState
    )

    switch($View) {
        'Created' {
            @(Get-AzDOCreatedRecords -OrganizationName $OrganizationName -ProjectName $ProjectName -Headers $Headers -AuthenticatedUser $AuthenticatedUser -Status $Status)
        }

        'ReviewRequested' {
            @(Get-AzDORequestedReviewRecords -OrganizationName $OrganizationName -ProjectName $ProjectName -Headers $Headers -AuthenticatedUser $AuthenticatedUser -Status $Status -ResolvedGroups $ResolvedGroups -ReviewState $ReviewState)
        }

        'Both' {
            @(
                @(Get-AzDOCreatedRecords -OrganizationName $OrganizationName -ProjectName $ProjectName -Headers $Headers -AuthenticatedUser $AuthenticatedUser -Status $Status) +
                @(Get-AzDORequestedReviewRecords -OrganizationName $OrganizationName -ProjectName $ProjectName -Headers $Headers -AuthenticatedUser $AuthenticatedUser -Status $Status -ResolvedGroups $ResolvedGroups -ReviewState $ReviewState)
            )
        }
    }
}

function Get-AzDOProjectResult {
    param(
        [string]$OrganizationName,
        [object]$Project,
        [hashtable]$Headers,
        [object]$AuthenticatedUser,
        [string]$View,
        [string]$Status,
        [object[]]$ResolvedGroups,
        [string]$ReviewState
    )

    $start=Get-Date

    try{
        $records=@(
            Get-AzDOProjectViewRecords -OrganizationName $OrganizationName -ProjectName $Project.name -Headers $Headers -AuthenticatedUser $AuthenticatedUser -View $View -Status $Status -ResolvedGroups $ResolvedGroups -ReviewState $ReviewState
        )

        $end=Get-Date

        [pscustomobject]@{
            OrganizationName=$OrganizationName;
            ProjectName=$Project.name;
            Records=$records;
            ErrorMessage=$null;
            StartTime=$start;
            EndTime=$end;
            DurationSeconds=($end-$start).TotalSeconds
        }
    }catch{
        $end=Get-Date

        [pscustomobject]@{
            OrganizationName=$OrganizationName;
            ProjectName=$Project.name;
            Records=@();
            ErrorMessage=$_.Exception.Message;
            StartTime=$start;
            EndTime=$end;
            DurationSeconds=($end-$start).TotalSeconds
        }
    }
}

function Update-AzDOConfigFromDiscover {
    param(
        [string]$ConfigPath,
        [hashtable]$DiscoveredProjectsByOrganization
    )

    if ($DiscoveredProjectsByOrganization.Count -eq 0) { return $false }

    $ext=[IO.Path]::GetExtension($ConfigPath).ToLowerInvariant()

    if ($ext -notin '.yml','.yaml') {
        throw "Discover mode can only update YAML config files. Unsupported config extension '$ext'."
    }

    if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue) -or -not (Get-Command ConvertTo-Yaml -ErrorAction SilentlyContinue)) {
        throw "Discover mode YAML updates require both ConvertFrom-Yaml and ConvertTo-Yaml to be available in this PowerShell session."
    }

    $parsed=Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Yaml
    $orgs=if ($parsed.organizations) {@($parsed.organizations)} else {@($parsed)}
    $updated=$false

    foreach ($org in $orgs) {
        $name=if ($org.name) {[string]$org.name} else {[string]$org.org}

        if ([string]::IsNullOrWhiteSpace($name) -or -not $DiscoveredProjectsByOrganization.ContainsKey($name)) {
            continue
        }

        if ($null -ne $org.enabled -and -not [bool]$org.enabled) { continue }

        $existing=[string[]]@(@($org.projects) | Where-Object {-not [string]::IsNullOrWhiteSpace([string]$_)} | ForEach-Object {[string]$_})
        $incoming=[string[]]@(@($DiscoveredProjectsByOrganization[$name]) | Where-Object {-not [string]::IsNullOrWhiteSpace([string]$_)} | ForEach-Object {[string]$_})
        $merged=[string[]]@(@($existing+$incoming) | Sort-Object -Unique)

        if ((@($existing)-join "`n") -eq (@($merged)-join "`n")) { continue }

        $org.projects=$merged
        $updated=$true
    }

    if (-not $updated) { return $false }

    $ordered=@(
        foreach ($org in $orgs) {
            $o=[ordered]@{ name=if ($org.name) {$org.name} else {$org.org} }

            if ($null -ne $org.enabled) { $o.enabled=[bool]$org.enabled }

            if ($null -ne $org.pat) { $o.pat=$org.pat }

            if ($null -ne $org.groups) { $o.groups=[string[]]@(@($org.groups) | ForEach-Object {[string]$_}) }

            if ($null -ne $org.projects) {
                $o.projects=[string[]]@(@($org.projects) | ForEach-Object {[string]$_})
            }

            foreach ($k in $org.Keys | Where-Object {$_ -notin 'name','org','enabled','pat','groups','projects'}) {
                $o[$k]=$org[$k]
            }

            [pscustomobject]$o
        }
    )

    Set-Content -LiteralPath $ConfigPath -Value ([pscustomobject]@{ organizations=$ordered } | ConvertTo-Yaml)
    $true
}

function Get-AzDOPulls {
    [CmdletBinding(DefaultParameterSetName='ConfigPath')]
    param(
        [Parameter(ParameterSetName='ConfigPath')]
        [string]$ConfigPath,

        [Parameter(Mandatory=$true,ParameterSetName='Direct')]
        [string]$Org,

        [Parameter(ParameterSetName='Direct')]
        [string]$Pat,

        [ValidateSet('Created','ReviewRequested','Both')]
        [string]$View='Both',

        [ValidateSet('active','completed','abandoned','all')]
        [string]$Status='active',

        [ValidateSet('Pending','All')]
        [string]$ReviewState='Pending',

        [ValidateSet('Configured','Discover')]
        [string]$Mode='Configured',

        [ValidateSet('Plain','Boxed')]
        [string]$Display='Plain',

        [Parameter(ParameterSetName='Direct')]
        [object[]]$Groups=@()
    )

    if ($PSCmdlet.ParameterSetName -eq 'ConfigPath' -and [string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = $script:ConfigPath
    }

    $configs=Get-AzDOConfigCollection -ConfigPath $ConfigPath -Org $Org -Pat $Pat -Groups $Groups -IsDirect ($PSCmdlet.ParameterSetName -eq 'Direct')
    $allResults=[System.Collections.Generic.List[object]]::new()
    $discovered=@{}
    $discoverLabel=if ($PSCmdlet.ParameterSetName -eq 'ConfigPath') {'Projects added to config'} else {'Projects discovered for config'}

    foreach ($config in $configs) {
        $orgStart=Get-Date
        Write-Verbose "$($orgStart.ToString('o')) Org $($config.Name) started"

        try{
            if (-not $config.Enabled) {
                Write-Information "Skipping organization '$($config.Name)' because it is disabled in config."
                continue
            }

            $token=Resolve-AzDOPat -PatSpec $(if ($Pat) {$Pat} else {$config.Pat}) -OrganizationName $config.Name
            $headers=@{
                Authorization="Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$token")))"
            }

            $me=(Invoke-AzDOGet -Uri "https://dev.azure.com/$($config.Name)/_apis/connectionData?api-version=7.1-preview.1&connectOptions=1" -Headers $headers).authenticatedUser
            $me=[pscustomobject]@{
                Id=$me.id;
                Name=if ($me.customDisplayName) {$me.customDisplayName} else {$me.providerDisplayName}
            }

            $resolved=@(Resolve-AzDOReviewerGroups -OrganizationName $config.Name -Headers $headers -ConfiguredGroups $config.Groups)
            $allProjects=@((Invoke-AzDOGet -Uri "https://dev.azure.com/$($config.Name)/_apis/projects?api-version=7.1-preview.4" -Headers $headers).value)
            $projects=$allProjects

            if ($Mode -eq 'Configured' -and $config.FromConfig) {
                if (@($config.Projects).Count -eq 0) {
                    Write-Information "Skipping organization '$($config.Name)' because Mode is 'Configured' and no projects were configured."
                    continue
                }

                $lookup=@{}
                $allProjects | ForEach-Object {$lookup[$_.name.ToLowerInvariant()]=$_}

                $seen=@{}
                $missing=[System.Collections.Generic.List[string]]::new()
                $selected=[System.Collections.Generic.List[object]]::new()

                foreach ($p in @($config.Projects)) {
                    $name=[string]$p

                    if ([string]::IsNullOrWhiteSpace($name)) { continue }

                    $key=$name.ToLowerInvariant()

                    if ($seen[$key]) { continue }

                    $seen[$key]=$true

                    if ($lookup.ContainsKey($key)) {
                        $selected.Add($lookup[$key]) | Out-Null
                    } else {
                        $missing.Add($name) | Out-Null
                    }
                }

                foreach ($m in $missing) {
                    Write-Information "Configured project '$m' was not found in organization '$($config.Name)'."
                }

                $projects=$selected.ToArray()

                if ($projects.Count -eq 0) {
                    Write-Information "Skipping organization '$($config.Name)' because none of the configured projects were found."
                    continue
                }
            }

            if ($allProjects.Count -eq 0) {
                continue
            }

            $projectResults=[System.Collections.Generic.List[object]]::new()

            foreach ($project in $projects) {
                $r=Get-AzDOProjectResult -OrganizationName $config.Name -Project $project -Headers $headers -AuthenticatedUser $me -View $View -Status $Status -ResolvedGroups $resolved -ReviewState $ReviewState
                $projectResults.Add($r) | Out-Null

                if ($r.ErrorMessage) {
                    Write-Warning "Failed to inspect project '$($r.ProjectName)' in organization '$($r.OrganizationName)': $($r.ErrorMessage)"
                    continue
                }

                Write-Verbose "$($r.StartTime.ToString('o')) Project $($r.OrganizationName)/$($r.ProjectName) started"
                Write-Verbose "$($r.EndTime.ToString('o')) Project $($r.OrganizationName)/$($r.ProjectName) ended"
                Write-Verbose "$($r.EndTime.ToString('o')) Project $($r.OrganizationName)/$($r.ProjectName) processed in $([math]::Round($r.DurationSeconds,2))s"

                if ($Mode -ne 'Discover') {
                    foreach ($record in @($r.Records)) {
                        $allResults.Add($record) | Out-Null
                    }
                }
            }

            if ($Mode -eq 'Discover') {
                $configured=@{}

                foreach ($p in @($config.Projects)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$p)) {
                        $configured[[string]$p.ToLowerInvariant()]=[string]$p
                    }
                }

                $matching=@(@($projectResults.ToArray()) | Where-Object {-not $_.ErrorMessage -and @($_.Records).Count -gt 0} | Sort-Object ProjectName)
                $toAdd=@($matching | Where-Object {-not $configured.ContainsKey($_.ProjectName.ToLowerInvariant())} | Select-Object -ExpandProperty ProjectName)

                if ($toAdd.Count -gt 0) { $discovered[$config.Name]=$toAdd }

                Write-Output (@(
                    "Organization: $($config.Name)"
                    "Configured projects: $(if (@($config.Projects).Count -gt 0) {(@($config.Projects) | Sort-Object) -join ', '} else {'(none)'})"
                    "Projects with matching PRs: $(if ($matching.Count -gt 0) {@($matching | ForEach-Object {"$($_.ProjectName) ($(@($_.Records).Count))"}) -join ', '} else {'(none)'})"
                    "${discoverLabel}: $(if ($toAdd.Count -gt 0) {$toAdd -join ', '} else {'(none)'})"
                    ''
                ) -join [Environment]::NewLine)
            }
        }catch{
            $message="Failed to inspect Azure DevOps organization '$($config.Name)': $($_.Exception.Message)"

            if ($ErrorActionPreference -eq 'Stop') {
                throw $message
            }

            Write-Warning $message
        }finally{
            $orgEnd=Get-Date
            Write-Verbose "$($orgEnd.ToString('o')) Org $($config.Name) ended"
            Write-Verbose "$($orgEnd.ToString('o')) Org $($config.Name) processed in $([math]::Round(($orgEnd-$orgStart).TotalSeconds,2))s"
        }
    }

    if ($Mode -eq 'Discover') {
        if ($PSCmdlet.ParameterSetName -ne 'ConfigPath') {
            if ($discovered.Count -gt 0) {
                Write-Information "Discover mode found projects, but direct parameter-based runs do not update a config file automatically."
            }

            return
        }

        if (Update-AzDOConfigFromDiscover -ConfigPath $ConfigPath -DiscoveredProjectsByOrganization $discovered) {
            Write-Information "Discover mode updated '$ConfigPath' with newly discovered projects."
        }

        return
    }

    $renderWidth=Get-AzDOTerminalWidth

    $sections=@(if ($View -eq 'Both') {'Created','ReviewRequested'} else {$View})

    for ($sectionIndex=0; $sectionIndex -lt $sections.Count; $sectionIndex++) {
        $section=$sections[$sectionIndex]
        $sectionRecords=@(@($allResults.ToArray()) | Where-Object {$_.View -eq $section} | Sort-Object CreationDate -Descending)

        if ($sectionRecords.Count -eq 0) { continue }

        if ($Display -eq 'Boxed') {
            Write-Output (Format-AzDOOutput -Section $section -Records $sectionRecords -Display $Display -Width $renderWidth)
            if ($sectionIndex -lt ($sections.Count - 1)) {
                Write-Output ''
            }
            continue
        }

        Write-Output (Format-AzDOOutput -Section $section -Display $Display -Width $renderWidth)

        foreach ($record in $sectionRecords) {
            Write-Output (Format-AzDOOutput -Record $record -Display $Display -Width $renderWidth)
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Get-AzDOPulls @PSBoundParameters
}
