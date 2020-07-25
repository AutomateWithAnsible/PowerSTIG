#requires -module posh-git
#requires -version 6.0

$script:ReleaseName = "{0}-Release"

<#
    .SYNOPSIS
        Validates that the supplied module version is greater than the current
        version listed in the module manifest.
#>
function Test-ModuleVersion
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [version]
        $ModuleVersion
    )

    $publishedModule = Find-Module PowerStig -Repository PsGallery -Verbose:$false

    if ($ModuleVersion -le $publishedModule.Version)
    {
        return $false
    }

    return $true
}
#region Git

function Invoke-Git
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [string]
        $Command
    )

    Invoke-Expression "git $Command" 2>&1
}

<#
    .SYNOPSIS
        Returns the remote url details of the local git repository. The remote
        url is used to build the return object properties.
#>
function Get-PowerStigRepository
{
    [OutputType([string])]
    [CmdletBinding()]
    param ()

    Write-Host "Testing git is installed"

    $git = Get-Command "git" -ErrorAction SilentlyContinue
    if ($git)
    {
        Write-Verbose "Git is found on the System at $($git.Source)"
    }
    else
    {
        throw "Git was not found on the System. Please install Git and try again"
    }

    Write-Host "Getting remote repository details"

    $gitRemote = Invoke-Git -Command "remote get-url origin"

    $baseUrl = $gitRemote -replace '\.git$', ''
    if ([string]::IsNullOrEmpty($gitRemote) -or
        $gitRemote -notmatch "^https://github.com/Microsoft/PowerStig")
    {
        throw "$gitRemote is not a PowerStig Project. Please select a PowerStig project to release."
    }
    else
    {
        Write-Verbose -Message "Releasing $baseUrl"
    }

    return [ordered]@{
        'name'     = ($baseUrl -split "/")[-1]
        'html_url' = $baseUrl
        'api_url'  = $baseUrl -replace 'github\.com', 'api.github.com/repos'
    }
}

<#
    .SYNOPSIS
        A set companion function to the posh-git Get-GitBranch function.

    .PARAMETER Branch
        The name of the branch to switch to.

    .Parameter SkipPull
        By default the branch remote is pulled as soon as it is swithced into.
        This switch skips the pull step. This normaly just a perf boost.
#>
function Set-GitBranch
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [string]
        $Branch,

        [Parameter()]
        [switch]
        $SkipPull
    )

    $currentBranch = Get-GitBranch

    # If the case is input incorrectly, drop it to lower for dev and master
    if ($Branch -match "dev|master")
    {
        $Branch = $Branch.ToLower()
    }

    if ($currentBranch -ne $Branch)
    {
        Write-Host "Switching to $Branch branch"
        $null = Invoke-Git -Command "checkout $Branch"
    }
    else
    {
        Write-Verbose -Message "Already in $Branch branch"
    }

    if ($SkipPull)
    {
        Write-Verbose -Message "Skipping Pull"
    }
    else
    {
        Write-Verbose -Message "Pulling $Branch branch from origin"
        $null = Invoke-Git -Command "pull"
    }
}

function New-GitReleaseBranch
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [string]
        $BranchName
    )

    if (Get-GitBranch -ne 'dev')
    {
        Set-GitBranch -Branch dev
    }

    Write-Host "Creating Git branch ($BranchName)"

    $branch = Invoke-Git -Command "show-branch $BranchName"

    If ($branch -match "^\[$BranchName\]")
    {
        $null = Invoke-Git -Command "checkout $BranchName"
    }
    else
    {
        $null = Invoke-Git -Command "checkout -b $BranchName dev"
    }
}

function Remove-GitBranch
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [string]
        $BranchName
    )

    Write-Host "Removing Git branch ($BranchName)"

    # Merge the release back into dev
    if (Get-GitBranch -ne 'dev')
    {
        Set-GitBranch -Branch dev
    }

    #Invoke-Git -Command "merge $branchName"
    # Push dev to GitHub
    #Invoke-Git -Command "push"
    # Delete the branch Locally
    Invoke-Git -Command "branch -d $branchName"
    # Push the delete to GitHub
    Invoke-Git -Command "push origin -d $branchName"
    # Remove the origin branch reference from the local repo
    Invoke-Git -Command "remote prune origin"
}

function Push-GitBranch
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [string]
        $Name,

        [Parameter(Mandatory = $true)]
        [string]
        $CommitMessage
    )

    Write-Host "Pushing ($Name) to GitHub."

    $commit = Invoke-Git -Command "commit -a -m '$CommitMessage'"

    if ($commit -match 'Your branch is up to date')
    {
        Write-Host "Nothing to commit or push"
        return
    }
    $null = Invoke-Git -Command "push -u origin $Name"
}
#endregion

#region Update Version and release notes

<#
    .SYNOPSIS
        Get Unreleased content from the changlog
#>
function Get-UnreleasedNotes
{
    [OutputType([string])]
    [CmdletBinding()]
    param
    (
        [Parameter()]
        [string]
        $Branch
    )
    Write-Host "Getting unreleased notes from CHANGELOG."
    $changelogPath = (Get-ChildItem -Path $PWD -Filter "CHANGELOG.md").FullName
    $changelogContent = Get-Content -Path $changelogPath

    $h2 = '^##'
    $unreleasedHeader = "$h2\s+Unreleased"
    $latestedreleaseHeader = "$h2\s+\d\.\d\.\d\.\d"

    $unreleasedLine = $changelogContent | Select-String -Pattern $unreleasedHeader

    $latestedreleaseLine = ($changelogContent |
            Select-String -Pattern $latestedreleaseHeader)[0]

    $releaseNotes = $changelogContent[
        ($unreleasedLine.LineNumber)..($latestedreleaseLine.LineNumber - 2)] |
            Out-String

    return $releaseNotes.Trim()
}

<#
    .SYNOPSIS
        Adds a new version section to the readme released notes or  updates the
        list of contributors to the Contributors section.

    .PARAMETER ModuleVersion
        The module version to add to the readme below the unreleased section

    .PARAMETER Repository
        A hashtable that contains the repository api url to query for the list of contributors
