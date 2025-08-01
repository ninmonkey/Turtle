﻿<#
.Synopsis
    GitHub Action for Turtle
.Description
    GitHub Action for Turtle.  This will:

    * Import Turtle
    * If `-Run` is provided, run that script
    * Otherwise, unless `-SkipScriptFile` is passed, run all *.Turtle.ps1 files beneath the workflow directory
      * If any `-ActionScript` was provided, run scripts from the action path that match a wildcard pattern.

    If you will be making changes using the GitHubAPI, you should provide a -GitHubToken
    If none is provided, and ENV:GITHUB_TOKEN is set, this will be used instead.
    Any files changed can be outputted by the script, and those changes can be checked back into the repo.
    Make sure to use the "persistCredentials" option with checkout.
#>

param(
# A PowerShell Script that uses Turtle.  
# Any files outputted from the script will be added to the repository.
# If those files have a .Message attached to them, they will be committed with that message.
[string]
$Run,

# If set, will not process any files named *.Turtle.ps1
[switch]
$SkipScriptFile,

# A list of modules to be installed from the PowerShell gallery before scripts run.
[string[]]
$InstallModule,

# If provided, will commit any remaining changes made to the workspace with this commit message.
[string]
$CommitMessage,

# If provided, will checkout a new branch before making the changes.
# If not provided, will use the current branch.
[string]
$TargetBranch,

# The name of one or more scripts to run, from this action's path.
[string[]]
$ActionScript,

# The github token to use for requests.
[string]
$GitHubToken = '{{ secrets.GITHUB_TOKEN }}',

# The user email associated with a git commit.  If this is not provided, it will be set to the username@noreply.github.com.
[string]
$UserEmail,

# The user name associated with a git commit.
[string]
$UserName,

# If set, will not push any changes made to the repository.
# (they will still be committed unless `-NoCommit` is passed)
[switch]
$NoPush,

# If set, will not commit any changes made to the repository.
# (this also implies `-NoPush`)
[switch]
$NoCommit
)

$ErrorActionPreference = 'continue'
"::group::Parameters" | Out-Host
[PSCustomObject]$PSBoundParameters | Format-List | Out-Host
"::endgroup::" | Out-Host

$gitHubEventJson = [IO.File]::ReadAllText($env:GITHUB_EVENT_PATH)
$gitHubEvent = 
    if ($env:GITHUB_EVENT_PATH) {
        $gitHubEventJson | ConvertFrom-Json
    } else { $null }
"::group::Parameters" | Out-Host
$gitHubEvent   | Format-List | Out-Host
"::endgroup::" | Out-Host


$anyFilesChanged = $false
$ActionModuleName = 'Turtle'
$actorInfo = $null


$checkDetached = git symbolic-ref -q HEAD
if ($LASTEXITCODE) {
    "::warning::On detached head, skipping action" | Out-Host
    exit 0
}

function InstallActionModule {
    param([string]$ModuleToInstall)
    $moduleInWorkspace = Get-ChildItem -Path $env:GITHUB_WORKSPACE -Recurse -File |
        Where-Object Name -eq "$($moduleToInstall).psd1" |
        Where-Object { 
            $(Get-Content $_.FullName -Raw) -match 'ModuleVersion'
        }
    if (-not $moduleInWorkspace) {
        $availableModules = Get-Module -ListAvailable
        if ($availableModules.Name -notcontains $moduleToInstall) {
            Install-Module $moduleToInstall -Scope CurrentUser -Force -AcceptLicense -AllowClobber
        }
        Import-Module $moduleToInstall -Force -PassThru | Out-Host
    } else {
        Import-Module $moduleInWorkspace.FullName -Force -PassThru | Out-Host
    }
}
function ImportActionModule {
    #region -InstallModule
    if ($InstallModule) {
        "::group::Installing Modules" | Out-Host
        foreach ($moduleToInstall in $InstallModule) {
            InstallActionModule -ModuleToInstall $moduleToInstall
        }
        "::endgroup::" | Out-Host
    }
    #endregion -InstallModule

    if ($env:GITHUB_ACTION_PATH) {
        $LocalModulePath = Join-Path $env:GITHUB_ACTION_PATH "$ActionModuleName.psd1"
        if (Test-path $LocalModulePath) {
            Import-Module $LocalModulePath -Force -PassThru | Out-String
        } else {
            throw "Module '$ActionModuleName' not found"
        }
    } elseif (-not (Get-Module $ActionModuleName)) {    
        throw "Module '$ActionModuleName' not found"
    }

    "::notice title=ModuleLoaded::$ActionModuleName Loaded from Path - $($LocalModulePath)" | Out-Host
    if ($env:GITHUB_STEP_SUMMARY) {
        "# $($ActionModuleName)" |
            Out-File -Append -FilePath $env:GITHUB_STEP_SUMMARY
    }
}
function InitializeAction {
    #region Custom 
    #endregion Custom

    # Configure git based on the $env:GITHUB_ACTOR
    if (-not $UserName) { $UserName = $env:GITHUB_ACTOR }
    if (-not $actorID)  { $actorID = $env:GITHUB_ACTOR_ID }
    $actorInfo = 
        if ($GitHubToken -notmatch '^\{{2}' -and $GitHubToken -notmatch '\}{2}$') {
            Invoke-RestMethod -Uri "https://api.github.com/user/$actorID" -Headers @{ Authorization = "token $GitHubToken" }
        } else {
            Invoke-RestMethod -Uri "https://api.github.com/user/$actorID"
        }
    
    if (-not $UserEmail) { $UserEmail = "$UserName@noreply.github.com" }
    git config --global user.email $UserEmail
    git config --global user.name  $actorInfo.name

    # Pull down any changes
    git pull | Out-Host

    if ($TargetBranch) {
        "::notice title=Expanding target branch string $targetBranch" | Out-Host
        $TargetBranch = $ExecutionContext.SessionState.InvokeCommand.ExpandString($TargetBranch)
        "::notice title=Checking out target branch::$targetBranch" | Out-Host
        git checkout -b $TargetBranch | Out-Host    
        git pull | Out-Host
    }
}

