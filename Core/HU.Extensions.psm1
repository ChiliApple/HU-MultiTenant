#Requires -Version 5.1

# HU.Extensions - Extension Loader and Manager for HU-MultiTenant
# Scans ./Extensions/ for .ps1 scripts, parses metadata headers,
# categorizes by prefix, validates permissions, executes scripts.
# Module: HU.Extensions.psm1 | Project: HU-MultiTenant | Version: 1.0.0

# ============================================================================
# MODULE VARIABLES
# ============================================================================

# Cached extension objects
$script:ExtensionCache = [System.Collections.ArrayList]::new()

# Base path for extensions
$script:ExtensionBasePath = $null

# Known category prefixes
$script:CategoryPrefixes = @{
    'Device-'   = 'Device'
    'Policy-'   = 'Policy'
    'Security-' = 'Security'
    'Common-'   = 'Common'
    'User-'     = 'User'
}

# ============================================================================
# 1. Get-AllExtensions
# ============================================================================

function Get-AllExtensions {
    <#
    .SYNOPSIS
        Scans all extension scripts and returns them as structured objects.
    .DESCRIPTION
        Searches configured SearchPaths for .ps1 files recursively,
        parses their metadata headers and caches the results.
        Template.ps1 is always skipped.
    .PARAMETER SearchPaths
        Array of directory paths to search. Default: ./Extensions
    .PARAMETER ForceRescan
        Ignore cache and rescan all paths.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [string[]]$SearchPaths,
        [switch]$ForceRescan
    )

    process {
        # Return cache if available
        if (-not $ForceRescan -and $script:ExtensionCache.Count -gt 0) {
            return @($script:ExtensionCache)
        }

        $script:ExtensionCache.Clear()

        # Default SearchPaths
        if (-not $SearchPaths -or $SearchPaths.Count -eq 0) {
            $moduleDir = Split-Path -Parent $PSScriptRoot
            $SearchPaths = @(Join-Path $moduleDir 'Extensions')
        }

        foreach ($basePath in $SearchPaths) {
            if (-not (Test-Path $basePath)) {
                Write-Verbose "[Extensions] Ordner nicht gefunden: $basePath"
                continue
            }

            $script:ExtensionBasePath = $basePath

            # Find all .ps1 files recursively
            $scripts = Get-ChildItem -Path $basePath -Filter '*.ps1' -Recurse -File |
                Where-Object { $_.Name -ne 'Template.ps1' }

            foreach ($scriptFile in $scripts) {
                $metadata = Parse-ExtensionMetadata -FilePath $scriptFile.FullName

                if (-not $metadata) {
                    Write-Verbose "[Extensions] Keine Metadaten in $($scriptFile.Name) - uebersprungen"
                    continue
                }

                # Determine category from metadata or filename prefix
                $category = $metadata.Category
                if ([string]::IsNullOrWhiteSpace($category)) {
                    $category = Resolve-CategoryFromName -FileName $scriptFile.Name
                }

                # Parse targets (JSON array string to PS array, flattened)
                $targets = @()
                if ($metadata.Targets) {
                    try {
                        $parsed = $metadata.Targets | ConvertFrom-Json -ErrorAction Stop
                        # Flatten: ConvertFrom-Json may return nested array
                        $targets = @($parsed | ForEach-Object { $_ })
                    }
                    catch {
                        $targets = @($metadata.Targets -split '[,\r\n]+' |
                            ForEach-Object { $_.Trim().Trim('"', "'", '[', ']') } |
                            Where-Object { $_ -ne '' })
                    }
                }

                # Parse boolean values
                $batchCapable = Convert-ToBool -Value $metadata.BatchCapable
                $dryRunCapable = Convert-ToBool -Value $metadata.DryRunCapable

                # Parse permissions (comma or newline separated)
                $permissions = @()
                if ($metadata.RequiredPermissions) {
                    $permissions = @($metadata.RequiredPermissions -split '[,\r\n]+' |
                        ForEach-Object { $_.Trim() } |
                        Where-Object { $_ -ne '' })
                }

                # Parse roles
                $roles = @()
                if ($metadata.RequiredRoles) {
                    $roles = @($metadata.RequiredRoles -split '[,\r\n]+' |
                        ForEach-Object { $_.Trim() } |
                        Where-Object { $_ -ne '' })
                }

                # Parse runtime: PS5 (default), PS7, PS5|PS7
                $runtime = 'PS5'
                if ($metadata.Runtime) {
                    $rtVal = $metadata.Runtime.Trim().ToUpper()
                    if ($rtVal -match 'PS7' -or $rtVal -match 'PWSH') {
                        $runtime = if ($rtVal -match 'PS5') { 'PS5|PS7' } else { 'PS7' }
                    }
                }

                # Parse mode: ReadOnly (default), ReadWrite
                $mode = 'ReadOnly'
                if ($metadata.Mode) {
                    $modeVal = $metadata.Mode.Trim()
                    if ($modeVal -match 'ReadWrite|Write|Manage') {
                        $mode = 'ReadWrite'
                    }
                }

                # Parse custom parameters: "Name|Type|Label|Default" per line
                $customParams = @()
                if ($metadata.Parameters) {
                    $customParams = @($metadata.Parameters -split '[\r\n]+' |
                        ForEach-Object { $_.Trim() } |
                        Where-Object { $_ -ne '' } |
                        ForEach-Object {
                            $paramParts = $_ -split '\|'
                            if ($paramParts.Count -ge 3) {
                                [PSCustomObject]@{
                                    Name    = $paramParts[0].Trim()
                                    Type    = $paramParts[1].Trim()    # string, int, bool, choice
                                    Label   = $paramParts[2].Trim()    # GUI display label
                                    Default = if ($paramParts.Count -ge 4) { $paramParts[3].Trim() } else { '' }
                                    Choices = if ($paramParts.Count -ge 5) { @($paramParts[4].Trim() -split ';') } else { @() }
                                }
                            }
                        })
                }

                $extension = [PSCustomObject]@{
                    Name                = [System.IO.Path]::GetFileNameWithoutExtension($scriptFile.Name)
                    FileName            = $scriptFile.Name
                    Path                = $scriptFile.FullName
                    RelativePath        = $scriptFile.FullName.Replace($basePath, '').TrimStart('\', '/')
                    Category            = $category
                    Synopsis            = if ($metadata.Synopsis) { $metadata.Synopsis.Trim() } else { '' }
                    Description         = if ($metadata.Description) { $metadata.Description.Trim() } else { '' }
                    RequiredPermissions = $permissions
                    RequiredRoles       = $roles
                    Targets             = $targets
                    BatchCapable        = $batchCapable
                    DryRunCapable       = $dryRunCapable
                    Runtime             = $runtime
                    Mode                = $mode
                    CustomParameters    = $customParams
                    LastModified        = $scriptFile.LastWriteTime
                    FileSize            = $scriptFile.Length
                }

                [void]$script:ExtensionCache.Add($extension)
            }
        }

        Write-Verbose "[Extensions] $($script:ExtensionCache.Count) Extension(s) geladen."
        return @($script:ExtensionCache)
    }
}