#>
function Update-ReleaseNotes
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true, ParameterSetName = 'ReleaseNotes')]
        [version]
        $ModuleVersion
    )

    Write-Host 'Updating ReleaseNotes'
    $changelogPath = (Get-ChildItem -Path $PWD -Filter "CHANGELOG.md").FullName
    $changelogContent = Get-Content -Path $changelogPath -Raw

    $unreleasedHeaderReplace = New-Object System.Text.StringBuilder
    $null = $unreleasedHeaderReplace.AppendLine('## Unreleased')
    $null = $unreleasedHeaderReplace.AppendLine('')
    $null = $unreleasedHeaderReplace.AppendLine("## $ModuleVersion")

    $changelogContent = $changelogContent -replace '##\sUnreleased',
    $unreleasedHeaderReplace.ToString().Trim()

    Set-Content -Path $changelogPath -Value $changelogContent.Trim()
}

<#
    .SYNOPSIS
        Adds a new version section to the readme released notes or  updates the
        list of contributors to the Contributors section.

    .PARAMETER ModuleVersion
        The module version to add to the readme below the unreleased section

    .PARAMETER Repository
        A hashtable that contains the repository api url to query for the list of contributors
#>
function Update-Contributors
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [hashtable]
        $Repository
    )

    Write-Host 'Updating Contributor List'
    $readmePath = (Get-ChildItem -Path $PWD -Filter "README.md").FullName
    $readmeContent = Get-Content -Path $readmePath -Raw

    $contributorList = Get-ProjectContributorList -Repository $Repository
    $contributorsMd = New-Object System.Text.StringBuilder
    $null = $contributorsMd.AppendLine('')
    $null = $contributorsMd.AppendLine('')

    foreach ($contributor in $contributorList)
    {
        $line = "* [@$($contributor.login)](https://github.com/$($contributor.login))"
        if ($contributor.Name)
        {
            $line = $line + " ($($contributor.Name))"
        }

        $null = $contributorsMd.AppendLine($line)
    }
    $null = $contributorsMd.AppendLine('')

    $readmeContributorsRegEx = '(?<=### Contributors)[^#]+(?=#)'
    $readmeContent = $readmeContent -replace $readmeContributorsRegEx, $contributorsMd.ToString()

    Set-Content -Path $readmePath -Value $readmeContent.Trim()
}

<#
    .SYNOPSIS
        Updates a module manifest version and release notes.

    .PARAMETER ModuleVersion
        The version number to update the manifest with

    .PARAMETER ReleaseNotes
        The release notes to update the manifest with
#>
function Update-Manifest
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [version]
        $ModuleVersion,

        [Parameter(Mandatory = $true)]
        [string]
        $ReleaseNotes,

        [Parameter()]
        [string]
        $ManifestPath
    )

    Write-Host "Updating version number and release notes in module manifest."

    if (-not $ManifestPath)
    {
        $ManifestPath = (Get-ChildItem -Path $PWD -Filter "*.psd1").FullName
    }

    $manifestContent = Get-Content -Path $ManifestPath -Raw
    $moduleVersionRegex = '(?<=ModuleVersion\s*=\s*'')(?<ModuleVersion>.*)(?=''(?!(\s*)}))'
    $manifestContent = $manifestContent -replace $moduleVersionRegex, $ModuleVersion

    $releaseNotesRegEx = "(?<=ReleaseNotes\s*=\s*')[^']+(?=')"

    # If any single quotes are in the release notes, they need to be escaped with another single quote
    $ReleaseNotes = $ReleaseNotes -replace "'","''"

    $manifestContent = $manifestContent -replace $releaseNotesRegEx, $ReleaseNotes

    Set-Content -Path $ManifestPath -Value $manifestContent.TrimEnd()
}

<#
    .SYNOPSIS
        Updates the AppVeyor build configuration yaml file with the module
        version number

    .PARAMETER ModuleVersion
        The version number to update the manifest with
#>
function Update-AppVeyorConfiguration
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [version]
        $ModuleVersion
    )

    Write-Host "Updating appveyor configuration."

    $appveyorPath = (Get-ChildItem -Path $PWD -Filter "appveyor.yml").FullName
    $appveyorContent = Get-Content -Path $appveyorPath
    $regex = 'version\:\s\d\.\d\.\d\.\{build\}'
    $appveyorContent = $appveyorContent -replace $regex,
        "version: $($moduleVersion.major).$($moduleVersion.Minor).$($moduleVersion.Build).{build}"

    Set-Content -Path $appveyorPath -Value $appveyorContent.TrimEnd()
}

#endregion
#region Update Contributor list

<#
    .SYNOPSIS
        Queries the GitHub repo and returns a unique list of users that have
        submitted closed pull requests into the dev branch

    .PARAMETER Repository
        A hashtable that contains the repository api url to query for the list of contributors
#>
function Get-ProjectContributorList
{
    [OutputType([string[]])]
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [hashtable]
        $Repository
    )

    # https://developer.github.com/v3/pulls/#list-pull-requests
    $gitHubReleaseParam = [ordered]@{
        Authentication = 'OAuth'
        Token          = $script:GitHubApiKeySecure
        Uri            = "$($Repository.api_url)/pulls"
        Method         = 'Get'
        Body           = [ordered]@{
            state = 'closed'
            base  = 'dev'
        }
    }
    $pulls = Invoke-RestMethod @gitHubReleaseParam

    [System.Collections.ArrayList]$users = @(($pulls | Select-Object user ).user.login | Select-Object -Unique)

    # There were several contributors before this project was moved to GitHub, so
    # make sure they are given credit along side the contributions from GitHub.
    $preGitHubContributors = @{
        PowerStig    = @('jcwalker', 'regedit32', 'bgouldman', 'mcollera')
        PowerStigDsc = @('jcwalker', 'regedit32', 'bgouldman', 'mcollera')
    }

    foreach ($user in $preGitHubContributors.($Repository.name))
    {
        if ($users -notcontains $user)
        {
            $null = $users.Add($user)
        }
    }

    $contributors = [System.Collections.ArrayList]@()
    foreach ($user in $users)
    {
        # https://developer.github.com/v3/users/#get-a-single-user
        $gitHubReleaseParam = [ordered]@{
            Authentication = 'OAuth'
            Token          = $script:GitHubApiKeySecure
            Uri            = "https://api.github.com/users/$user"
            Method         = 'Get'
        }
        # The GitHub release triggers the AppVeyor deployment to the Gallery.
        $userDetails = Invoke-RestMethod @gitHubReleaseParam

        $null = $contributors.Add($userDetails)
    }

    return $contributors | Sort-Object login
}