function InvokeActionModule {
    $myScriptStart = [DateTime]::Now
    $myScript = $ExecutionContext.SessionState.PSVariable.Get("Run").Value
    if ($myScript) {
        Invoke-Expression -Command $myScript |
            . ProcessOutput |
            Out-Host
        return
    }
    $myScriptTook = [Datetime]::Now - $myScriptStart
    $MyScriptFilesStart = [DateTime]::Now

    $myScriptList  = @()
    $shouldSkip = $ExecutionContext.SessionState.PSVariable.Get("SkipScriptFile").Value
    if ($shouldSkip) {
        return 
    }
    $scriptFiles = @(
        Get-ChildItem -Recurse -Path $env:GITHUB_WORKSPACE |
            Where-Object Name -Match "\.$($ActionModuleName)\.ps1$"
        if ($ActionScript) {
            if ($ActionScript -match '^\s{0,}/' -and $ActionScript -match '/\s{0,}$') {
                $ActionScriptPattern = $ActionScript.Trim('/').Trim() -as [regex]
                if ($ActionScriptPattern) {
                    $ActionScriptPattern = [regex]::new($ActionScript.Trim('/').Trim(), 'IgnoreCase,IgnorePatternWhitespace', [timespan]::FromSeconds(0.5))
                    Get-ChildItem -Recurse -Path $env:GITHUB_ACTION_PATH |
                        Where-Object { $_.Name -Match "\.$($ActionModuleName)\.ps1$" -and $_.FullName -match $ActionScriptPattern }
                }
            } else {
                Get-ChildItem -Recurse -Path $env:GITHUB_ACTION_PATH |
                    Where-Object Name -Match "\.$($ActionModuleName)\.ps1$" |
                    Where-Object FullName -Like $ActionScript
            }
        }
    ) | Select-Object -Unique
    $scriptFiles |
        ForEach-Object -Begin {
            if ($env:GITHUB_STEP_SUMMARY) {
                "## $ActionModuleName Scripts" |
                    Out-File -Append -FilePath $env:GITHUB_STEP_SUMMARY
            } 
        } -Process {
            $myScriptList += $_.FullName.Replace($env:GITHUB_WORKSPACE, '').TrimStart('/')
            $myScriptCount++
            $scriptFile = $_
            if ($env:GITHUB_STEP_SUMMARY) {
                "### $($scriptFile.Fullname -replace [Regex]::Escape($env:GITHUB_WORKSPACE))" |
                    Out-File -Append -FilePath $env:GITHUB_STEP_SUMMARY
            }
            $scriptCmd = $ExecutionContext.SessionState.InvokeCommand.GetCommand($scriptFile.FullName, 'ExternalScript')
            foreach ($requiredModule in $CommandInfo.ScriptBlock.Ast.ScriptRequirements.RequiredModules) {
                if ($requiredModule.Name -and 
                    (-not $requiredModule.MaximumVersion) -and
                    (-not $requiredModule.RequiredVersion)
                ) {
                    InstallActionModule $requiredModule.Name
                }
            }
            Push-Location $scriptFile.Directory.Fullname
            $scriptFileOutputs = . $scriptCmd
            $scriptFileOutputs |
                . ProcessOutput  | 
                Out-Host
            Pop-Location
        }    
    
    $MyScriptFilesTook = [Datetime]::Now - $MyScriptFilesStart
    $SummaryOfMyScripts = "$myScriptCount $ActionModuleName scripts took $($MyScriptFilesTook.TotalSeconds) seconds" 
    $SummaryOfMyScripts | 
        Out-Host
    if ($env:GITHUB_STEP_SUMMARY) {
        $SummaryOfMyScripts | 
            Out-File -Append -FilePath $env:GITHUB_STEP_SUMMARY
    }
    #region Custom    
    #endregion Custom
}