# ============================================================================
# 2. Parse-ExtensionMetadata
# ============================================================================

function Parse-ExtensionMetadata {
    <#
    .SYNOPSIS
        Extracts metadata from a script comment block.
    .DESCRIPTION
        Reads the first PowerShell help comment block and extracts
        all .KEY values (SYNOPSIS, REQUIRED_PERMISSIONS, TARGETS, etc.).
    .PARAMETER FilePath
        Full path to the .ps1 file.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$FilePath
    )

    process {
        if (-not (Test-Path $FilePath)) {
            Write-Warning "[Extensions] Datei nicht gefunden: $FilePath"
            return $null
        }

        $content = Get-Content -Path $FilePath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($content)) {
            return $null
        }

        # Extract comment block using regex
        # Pattern matches the opening token, captures content, then the closing token
        $openToken = '<' + '#'
        $closeToken = '#' + '>'
        $escapedOpen = [regex]::Escape($openToken)
        $escapedClose = [regex]::Escape($closeToken)
        $blockPattern = $escapedOpen + '([\s\S]*?)' + $escapedClose

        $commentMatch = [regex]::Match($content, $blockPattern)
        if (-not $commentMatch.Success) {
            return $null
        }

        $commentBlock = $commentMatch.Groups[1].Value

        # Result object
        $result = [PSCustomObject]@{
            Synopsis            = ''
            Description         = ''
            RequiredPermissions = ''
            RequiredRoles       = ''
            Category            = ''
            Targets             = ''
            BatchCapable        = ''
            DryRunCapable       = ''
            Runtime             = ''
            Mode                = ''
            Parameters          = ''
        }

        # Parse all .KEY blocks using split-based approach
        # Known metadata keys - ONLY these are recognized as block delimiters
        # This prevents .All, .Read, .ps1 etc. in permission values from splitting blocks
        $knownKeys = 'SYNOPSIS|DESCRIPTION|REQUIRED_PERMISSIONS|REQUIRED_ROLES|CATEGORY|TARGETS|BATCH_CAPABLE|DRY_RUN_CAPABLE|RUNTIME|MODE|PARAM|EXAMPLE|NOTES'
        $splitPattern = "(?m)^\s*\.($knownKeys)\s*$"
        $parts = [regex]::Split($commentBlock, $splitPattern)

        # Split produces: [preamble, key1, value1, key2, value2, ...]
        for ($i = 1; $i -lt $parts.Count - 1; $i += 2) {
            $key = $parts[$i].Trim()
            $value = $parts[$i + 1].Trim()

            switch ($key.ToUpper()) {
                'SYNOPSIS'             { $result.Synopsis = $value }
                'DESCRIPTION'          { $result.Description = $value }
                'REQUIRED_PERMISSIONS' { $result.RequiredPermissions = $value }
                'REQUIRED_ROLES'       { $result.RequiredRoles = $value }
                'CATEGORY'             { $result.Category = $value }
                'TARGETS'              { $result.Targets = $value }
                'BATCH_CAPABLE'        { $result.BatchCapable = $value }
                'DRY_RUN_CAPABLE'      { $result.DryRunCapable = $value }
                'RUNTIME'              { $result.Runtime = $value }
                'MODE'                 { $result.Mode = $value }
                'PARAM'                { $result.Parameters = $value }
            }
        }

        # At least Synopsis or Description must be present
        if ([string]::IsNullOrWhiteSpace($result.Synopsis) -and
            [string]::IsNullOrWhiteSpace($result.Description)) {
            return $null
        }

        return $result
    }
}