#endregion
#region GitHub

function Get-GitHubApiKey
{
    [CmdletBinding()]
    param
    (
        [Parameter(ParameterSetName = 'SecureFile')]
        [AllowNull()]
        [string]
        $SecureFilePath
    )

    if ([string]::IsNullOrEmpty($SecureFilePath))
    {
        $SecureFilePath = "$(Split-Path $profile)\PowerStigGitHubApi.txt"
    }
    elseif (-not (Test-Path -Path $SecureFilePath))
    {
        throw "$SecureFilePath was not found. Please move the secure file here or provide a valid path."
    }

    try
    {
        [System.Security.SecureString] $GitHubKeySecure =
            Get-Content -Path $SecureFilePath | ConvertTo-SecureString
    }
    catch
    {
        throw "Unable to convert $SecureFilePath to a secure string."
    }

    $script:GitHubApiKeySecure = $GitHubKeySecure
}

<#
    .SYNOPSIS
        Get's the status of a branch based on the policies that are applied

    .PARAMETER Repository
        A hashtable that contains the repository api url to query

    .PARAMETER Name
        A SHA, branch name, or tag name to get the status for

    .PARAMETER WaitForSuccess
        A switch that will start a loop that waits for a success status message
        or a 10 minute wait timeout
#>
function Get-GitHubRefStatus
{
    [OutputType([string])]
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [hashtable]
        $Repository,

        [Parameter(Mandatory = $true)]
        [string]
        $Name,

        [Parameter()]
        [switch]
        $WaitForSuccess
    )

    # https://developer.github.com/v3/repos/statuses/#list-statuses-for-a-specific-ref
    $restParameters = [ordered]@{
        'Authentication' = 'OAuth'
        'Token'          = $script:GitHubApiKeySecure
        'Uri'            = "$($Repository.api_url)/commits/$Name/status"
        'Method'         = 'Get'
        'Verbose'        = $false
    }

    [int] $i = 0
    [int] $waitCounter = 30
    [int] $waitSeconds = 30
    do
    {
        $response = (Invoke-RestMethod @restParameters).state

        if ($response -eq 'pending')
        {
            if (-not $WaitForSuccess)
            {
                return $response
            }
            Write-Host "$Name is in a pending state, starting sleep (30 seconds)."
            Start-Sleep -Seconds $waitSeconds
            $i ++
        }
        elseif ($response -eq 'failure')
        {
            return $response
        }
        else
        {
            return $response
        }
    }
    until ($response.state -eq 'success' -or $i -ge $waitCounter )

    throw "Timeout $([timespan]::fromseconds($waitCounter*$waitSeconds))"
}

<#
    .SYNOPSIS
        Create a Pull request on GitHub with the provided branch head that is
        merging into the branch base.

#>
function New-GitHubPullRequest
{
    [OutputType([PSObject])]
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [hashtable]
        $Repository,

        [Parameter(Mandatory = $true)]
        [version]
        $ModuleVersion,

        [Parameter()]
        [string]
        $Title = "Release of version $ModuleVersion.",

        [Parameter()]
        [string]
        $Body = "Release version $ModuleVersion.",

        [Parameter(Mandatory = $true)]
        [string]
        $BranchHead,

        [Parameter()]
        [string]
        $BranchBase = 'master'
    )

    # https://developer.github.com/v3/pulls/#create-a-pull-request
    $restMethodParamList = [ordered]@{
        Authentication = 'OAuth'
        Token          = $script:GitHubApiKeySecure
        Uri            = "$($Repository.api_url)/pulls"
        Method         = 'Post'
        Body           = [ordered]@{
            title = $Title
            body  = $Body
            head  = $BranchHead
            base  = $BranchBase
        } | ConvertTo-Json
    }

    Invoke-RestMethod @restMethodParamList
}

function Get-GitHubPullRequest
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true, ParameterSetName = 'one')]
        [Parameter(Mandatory = $true, ParameterSetName = 'all')]
        [hashtable]
        $Repository,

        [Parameter(Mandatory = $true, ParameterSetName = 'one')]
        [int]
        $Number,

        [Parameter(Mandatory = $true, ParameterSetName = 'all')]
        [string]
        $BranchHead,

        [Parameter(Mandatory = $true, ParameterSetName = 'all')]
        [string]
        $BranchBase
    )

    # https://developer.github.com/v3/pulls/#list-pull-requests
    $pullRequestParams = @{
        Authentication = 'OAuth'
        Token          = $script:GitHubApiKeySecure
        Method         = 'Get'
        Uri            = "$($Repository.api_url)/pulls"
    }

    If ($PSCmdlet.ParameterSetName -eq 'one')
    {
        # https://developer.github.com/v3/pulls/#get-a-single-pull-request
        $pullRequestParams.Uri = $pullRequestParams.Uri + "/$Number"
        return Invoke-RestMethod @pullRequestParams
    }

    $prList = Invoke-RestMethod @pullRequestParams

    return $prList | Where-Object {
        $PSItem.head.ref -eq $BranchHead -and
        $PSItem.base.ref -eq $BranchBase
    }
}