function OutError {
    $anyRuntimeExceptions = $false
    foreach ($err in $error) {        
        $errParts = @(
            "::error "
            @(
                if ($err.InvocationInfo.ScriptName) {
                "file=$($err.InvocationInfo.ScriptName)"
            }
            if ($err.InvocationInfo.ScriptLineNumber -ge 1) {
                "line=$($err.InvocationInfo.ScriptLineNumber)"
                if ($err.InvocationInfo.OffsetInLine -ge 1) {
                    "col=$($err.InvocationInfo.OffsetInLine)"
                }
            }
            if ($err.CategoryInfo.Activity) {
                "title=$($err.CategoryInfo.Activity)"
            }
            ) -join ','
            "::"
            $err.Exception.Message
            if ($err.CategoryInfo.Category -eq 'OperationStopped' -and 
                $err.CategoryInfo.Reason -eq 'RuntimeException') {
                $anyRuntimeExceptions = $true
            }
        ) -join ''
        $errParts | Out-Host
        if ($anyRuntimeExceptions) {
            exit 1
        }
    }
}

function PushActionOutput {
    if ($anyFilesChanged) {
        "::notice::$($anyFilesChanged) Files Changed" | Out-Host        
    }
    if ($CommitMessage -or $anyFilesChanged) {
        if ($CommitMessage) {
            Get-ChildItem $env:GITHUB_WORKSPACE -Recurse |
                ForEach-Object {
                    $gitStatusOutput = git status $_.Fullname -s
                    if ($gitStatusOutput) {
                        git add $_.Fullname
                    }
                }
    
            git commit -m $ExecutionContext.SessionState.InvokeCommand.ExpandString($CommitMessage)
        }
    
        $checkDetached = git symbolic-ref -q HEAD
        if (-not $LASTEXITCODE -and -not $NoPush -and -not $noCommit) {            
            if ($TargetBranch -and $anyFilesChanged) {
                "::notice::Pushing Changes to $targetBranch" | Out-Host
                git push --set-upstream origin $TargetBranch
            } elseif ($anyFilesChanged) {
                "::notice::Pushing Changes" | Out-Host
                git push
            }
            "Git Push Output: $($gitPushed  | Out-String)"
        } else {
            "::notice::Not pushing changes (on detached head)" | Out-Host
            $LASTEXITCODE = 0
            exit 0
        }
    }
}

filter ProcessOutput {
    $out = $_
    $outItem = Get-Item -Path $out -ErrorAction Ignore
    if (-not $outItem -and $out -is [string]) {
        $out | Out-Host
        if ($env:GITHUB_STEP_SUMMARY) {
            "> $out" | Out-File -Append -FilePath $env:GITHUB_STEP_SUMMARY
        }
        return
    }
    $fullName, $shouldCommit = 
        if ($out -is [IO.FileInfo]) {
            $out.FullName, (git status $out.Fullname -s)
        } elseif ($outItem) {
            $outItem.FullName, (git status $outItem.Fullname -s)
        }
    if ($shouldCommit -and -not $NoCommit) {
        "$fullName has changed, and should be committed" | Out-Host
        git add $fullName
        if ($out.Message) {
            git commit -m "$($out.Message)" | Out-Host
        } elseif ($out.CommitMessage) {
            git commit -m "$($out.CommitMessage)" | Out-Host
        }  elseif ($gitHubEvent.head_commit.message) {
            git commit -m "$($gitHubEvent.head_commit.message)" | Out-Host
        }
        $anyFilesChanged = $true
    }    
    $out
}

. ImportActionModule
. InitializeAction
. InvokeActionModule
. PushActionOutput
. OutError