# ============================================================================
# 3. Get-ExtensionsByCategory
# ============================================================================

function Get-ExtensionsByCategory {
    <#
    .SYNOPSIS
        Returns extensions filtered by category.
    .PARAMETER Category
        Category filter: Device, Policy, Security, Common, User
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Device', 'Policy', 'Security', 'Common', 'User')]
        [string]$Category
    )

    process {
        $all = Get-AllExtensions
        return @($all | Where-Object { $_.Category -eq $Category })
    }
}

# ============================================================================
# 4. Validate-ExtensionPermissions
# ============================================================================

function Validate-ExtensionPermissions {
    <#
    .SYNOPSIS
        Checks whether the current token has all permissions required by an extension.
    .DESCRIPTION
        Compares Extension.RequiredPermissions with the token claims (roles/scp).
        Returns missing and granted permissions.
    .PARAMETER Extension
        Extension object from Get-AllExtensions.
    .PARAMETER Token
        Current access token.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Extension,

        [Parameter(Mandatory)]
        [string]$Token
    )

    process {
        $result = [PSCustomObject]@{
            IsValid            = $true
            MissingPermissions = @()
            GrantedPermissions = @()
            ExtensionName      = $Extension.Name
        }

        if (-not $Extension.RequiredPermissions -or $Extension.RequiredPermissions.Count -eq 0) {
            return $result
        }

        # Read token permissions (uses HU.Graph)
        $tokenPermissions = Get-TokenPermissions -Token $Token

        $missing = [System.Collections.ArrayList]::new()
        $granted = [System.Collections.ArrayList]::new()

        foreach ($requiredPerm in $Extension.RequiredPermissions) {
            if ($tokenPermissions -contains $requiredPerm) {
                [void]$granted.Add($requiredPerm)
            }
            else {
                [void]$missing.Add($requiredPerm)
            }
        }

        $result.MissingPermissions = @($missing)
        $result.GrantedPermissions = @($granted)
        $result.IsValid = ($missing.Count -eq 0)

        return $result
    }
}

# ============================================================================
# 5. Get-RequiredPermissionsForScript
# ============================================================================