function Approve-GitHubPullRequest
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [psobject]
        $PullRequest,

        [Parameter(Mandatory = $true)]
        [string]
        $CommitTitle,

        [Parameter(Mandatory = $true)]
        [string]
        $CommitMessage,

        [Parameter()]
        [ValidateSet('merge', 'squash', 'rebase')]
        [string]
        $MergeMethod = 'merge'
    )

    # https://developer.github.com/v3/pulls/#merge-a-pull-request-merge-button
    $restMethodParam = [ordered]@{
        Authentication = 'OAuth'
        Token          = $script:GitHubApiKeySecure
        Uri            = "$($PullRequest.url)/merge"
        Method         = 'Put'
        Body           = [ordered]@{
            commit_title   = $CommitTitle
            commit_message = $CommitMessage
            sha            = $PullRequest.head.sha
            merge_method   = $MergeMethod.ToLower()
        } | ConvertTo-Json
    }

    Invoke-RestMethod @restMethodParam
}

function New-GitHubRelease
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [hashtable]
        $Repository,

        [Parameter(Mandatory = $true)]
        [string]
        $TagName,

        [Parameter(Mandatory = $true)]
        [string]
        $Title,

        [Parameter(Mandatory = $true)]
        [string]
        $Description,

        [Parameter()]
        [bool]
        $Draft,

        [Parameter()]
        [bool]
        $Prerelease
    )

    # https://developer.github.com/v3/repos/releases/#create-a-release
    $restMethodParam = [ordered]@{
        Authentication = 'OAuth'
        Token          = $script:GitHubApiKeySecure
        Uri            = "$($Repository.api_url)/releases"
        Method         = 'Post'
        Body           = [ordered]@{
            tag_name         = $TagName
            target_commitish = 'master'
            name             = $Title
            body             = $Description
            draft            = $Draft
            prerelease       = $Prerelease
        } | ConvertTo-Json
    }

    Invoke-RestMethod @restMethodParam
}

<#
    .SYNOPSIS
        Sets a markdown file which contains PowerSTIG file hashes.

    .DESCRIPTION
        Used to set a markdown file with file hashes for PowerSTIG
        module files, such as Processed STIG Data, etc.

    .PARAMETER FileHashPath
        Specifies the path to one or more files as an array to generate file
        hash data. Wildcard characters are permitted.

    .PARAMETER MarkdownPath
        Specifies the path for the markdown file.

    .PARAMETER Algorithm
        Specifies the cryptographic hash function to use for computing the hash
        value of the contents of the specified file. A cryptographic hash function
        includes the property that it is not possible to find two distinct inputs
        that generate the same hash values. Hash functions are commonly used with
        digital signatures and for data integrity.

        The acceptable values for this parameter are:
        'SHA256', 'SHA384' or 'SHA512'
#>
function Update-FileHashMarkdown
{
    [CmdletBinding()]
    param
    (
        [Parameter()]
        [string[]]
        $FileHashPath = (Join-Path -Path $PWD -ChildPath 'source\StigData\Processed\*.xml'),

        [Parameter()]
        [string]
        $MarkdownPath = (Join-Path -Path $PWD -ChildPath '\FILEHASH.md'),

        [Parameter()]
        [ValidateSet('SHA256', 'SHA384', 'SHA512')]
        [string]
        $Algorithm = 'SHA256',

        [Parameter(Mandatory = $true)]
        [string]
        $ModuleVersion
    )

    # Markdown header for file hash information table
    $markdownHeader = @'
# PowerSTIG File Hashes : Module Version {0}

Hashes for **PowerSTIG** files are listed in the following table:

| File | {1} Hash | Size (bytes) |
| :---- | ---- | ---: |
'@ -f $ModuleVersion, $Algorithm

    $fileHash = Get-FileHash -Path $FileHashPath -Algorithm $Algorithm

    # String builder to set the markdown file
    $fileHashMarkdownFileContent = New-Object System.Text.StringBuilder
    $null = $fileHashMarkdownFileContent.AppendLine($markdownHeader)

    foreach ($file in $fileHash)
    {
        $fileHashWithSize = '| {0} | {1} | {2} |' -f
            $(Split-Path -Path $file.Path -Leaf),
            $($file.Hash),
            $((Get-Item -Path $file.Path).Length)
        $null = $fileHashMarkdownFileContent.AppendLine($fileHashWithSize)
    }

    Set-Content -Path $MarkdownPath -Value $fileHashMarkdownFileContent.ToString().Trim() -Force
}

<#
    .SYNOPSIS
        Updates the PowerSTIG Wiki STIG Coverage markdown files located in .\PowerStig.wiki\StigDetails.

    .DESCRIPTION
        Updates the PowerSTIG Wiki STIG Coverage markdown files located in .\PowerStig.wiki\StigDetails.
        Updates/Creates a markdown per Processed STIG Xml with statistical data on STIG Coverage.

    .PARAMETER ProcessedStigPath
        Specifies the path to the ProcessedStig directory within the PowerSTIG project.

    .PARAMETER PowerStigWikiPath
        Specifies the path to the PowerSTIG Wiki on the local machine. The default parameter value is
        the root directory the PowerSTIG project resides in.

    .PARAMETER Exclude
        Specifies an array of strings representing files and/or directories to exclude from the ProcessedStig
        Get-ChildItem output.

    .EXAMPLE
        PS C:\> Update-PowerSTIGCoverageMarkdown

        Updates/Creates a markdown per Processed STIG Xml with statistical data on STIG Coverage in the
        PowerStig.wiki path.
