#Requires -Version 5.1
<#
.SYNOPSIS
    Client Secrets eingeben: Start-Dialog fuer fehlende Secrets und Einzel-Dialog je Tenant (Einstellungen).
.DESCRIPTION
    Speicherung ueber HU.Auth (Save-StoredCredential): DPAPI-Datei %APPDATA%\HU-MultiTenant\<credentialName>.cred,
    nur fuer den angemeldeten Windows-Benutzer auf diesem PC lesbar.
.NOTES
    Dot-Source aus Main.ps1. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
#>

# Nach neuem Secret: Token und alter Ablauf-Eintrag sind ungueltig
function Clear-HUSecretState([string]$TenantKey) {
    try { Clear-TokenCache -TenantKey $TenantKey } catch { }
    $cache = Get-HUSecretCache
    if ($cache.ContainsKey($TenantKey)) {
        $cache.Remove($TenantKey)
        try {
            $o = [ordered]@{}; foreach ($k in ($cache.Keys | Sort-Object)) { $o[$k] = $cache[$k] }
            Write-HUJsonFile -Path $script:SecretCachePath -Object ([pscustomobject]$o) -Depth 4
        } catch { }
    }
}

function Show-SecretSetupDialog {
    <#
    .SYNOPSIS
        Shows a WPF dialog for entering missing Client Secrets.
    .DESCRIPTION
        Checks all tenants for stored credentials. If any are missing,
        displays a Dark Mode dialog with PasswordBoxes for each school.
        Save stores via Save-StoredCredential (DPAPI), Skip bypasses.
    .OUTPUTS
        [bool] $true if secrets were saved, $false if skipped
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    # Check which tenants are missing secrets
    $missingTenants = @()
    foreach ($tenant in @($script:Settings.tenants | Where-Object { "$($_.tenantId)" -and "$($_.tenantId)" -notmatch '<' })) {
        $stored = Get-StoredCredential -TenantKey $tenant.key -Settings $script:Settings
        if (-not $stored) {
            $missingTenants += $tenant
        }
    }

    # All secrets present - no dialog needed
    if ($missingTenants.Count -eq 0) {
        return $true
    }
    # Startbildschirm schliessen, sonst laege er (Topmost) ueber dem Dialog
    if (Get-Command Close-HUSplash -ErrorAction SilentlyContinue) { Close-HUSplash }

    # Build PasswordBox rows dynamically
    $rowDefs = ''
    $inputRows = ''
    $rowIndex = 0

    foreach ($tenant in @($missingTenants)) {
        $isMissing = $null -ne ($missingTenants | Where-Object { $_.key -eq $tenant.key })
        $statusIcon = if ($isMissing) { '&#x274C;' } else { '&#x2705;' }
        $isEnabled = if ($isMissing) { 'True' } else { 'False' }

        $rowDefs += "                    <RowDefinition Height=""Auto""/>`n"
        $inputRows += @"
                    <StackPanel Grid.Row="$rowIndex" Margin="0,4">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="$statusIcon " FontSize="12" VerticalAlignment="Center"/>
                            <TextBlock Text="$([System.Security.SecurityElement]::Escape("$($tenant.displayName)"))" Foreground="White" FontWeight="SemiBold" FontSize="13"/>
                            <TextBlock Text="  ($([System.Security.SecurityElement]::Escape("$($tenant.key)")))" Foreground="#888888" FontSize="11" VerticalAlignment="Center"/>
                        </StackPanel>
                        <PasswordBox x:Name="pwd_$("$($tenant.key)" -replace '[^A-Za-z0-9_]','_')"
                                     Background="#1E1E1E" Foreground="#CCCCCC" FontSize="12"
                                     Padding="6,4" Margin="0,2,0,0"
                                     BorderBrush="#555555" BorderThickness="1"
                                     IsEnabled="$isEnabled"
                                     MaxLength="100"/>
                    </StackPanel>
"@
        $rowIndex++
    }

    $setupXaml = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="HU-MultiTenant - Client Secrets"
    Width="550" Height="480"
    WindowStartupLocation="CenterScreen"
    Background="#1E1E1E"
    ResizeMode="NoResize">

    <DockPanel Margin="20">

        <!-- Header -->
        <StackPanel DockPanel.Dock="Top" Margin="0,0,0,16">
            <TextBlock Text="&#x1F510; Client Secrets eingeben" FontSize="18" FontWeight="Bold" Foreground="White"/>
            <TextBlock Text="Fuer diese Tenants ist auf diesem PC noch kein Client Secret gespeichert (DPAPI, nur fuer deinen Windows-Benutzer lesbar):" Foreground="#AAAAAA" FontSize="12" Margin="0,6,0,0" TextWrapping="Wrap"/>
            <TextBlock Foreground="#FF9800" FontSize="11" Margin="0,4,0,0">
                <Run Text="&#x26A0; "/>
                <Run Text="$($missingTenants.Count) von $($script:Settings.tenants.Count) Secrets fehlen"/>
            </TextBlock>
        </StackPanel>

        <!-- Buttons -->
        <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
            <Button x:Name="btnSetupSkip" Content="Spaeter" Width="90" Padding="8,6"
                    Background="#555555" Foreground="White" FontWeight="SemiBold"
                    BorderThickness="0" Margin="0,0,8,0" Cursor="Hand"/>
            <Button x:Name="btnSetupSave" Content="Speichern" Width="130" Padding="8,6"
                    Background="#4CAF50" Foreground="White" FontWeight="Bold"
                    BorderThickness="0" Cursor="Hand"/>
        </StackPanel>

        <!-- Tenant Inputs (scrollable) -->
        <ScrollViewer VerticalScrollBarVisibility="Auto" Margin="0,4">
            <Grid>
                <Grid.RowDefinitions>
$rowDefs                </Grid.RowDefinitions>
$inputRows            </Grid>
        </ScrollViewer>

    </DockPanel>
</Window>
"@

    # Parse XAML
    try {
        $setupReader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($setupXaml))
        $setupWindow = [System.Windows.Markup.XamlReader]::Load($setupReader)
        if ($script:AppIcon) { try { $setupWindow.Icon = $script:AppIcon } catch { } }
    }
    catch {
        [System.Windows.MessageBox]::Show(
            "Secret-Setup Dialog konnte nicht geladen werden:`n$($_.Exception.Message)",
            'HU MultiTenant - Error', 'OK', 'Error'
        )
        return $false
    }

    # Get button references
    $btnSave = $setupWindow.FindName('btnSetupSave')
    $btnSkip = $setupWindow.FindName('btnSetupSkip')

    # Save button handler
    $btnSave.Add_Click({
        $savedCount = 0
        $errorList = @()

        foreach ($t in $script:Settings.tenants) {
            $ctrlName = "pwd_$("$($t.key)" -replace '[^A-Za-z0-9_]','_')"
            $pwdBox = $setupWindow.FindName($ctrlName)

            if ($pwdBox -and $pwdBox.IsEnabled -and $pwdBox.Password.Length -gt 0) {
                try {
                    $result = Save-StoredCredential -TenantKey $t.key -SecretValue $pwdBox.Password -Settings $script:Settings
                    if ($result) {
                        $savedCount++
                        Clear-HUSecretState -TenantKey $t.key
                    } else {
                        $errorList += $t.displayName
                    }
                }
                catch {
                    $errorList += "$($t.displayName): $($_.Exception.Message)"
                }
            }
        }

        if ($errorList.Count -gt 0) {
            [System.Windows.MessageBox]::Show(
                "Fehler beim Speichern:`n$($errorList -join "`n")",
                'Secret Setup - Fehler', 'OK', 'Warning'
            )
        }

        if ($savedCount -gt 0) {
            [System.Windows.MessageBox]::Show(
                "$savedCount Secret(s) erfolgreich gespeichert.",
                'Secret Setup', 'OK', 'Information'
            )
        }

        $setupWindow.DialogResult = $true
        $setupWindow.Close()
    })

    # Skip button handler
    $btnSkip.Add_Click({
        $setupWindow.DialogResult = $false
        $setupWindow.Close()
    })

    # Show as modal dialog
    $dialogResult = $setupWindow.ShowDialog()
    return ($dialogResult -eq $true)
}


# Einzel-Dialog (Einstellungen > Tenants > "Secret eingeben"): Secret + optional Ablaufdatum
# Rueckgabe: $null = abgebrochen, sonst [pscustomobject]@{ Saved = $true; Expires = 'yyyy-MM-dd' oder '' }
function Show-HUSecretInput {
    param([Parameter(Mandatory)][string]$TenantKey, $Tenant = $null, $Owner = $null)
    # -Tenant: noch nicht gespeicherter Eintrag aus den Einstellungen (Credential-Name daraus)
    $tenant = if ($Tenant) { $Tenant } else { $script:Settings.tenants | Where-Object { $_.key -eq $TenantKey } | Select-Object -First 1 }
    $setObj = if ($Tenant) { [pscustomobject]@{ tenants = @($Tenant); credentials = $script:Settings.credentials } } else { $script:Settings }
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Client Secret" Width="540" SizeToContent="Height" WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        Background="#1E1E1E" ShowInTaskbar="False">
    <Window.Resources>
        <!--HU:THEME-->
    </Window.Resources>
    <StackPanel Margin="18">
        <TextBlock x:Name="lblTitle" Style="{StaticResource SectionTitle}"/>
        <TextBlock Style="{StaticResource HintText}" FontSize="11" Margin="0,0,0,12"
                   Text="Neues Secret: Entra Admin Center &gt; App-Registrierungen &gt; App &gt; Zertifikate &amp; Geheimnisse &gt; Neuer geheimer Clientschluessel. Den WERT (nicht die ID) hier einfuegen."/>
        <TextBlock Text="Client Secret (Wert)" Style="{StaticResource FieldLabel}" Margin="0,0,0,3"/>
        <PasswordBox x:Name="pwd" Style="{StaticResource DarkPasswordBox}" FontSize="12"/>
        <TextBlock Text="Gueltig bis (optional, TT.MM.JJJJ - nur noetig, wenn die App kein Application.Read.All hat)" Style="{StaticResource FieldLabel}" Margin="0,12,0,3"/>
        <TextBox x:Name="txtExpires" Style="{StaticResource DarkTextBox}" FontSize="12" Width="140" HorizontalAlignment="Left"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
            <Button x:Name="btnEntra" Content="Entra Admin Center" Style="{StaticResource ToolButton}" Margin="0,0,8,0"/>
            <Button x:Name="btnOk" Content="Speichern" Width="100" Background="#4CAF50" Style="{StaticResource DarkButton}" IsDefault="True" Margin="0,0,8,0"/>
            <Button x:Name="btnCancel" Content="Abbrechen" Width="100" Background="#555555" Style="{StaticResource DarkButton}" IsCancel="True"/>
        </StackPanel>
    </StackPanel>
</Window>
'@
    $theme = Get-HUXaml 'Theme'
    $m = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
    $d = New-HUWindow -XamlText ($x.Replace('<!--HU:THEME-->', $m.Groups[1].Value))
    $w = $d.Window; $c = $d.C
    if ($Owner) { try { $w.Owner = $Owner } catch { } }
    $c.lblTitle.Text = "Client Secret fuer $(if ($tenant) { $tenant.displayName } else { $TenantKey })"
    if ($tenant -and $tenant.PSObject.Properties['secretExpires'] -and "$($tenant.secretExpires)") {
        try { $c.txtExpires.Text = ([datetime]::Parse("$($tenant.secretExpires)", [Globalization.CultureInfo]::InvariantCulture)).ToString('dd.MM.yyyy') } catch { }
    }
    $st = @{ Result = $null }
    $c.btnEntra.Add_Click({
        $appId = if ($tenant) { "$($tenant.appId)" } else { '' }
        Open-HUUrl $(if ($appId -match '^[0-9a-fA-F-]{36}$') { "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/Credentials/appId/$appId" } else { 'https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade' })
    })
    $c.btnOk.Add_Click({
        $exp = ''
        $et = $c.txtExpires.Text.Trim()
        if ($et) {
            $dt = [datetime]::MinValue
            if (-not [datetime]::TryParseExact($et, @('dd.MM.yyyy', 'd.M.yyyy', 'yyyy-MM-dd'), [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$dt)) {
                Show-HUMessage 'Datum bitte als TT.MM.JJJJ eingeben (oder leer lassen).' -Icon Warning -Owner $w; return
            }
            $exp = $dt.ToString('yyyy-MM-dd')
        }
        $pw = $c.pwd.Password
        if ($pw) {
            if (-not (Save-StoredCredential -TenantKey $TenantKey -SecretValue $pw -Settings $setObj)) { Show-HUMessage 'Secret konnte nicht gespeichert werden.' -Icon Error -Owner $w; return }
            Clear-HUSecretState -TenantKey $TenantKey
            Write-HULogOK "Neues Client Secret gespeichert" -Tenant $TenantKey
        }
        $st.Result = [pscustomobject]@{ Saved = [bool]$pw; Expires = $exp }
        $w.Close()
    })
    $w.Add_ContentRendered({ $c.pwd.Focus() })
    [void]$w.ShowDialog()
    return $st.Result
}