function Get-RequiredPermissionsForScript {
    <#
    .SYNOPSIS
        Returns required permissions for an extension, enriched with registry info.
    .DESCRIPTION
        Looks up each permission in extensions-registry.json and returns
        description, risk level, category, and setup instructions.
    .PARAMETER Extension
        Extension object.
    .PARAMETER RegistryPath
        Path to extensions-registry.json. Auto-resolved if omitted.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Extension,

        [string]$RegistryPath
    )

    process {
        # Load registry
        if ([string]::IsNullOrWhiteSpace($RegistryPath)) {
            $moduleDir = Split-Path -Parent $PSScriptRoot
            $RegistryPath = Join-Path $moduleDir 'Config\extensions-registry.json'
        }

        $registry = $null
        if (Test-Path $RegistryPath) {
            try {
                $json = Get-Content -Path $RegistryPath -Raw -Encoding UTF8
                $registry = ($json | ConvertFrom-Json).permissionsRegistry
            }
            catch {
                Write-Warning "[Extensions] extensions-registry.json nicht lesbar: $_"
            }
        }

        $results = foreach ($perm in $Extension.RequiredPermissions) {
            $regEntry = $null
            if ($registry -and $registry.PSObject.Properties.Name -contains $perm) {
                $regEntry = $registry.$perm
            }

            [PSCustomObject]@{
                Permission        = $perm
                Description       = if ($regEntry) { $regEntry.description } else { '' }
                Risk              = if ($regEntry) { $regEntry.risk } else { 'Unknown' }
                Category          = if ($regEntry) { $regEntry.category } else { '' }
                UsedBy            = if ($regEntry) { @($regEntry.usedBy) } else { @() }
                SetupInstructions = if ($regEntry) { $regEntry.setupInstructions } else { '' }
            }
        }

        return @($results)
    }
}

# ============================================================================
# 6. Test-ExtensionTargets
# ============================================================================

function Test-ExtensionTargets {
    <#
    .SYNOPSIS
        Checks whether an extension is intended for the selected tenant.
    .DESCRIPTION
        Compares Extension.Targets with the current tenant key.
        An empty Targets array means all tenants are allowed.
    .PARAMETER Extension
        Extension object.
    .PARAMETER TenantKey
        Current tenant key (e.g. Schule-1).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Extension,

        [Parameter(Mandatory)]
        [string]$TenantKey
    )

    process {
        $result = [PSCustomObject]@{
            IsAllowed      = $true
            TenantKey      = $TenantKey
            AllowedTargets = @()
            ExtensionName  = $Extension.Name
            Warning        = ''
        }

        # No targets or empty array means all tenants allowed
        if (-not $Extension.Targets -or $Extension.Targets.Count -eq 0) {
            $result.AllowedTargets = @('*')
            return $result
        }

        $result.AllowedTargets = @($Extension.Targets)

        if ($Extension.Targets -contains $TenantKey) {
            return $result
        }

        # Not in target list
        $result.IsAllowed = $false
        $targetList = $Extension.Targets -join ', '
        $result.Warning = "Extension '$($Extension.Name)' not intended for '$TenantKey'. Allowed: $targetList"

        return $result
    }
}

# ============================================================================
# 7. Invoke-ExtensionScript
# ============================================================================

function Invoke-ExtensionScript {
    <#
    .SYNOPSIS
        Executes an extension script by dot-sourcing and calling its main function.
    .DESCRIPTION
        Steps: dot-source the script, find the Invoke-* entry point,
        call it with TenantKey, Token, and optional WhatIf,
        capture output and errors, measure duration.
    .PARAMETER Extension
        Extension object.
    .PARAMETER TenantKey
        Tenant key string.
    .PARAMETER Token
        Access token string.
    .PARAMETER WhatIf
        Enable dry-run mode.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Extension,

        [Parameter(Mandatory)]
        [string]$TenantKey,

        [Parameter(Mandatory)]
        [string]$Token,

        [switch]$WhatIf,

        [hashtable]$CustomParameters = @{}
    )

    process {
        $result = [PSCustomObject]@{
            Success       = $false
            Output        = $null
            ErrorMessage  = ''
            Duration      = [TimeSpan]::Zero
            ExtensionName = $Extension.Name
            WasDryRun     = $WhatIf.IsPresent
        }

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        try {
            # 1. Dot-source the script
            if (-not (Test-Path $Extension.Path)) {
                $result.ErrorMessage = "Skript nicht gefunden: $($Extension.Path)"
                return $result
            }

            . $Extension.Path

            # 2. Find the main function (convention: Invoke-* defined in script)
            $mainFunction = Get-Command -Name 'Invoke-*' -CommandType Function -ErrorAction SilentlyContinue |
                Where-Object { $_.ScriptBlock.File -eq $Extension.Path } |
                Select-Object -First 1

            if (-not $mainFunction) {
                $result.ErrorMessage = "Keine Invoke-*-Funktion in '$($Extension.Name)' gefunden."
                return $result
            }

            # 3. Build parameters
            $invokeParams = @{
                TenantKey = $TenantKey
                Token     = $Token
            }

            # Only pass WhatIf if script supports dry-run
            if ($WhatIf -and $Extension.DryRunCapable) {
                $invokeParams.WhatIf = $true
            }

            # 4. Pass custom parameters (only if function accepts them)
            if ($CustomParameters -and $CustomParameters.Count -gt 0) {
                $funcParams = $mainFunction.Parameters
                foreach ($cpKey in $CustomParameters.Keys) {
                    if ($funcParams.ContainsKey($cpKey)) {
                        $invokeParams[$cpKey] = $CustomParameters[$cpKey]
                    }
                }
            }

            # 5. Execute
            $output = & $mainFunction.Name @invokeParams

            $result.Success = $true
            $result.Output = $output
        }
        catch {
            $result.ErrorMessage = $_.Exception.Message
            $result.Success = $false
        }
        finally {
            $stopwatch.Stop()
            $result.Duration = $stopwatch.Elapsed
        }

        return $result
    }
}