#>
function Update-PowerSTIGCoverageMarkdown
{
    [CmdletBinding()]
    param
    (
        [Parameter()]
        [string[]]
        $ProcessedStigPath = (Join-Path -Path $PSScriptRoot -ChildPath '..\..\source\StigData\Processed\*.xml'),

        [Parameter()]
        [string]
        $PowerStigWikiPath = (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\PowerSTIG.wiki\'),

        [Parameter()]
        [string[]]
        $Exclude = @('*.org.default.xml','ActiveDirectory-All-*.xml')
    )

    if (-not (Test-Path -Path $PowerStigWikiPath))
    {
        throw "$(Split-Path -Path $PowerStigWikiPath) was not detected, check the path and try again."
    }

    $stigDetails = Join-Path -Path $PowerStigWikiPath -ChildPath 'StigDetails'
    Get-ChildItem -Path $stigDetails -Recurse | Remove-Item -Recurse -Confirm:$false -Force

    $moduleManifest = Join-Path -Path $PSScriptRoot -ChildPath '..\..\source\PowerStig.psd1'
    $moduleVersion = (Import-PowerShellDataFile -Path $moduleManifest).ModuleVersion
    $processedStig = Get-ChildItem -Path $ProcessedStigPath -Exclude $Exclude | Select-Object -ExpandProperty FullName
    $markdownStrings = Import-PowerShellDataFile -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Data.Markdown.psd1')
    $summaryHeader = $markdownStrings.markdownSummaryHeader -f $moduleVersion

    # String builder to set the StigCoverageSummary markdown file
    $summaryMarkdownContent = New-Object -TypeName System.Text.StringBuilder -ArgumentList $summaryHeader
    $null = $summaryMarkdownContent.AppendLine()

    # Loop through each xml and create coverage information
    foreach ($stigXml in $processedStig)
    {
        [xml]$stig = Get-Content -Path $stigXml -Encoding UTF8
        $allStigRuleType = ($stig.DISASTIG | Get-Member -Name *Rule).Name
        $automatedRuleType = $allStigRuleType | Where-Object -FilterScript {$_ -notmatch 'DocumentRule|ManualRule'}
        $docManualRuleType = $allStigRuleType | Where-Object -FilterScript {$_ -match 'DocumentRule|ManualRule'}
        $allStigRuleCount = ($allStigRuleType | ForEach-Object {$stig.DISASTIG.$_.Rule} | Measure-Object).Count
        $automatedRuleCount = ($automatedRuleType | ForEach-Object {$stig.DISASTIG.$_.Rule} | Measure-Object).Count
        $allStigRuleSevCount = $allStigRuleType | Foreach-Object {$stig.DISASTIG.$_.Rule} | Group-Object -Property severity -NoElement
        $automatedSevCount = $automatedRuleType | Foreach-Object {$stig.DISASTIG.$_.Rule} | Group-Object -Property severity -NoElement
        $stigDetailFileName = (Split-Path -Path $stigXml -Leaf) -replace '.xml', '.md'
        $stigDetailFilePath = Join-Path -Path $stigDetails -ChildPath $stigDetailFileName
        $stigDetailFileLink = $markdownStrings.markdownRuleLink -f ($stigDetailFileName -replace '.md')
        [string]$stigAutomatedRulePercentage = ([math]::Round($automatedRuleCount/$allStigRuleCount, 2) * 100)
        $stigMarkdown = $markdownStrings.markdownSummaryBody -f
            $stig.DISASTIG.stigid.Replace('_', ' ').Trim(),
            $stig.DISASTIG.fullversion.Trim(),
            $stigDetailFileLink,
            $stig.DISASTIG.title.Trim(),
            $stig.DISASTIG.version.Trim(),
            $stig.DISASTIG.releaseinfo.Trim(),
            $stig.DISASTIG.filename.Trim(),
            $stig.DISASTIG.created.Trim(),
            $stig.DISASTIG.description.Trim(),
            $automatedRuleCount,
            $allStigRuleCount,
            $stigAutomatedRulePercentage,
            ($automatedSevCount | Where-Object {$_.Name -eq 'high'}).Count,
            ($allStigRuleSevCount | Where-Object {$_.Name -eq 'high'}).Count,
            ($automatedSevCount | Where-Object {$_.Name -eq 'medium'}).Count,
            ($allStigRuleSevCount | Where-Object {$_.Name -eq 'medium'}).Count,
            ($automatedSevCount | Where-Object {$_.Name -eq 'low'}).Count,
            ($allStigRuleSevCount | Where-Object {$_.Name -eq 'low'}).Count,
            [char]32
        $null = $summaryMarkdownContent.AppendLine()
        $null = $summaryMarkdownContent.AppendLine($stigMarkdown)

        # String builder to set the StigRuleDetails markdown files
        $stigMarkdown = $stigMarkdown -replace '## ', '# '
        $stigDetailContent = New-Object -TypeName System.Text.StringBuilder
        $null = $stigDetailContent.AppendLine($stigMarkdown)
        $null = $stigDetailContent.AppendLine()
        $null = $stigDetailContent.AppendLine($markdownStrings.markdownRuleTableHeader)

        # Loop through each rule to create StigRuleDetails table (Automated Rules)
        foreach ($ruleType in $automatedRuleType)
        {
            foreach ($rule in $stig.DISASTIG.$ruleType.Rule)
            {
                $ruleMarkdown = $markdownStrings.markdownRuleDetail -f
                    $rule.id,
                    [System.Globalization.CultureInfo]::new('en-US').TextInfo.ToTitleCase($rule.severity),
                    $ruleType,
                    $rule.dscresource,
                    $rule.DuplicateOf
                $null = $stigDetailContent.AppendLine($ruleMarkdown)
            }
        }

        if ($null -ne $docManualRuleType)
        {
            # Add Document / Manual Rule Table Header
            $null = $stigDetailContent.AppendLine()
            $null = $stigDetailContent.AppendLine($markdownStrings.markdownDocumentRuleTableHeader)

            # Loop through each rule to create StigRuleDetails table (Document / Manual Rules)
            foreach ($ruleType in $docManualRuleType)
            {
                foreach ($rule in $stig.DISASTIG.$ruleType.Rule)
                {
                    $ruleMarkdown = $markdownStrings.markdownDocumentRuleDetail -f
                        $rule.id,
                        [System.Globalization.CultureInfo]::new('en-US').TextInfo.ToTitleCase($rule.severity),
                        $ruleType
                    $null = $stigDetailContent.AppendLine($ruleMarkdown)
                }
            }
        }

        Set-Content -Path $stigDetailFilePath -Value $stigDetailContent.ToString().Trim() -Force
    }

    $coverageSummary = Join-Path -Path $stigDetails -ChildPath StigCoverageSummary.md
    Set-Content -Path $coverageSummary -Value $summaryMarkdownContent.ToString().Trim() -Force

    Update-PowerSTIGCoverageSidebar -MarkdownStrings $markdownStrings -PowerStigWikiPath $PowerStigWikiPath
}

<#
    .SYNOPSIS
        Update-PowerSTIGCoverageSidebar creates _sidebar.md for Github wiki sidebar.

    .DESCRIPTION
        Update-PowerSTIGCoverageSidebar creates _sidebar.md for Github wiki sidebar. The _sidebar.md
        creates a sidebar table of contents for the wiki page.

    .PARAMETER PowerStigWikiPath
        Specifies the path to the PowerSTIG Wiki on the local machine. The default parameter value is
        the root directory the PowerSTIG project resides in.

    .PARAMETER MarkdownStrings
        Specifies a hashtable representing the Markdown Strings from Data.Markdown.psd1.

    .EXAMPLE
        PS C:\> Update-PowerSTIGCoverageSidebar -MarkdownStrings $markdownStrings

        Creates _sidebar.md in .\PowerSTIG.wiki\StigDetails which represents all the Stig markdown files
        in the StigDetails directory.
#>

function Update-PowerSTIGCoverageSidebar
{
    [CmdletBinding()]
    param
    (
        [Parameter()]
        [string]
        $PowerStigWikiPath = (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\PowerSTIG.wiki'),

        [Parameter(Mandatory = $true)]
        [hashtable]
        $MarkdownStrings
    )

    # Get the contents of the current root _sidebar.md and add the STIG details to create a new StigDetails\_sidebar.md
    $rootSidebar = Get-Content -Path (Join-Path -Path $PowerStigWikiPath -ChildPath '_sidebar.md') -Raw -Encoding UTF8
    $sidebarInsertionIndex = [regex]::Match($rootSidebar, '^\[', [System.Text.RegularExpressions.RegexOptions]::Multiline).Index - 2

    # Query files in the StigDetails directory to create string data for new StigDetails\_sidebar.md
    $stigDetailsDirectoryExclude = @('StigCoverageSummary.md', '_sidebar.md')
    $stigDetailsFileNames = Get-ChildItem -Path (Join-Path -Path $PowerStigWikiPath -ChildPath 'StigDetails') -Exclude $stigDetailsDirectoryExclude

    # String builder to create StigDetails\_sidebar.md
    $stigCoverageSidebarContent = New-Object -TypeName System.Text.StringBuilder
    $null = $stigCoverageSidebarContent.AppendLine($rootSidebar.TrimEnd())

    # String builder to build stig details sidebar table of contents insertion string
    $sidebarTocInsertionContent = New-Object -TypeName System.Text.StringBuilder

    # String builder to build stig details sidebar github hyperlink insertion string
    $sidebarHyperLinkInsertionContent = New-Object -TypeName System.Text.StringBuilder

    foreach ($stigDetail in $stigDetailsFileNames.Name)
    {
        $sidebarStigTitle = $stigDetail -replace '.md'
        $sidebarStigLabel = $stigDetail -replace '.md|-|\.'
        $sidebarTocString = $MarkdownStrings.markdownSidebarToc -f $sidebarStigTitle, $sidebarStigLabel
        $null = $sidebarTocInsertionContent.AppendLine($sidebarTocString)

        $hyperLinkString = $MarkdownStrings.markdownRuleLink -f $sidebarStigTitle
        $sidebarHyperLinkString = $MarkdownStrings.markdownSidebarHyperLink -f $sidebarStigLabel, $hyperLinkString
        $null = $sidebarHyperLinkInsertionContent.AppendLine($sidebarHyperLinkString)
    }

    # Insert sidebar table of contents / Append HyperLink
    $null = $stigCoverageSidebarContent.Insert($sidebarInsertionIndex, $sidebarTocInsertionContent.ToString())
    $null = $stigCoverageSidebarContent.AppendLine($sidebarHyperLinkInsertionContent.ToString().TrimEnd())

    # Create/Overwrite StigDetails\_sidebar.md
    $stigCoverageSidebarFilePath = Join-Path -Path $PowerStigWikiPath -ChildPath 'StigDetails\_sidebar.md'
    Set-Content -Path $stigCoverageSidebarFilePath -Value $stigCoverageSidebarContent.ToString().TrimEnd() -Force
}

#endregion
#region DevMerge

function Start-PowerStigDevMerge
{
    [OutputType([int])]
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [ValidateSet('Feature', 'Hotfix')]
        [string]
        $Type,

        [Parameter(Mandatory = $true)]
        [string]
        $GitRepositoryPath,

        [Parameter(Mandatory = $true)]
        [string]
        $ModuleVersion,

        [Parameter()]
        [string]
        $GitHubApiSecureFilePath
    )

    $repository = Get-PowerStigRepository
    Get-GitHubApiKey -SecureFilePath $GitHubApiSecureFilePath
    $releaseBranchName = $script:ReleaseName -f $ModuleVersion

    # Convert GitRepositoryPath into an absolute path if it is relative
    if (-not ([System.IO.Path]::IsPathRooted($GitRepositoryPath)))
    {
        $GitRepositoryPath = Resolve-Path -Path $GitRepositoryPath
    }

    Push-Location -Path $GitRepositoryPath

    if (Test-ModuleVersion -ModuleVersion $ModuleVersion)
    {
        Write-Verbose -Message "$ModuleVersion is greater than currently released."
    }
    else
    {
        throw "$ModuleVersion is not greater than currently released."
    }

    if ($Type -eq 'Hotfix')
    {
        New-GitReleaseBranch -BranchName $releaseBranchName
    }
    else
    {
        try
        {
            Set-GitBranch -Branch $ModuleVersion -SkipPull
            $releaseBranchName = $ModuleVersion
        }
        catch
        {
            throw "Git branch $ModuleVersion was not found"
        }
    }

    $releaseNotes = Get-UnreleasedNotes

    if ([string]::IsNullOrEmpty($releaseNotes))
    {
        throw 'There are no release notes for this release.'
    }

    Update-ReleaseNotes -ModuleVersion $ModuleVersion

    Update-Manifest -ModuleVersion $ModuleVersion -ReleaseNotes $releaseNotes

    Update-AppVeyorConfiguration -ModuleVersion $ModuleVersion

    Update-Contributors -Repository $repository

    Update-FileHashMarkdown -ModuleVersion $ModuleVersion

    # Push the release changes to GitHub
    Push-GitBranch -Name $releaseBranchName -CommitMessage "Bumped version number to $ModuleVersion for release."

    $pullRequestParameters = @{
        Repository    = $Repository
        ModuleVersion = $ModuleVersion
        BranchHead    = $releaseBranchName
        BranchBase    = 'dev'
    }
    $pullRequest = New-GitHubPullRequest @pullRequestParameters

    $null = Set-GitBranch -Branch 'dev'
    return $pullRequest.number
}

<#
    .SYNOPSIS
        Completes the PowerStig release process for a given module that was
        created using the New-PowerStigRelease function.
    .DESCRIPTION
    .PARAMETER GitRepositoryPath
        The path to the git repository on your local machine. If this path is
        not a valid git repository, this function will throw an error.
        Additionally, if the repository remote origin is not a PowerStig project,
        this function will throw an error
    .PARAMETER PullRequestNumber
        The pull request number to complete.
    .PARAMETER GitHubApiSecureFilePath
        The path to the secured GitHub API key. If you have a file named
        PowerStigGitHubApi.txt in $profile, it will automatically be loaded.
        Running the following command will prompt you for your GitHub API key
        and create the file for you so that you can skip this parameter.

        Read-Host "Enter Password" -AsSecureString |
            ConvertFrom-SecureString |
                Out-File "$(Split-Path $profile)\PowerStigGitHubApi.txt"
#>
function Complete-PowerStigDevMerge
{
    param
    (
        [Parameter(Mandatory = $true)]
        [string]
        $GitRepositoryPath,

        [Parameter(Mandatory = $true)]
        [int]
        $PullRequestNumber,

        [Parameter()]
        [string]
        $GitHubApiSecureFilePath
    )

    # Convert GitRepositoryPath into an absolute path if it is relative
    if (-not ([System.IO.Path]::IsPathRooted($GitRepositoryPath)))
    {
        $GitRepositoryPath = Resolve-Path -Path $GitRepositoryPath
    }

    Push-Location -Path $GitRepositoryPath

    try
    {
        $repository = Get-PowerStigRepository

        Get-GitHubApiKey -SecureFilePath $GitHubApiSecureFilePath

        $pullRequestParam = @{
            Repository = $repository
            Number     = $PullRequestNumber
        }
        $pullRequest = Get-GitHubPullRequest @pullRequestParam

        $approvePullRequestParam = [ordered]@{
            PullRequest   = $pullRequest
            CommitTitle   = 'Merged dev for release.'
            CommitMessage = 'Accepted PR'
        }
        $pullRequest = Approve-GitHubPullRequest @approvePullRequestParam
    }
    catch
    {
        Pop-Location
    }
}

#endregion
<#
    .SYNOPSIS
        Starts the PowerStig release process for a given module
    .DESCRIPTION
        Applies a standard process and comment structure to the release process
        for a given module. At a high level, this function will:

        1. Validate that you are trying to deploy and PowerStig module
        2. Validate that you are trying to release a higher version number than
           is currently released.
        3. Create a release branch from dev and update the module version number
           in all of the appropriate places.
        4. Push the release branch to GitHub and create a pull request into the
           master branch.
    .PARAMETER GitRepositoryPath
        The path to the git repository on your local machine. If this path is
        not a valid git repository, this function will throw an error.
        Additionally, if the repository remote origin is not a PowerStig project,
        this function will throw an error
    .PARAMETER ModuleVersion
        The version number that is injected to the different areas of the
        release process. Specifically the module manifest, AppVeyor build config,
        and readme release notes.
    .PARAMETER GitHubApiSecureFilePath
        The path to the secured GitHub API key. If you have a file named
        PowerStigGitHubApi.txt in $profile, it will automatically be loaded.
        Running the following command will prompt you for your GitHub API key
        and create the file for you so that you can skip this parameter.

        Read-Host "Enter Password" -AsSecureString |
            ConvertFrom-SecureString |
                Out-File "$(Split-Path $profile)\PowerStigGitHubApi.txt"
#>
function Start-PowerStigRelease
{
    [OutputType([int])]
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [string]
        $ModuleVersion,

        [Parameter()]
        [string]
        $GitHubApiSecureFilePath
    )

    $repository = Get-PowerStigRepository

    Get-GitHubApiKey -SecureFilePath $GitHubApiSecureFilePath

    # Get the Dev Banch status. Wait until it is success or failure
    $gitHubRefStatusParam = [ordered]@{
        'Repository' = $repository
        'Name' = 'dev'
        'WaitForSuccess' = $false
    }
    $gitHubReleaseBranchStatus = Get-GitHubRefStatus @gitHubRefStatusParam

    if ($gitHubReleaseBranchStatus -eq 'success')
    {
        $pullRequestParameters = @{
            Repository    = $Repository
            ModuleVersion = $ModuleVersion
            BranchHead    = 'dev'
            BranchBase    = 'master'
        }
        $pullRequest = New-GitHubPullRequest @pullRequestParameters

        return $pullRequest.number
    }
    else
    {
        throw "dev is currently $gitHubReleaseBranchStatus and cannot be merged into Master."
    }
}

function Start-PowerStigDevMerge
{
    [OutputType([int])]
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [ValidateSet('Feature', 'Hotfix')]
        [string]
        $Type,

        [Parameter(Mandatory = $true)]
        [string]
        $GitRepositoryPath,

        [Parameter(Mandatory = $true)]
        [string]
        $ModuleVersion,

        [Parameter()]
        [string]
        $GitHubApiSecureFilePath
    )

    $repository = Get-PowerStigRepository
    Get-GitHubApiKey -SecureFilePath $GitHubApiSecureFilePath
    $releaseBranchName = $script:ReleaseName -f $ModuleVersion

    # Convert GitRepositoryPath into an absolute path if it is relative
    if (-not ([System.IO.Path]::IsPathRooted($GitRepositoryPath)))
    {
        $GitRepositoryPath = Resolve-Path -Path $GitRepositoryPath
    }

    Push-Location -Path $GitRepositoryPath

    if (Test-ModuleVersion -ModuleVersion $ModuleVersion)
    {
        Write-Verbose -Message "$ModuleVersion is greater than currently released."
    }
    else
    {
        throw "$ModuleVersion is not greater than currently released."
    }

    if ($Type -eq 'Hotfix')
    {
        New-GitReleaseBranch -BranchName $releaseBranchName
    }
    else
    {
        try
        {
            Set-GitBranch -Branch $ModuleVersion -SkipPull
            $releaseBranchName = $ModuleVersion
        }
        catch
        {
            throw "Git branch $ModuleVersion was not found"
        }
    }

    # $releaseNotes = Get-UnreleasedNotes

    # if ([string]::IsNullOrEmpty($releaseNotes))
    # {
    #     throw 'There are no release notes for this release.'
    # }

    #Update-ReleaseNotes -ModuleVersion $ModuleVersion

    #Update-Manifest -ModuleVersion $ModuleVersion -ReleaseNotes $releaseNotes

    Update-AppVeyorConfiguration -ModuleVersion $ModuleVersion

    Update-Contributors -Repository $repository

    Update-FileHashMarkdown -ModuleVersion $ModuleVersion

    # Push the release branch to GitHub
    Push-GitBranch -Name $releaseBranchName -CommitMessage "Bumped version number to $ModuleVersion for release."

    $repository = Get-PowerStigRepository

    $pullRequestParameters = @{
        Repository    = $Repository
        ModuleVersion = $ModuleVersion
        BranchHead    = $releaseBranchName
        BranchBase    = 'dev'
    }
    #$pullRequest = New-GitHubPullRequest @pullRequestParameters

    return $pullRequest.number
}