# ============================================================================
# 8. Get-ExtensionSummary
# ============================================================================

function Get-ExtensionSummary {
    <#
    .SYNOPSIS
        Returns a compact overview of all loaded extensions.
    .DESCRIPTION
        Groups by category, collects all unique permissions,
        lists DryRun and Batch capable scripts.
        Useful for GUI display and setup guide generation.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    process {
        $all = Get-AllExtensions

        # Group by category
        $categories = @{}
        foreach ($ext in $all) {
            $cat = if ($ext.Category) { $ext.Category } else { 'Uncategorized' }
            if (-not $categories.ContainsKey($cat)) {
                $categories[$cat] = [System.Collections.ArrayList]::new()
            }
            [void]$categories[$cat].Add($ext.Name)
        }

        # Collect all unique permissions
        $allPermissions = @($all |
            ForEach-Object { $_.RequiredPermissions } |
            Where-Object { $_ } |
            Sort-Object -Unique)

        # Build category list
        $categoryList = foreach ($key in ($categories.Keys | Sort-Object)) {
            [PSCustomObject]@{
                Category   = $key
                Count      = $categories[$key].Count
                Extensions = @($categories[$key])
            }
        }

        return [PSCustomObject]@{
            TotalCount     = $all.Count
            Categories     = @($categoryList)
            AllPermissions = $allPermissions
            DryRunCapable  = @($all | Where-Object { $_.DryRunCapable } | ForEach-Object { $_.Name })
            BatchCapable   = @($all | Where-Object { $_.BatchCapable } | ForEach-Object { $_.Name })
            Extensions     = @($all | ForEach-Object {
                [PSCustomObject]@{
                    Name        = $_.Name
                    Category    = $_.Category
                    Synopsis    = $_.Synopsis
                    DryRun      = $_.DryRunCapable
                    Batch       = $_.BatchCapable
                    Permissions = $_.RequiredPermissions.Count
                }
            })
        }
    }
}

# ============================================================================
# INTERNAL HELPER FUNCTIONS
# ============================================================================

function Resolve-CategoryFromName {
    <#
    .SYNOPSIS
        Resolves category from filename prefix.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$FileName
    )

    process {
        foreach ($prefix in $script:CategoryPrefixes.Keys) {
            if ($FileName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                return $script:CategoryPrefixes[$prefix]
            }
        }
        return 'Uncategorized'
    }
}

function Convert-ToBool {
    <#
    .SYNOPSIS
        Converts string values to boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()]
        [string]$Value
    )

    process {
        if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
        $trimmed = $Value.Trim().ToLower()
        return ($trimmed -in @('$true', 'true', '1', 'yes', 'ja'))
    }
}

# ============================================================================
# MODULE EXPORTS
# ============================================================================

Export-ModuleMember -Function @(
    'Get-AllExtensions'
    'Parse-ExtensionMetadata'
    'Get-ExtensionsByCategory'
    'Validate-ExtensionPermissions'
    'Get-RequiredPermissionsForScript'
    'Test-ExtensionTargets'
    'Invoke-ExtensionScript'
    'Get-ExtensionSummary'
)