<#
    .SYNOPSIS
        Completes the PowerStig release process for a given module that was
        created using the New-PowerStigRelease function.
    .DESCRIPTION
        Applies a standard process and comment structure to the release process
        for a given module. At a high level, this function will:

        1. Validate that you are trying to deploy and PowerStig module
        2. Approve the pull request on GitHub
        3. Create a GitHub Release (Triggers an AppVeyor deployment)
        4. Cleans up the release branch from the local and remote repository
    .PARAMETER GitRepositoryPath
        The path to the git repository on your local machine. If this path is
        not a valid git repository, this function will throw an error.
        Additionally, if the repository remote origin is not a PowerStig project,
        this function will throw an error
    .PARAMETER ModuleVersion
        The version number that is injected to the different areas of the
        release process. Specifically the module manifest, AppVeyor build config,
        and readme release notes.
    .PARAMETER GitHubApiSecureFilePath
        The path to the secured GitHub API key. If you have a file named
        PowerStigGitHubApi.txt in $profile, it will automatically be loaded.
        Running the following command will prompt you for your GitHub API key
        and create the file for you so that you can skip this parameter.

        Read-Host "Enter Password" -AsSecureString |
            ConvertFrom-SecureString |
                Out-File "$(Split-Path $profile)\PowerStigGitHubApi.txt"
#>
function Complete-PowerStigRelease
{
    param
    (
        [Parameter(Mandatory = $true)]
        [string]
        $GitRepositoryPath,

        [Parameter(Mandatory = $true)]
        [int]
        $PullRequestNumber,

        [Parameter(Mandatory = $true)]
        [string]
        $ModuleVersion,

        [Parameter()]
        [string]
        $GitHubApiSecureFilePath
    )

    # Convert GitRepositoryPath into an absolute path if it is relative
    if (-not ([System.IO.Path]::IsPathRooted($GitRepositoryPath)))
    {
        $GitRepositoryPath = Resolve-Path -Path $GitRepositoryPath
    }
    Push-Location -Path $GitRepositoryPath

    $currentGitBranch = Get-GitBranch
    # make sure we pull the release notes from the dev branch
    Set-GitBranch -Branch 'dev'

    try
    {
        $repository = Get-PowerStigRepository

        Get-GitHubApiKey -SecureFilePath $GitHubApiSecureFilePath

        $pullRequestParam = @{
            Repository = $repository
            Number = $PullRequestNumber
        }
        $pullRequest = Get-GitHubPullRequest @pullRequestParam

        $approvePullRequestParam = [ordered]@{
            PullRequest = $pullRequest
            CommitTitle = 'Release'
            CommitMessage = 'This PR is automatically completed.'
            MergeMethod = 'merge'
        }
        $null = Approve-GitHubPullRequest @approvePullRequestParam

        # Get the manifest release notes to add to release
        $manifestPath = (Get-ChildItem -Path $PWD -Filter "*.psd1").FullName
        $releaseNotes = (Import-PowerShellDataFile -Path $manifestPath).PrivateData.PSData.ReleaseNotes

        $gitHubReleaseParams = @{
            Repository = $repository
            TagName = $ModuleVersion + '-PSGallery'
            Title = "Release of version $(($ModuleVersion -Split '-')[0])"
            Description = $releaseNotes
        }
        # The GitHub release triggers the AppVeyor deployment to the Gallery.
        $null = New-GitHubRelease @gitHubReleaseParams

        Remove-GitBranch -BranchName $ModuleVersion
    }
    finally
    {
        Write-Verbose -Message 'Reverting to initial location'
        Pop-Location -Verbose
        Write-Verbose -Message 'Reverting to initial branch'
        Set-GitBranch -Branch $currentGitBranch -SkipPull
    }
}

Export-ModuleMember -Function @(
    '*-PowerStigRelease',
    '*-PowerStigDevMerge',
    'Update-PowerSTIGCoverageMarkdown',
    'Update-FileHashMarkdown'
)
