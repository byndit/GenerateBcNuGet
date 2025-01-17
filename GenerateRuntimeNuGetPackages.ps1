Write-Host "Generate Runtime NuGet Packages"

. (Join-Path $PSScriptRoot "HelperFunctions.ps1")

$containerName = 'bcserver'

# Get apps and depenedencies
$appsFolder = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
$apps = @("$env:apps".Split(','))
$dependencies = @("$env:dependencies".Split(','))

$dependenciesFolder = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())

$fromNugetServerUrl = $env:fromNugetServerUrl
$fromNugetToken = $env:fromNugetToken
$fromDependencies = @("$env:fromDependencies".Split(','))
$fromApps = @("$env:fromApps".Split(','))

if ($fromNugetServerUrl -ne '' -and $fromNugetToken -ne '') {
    @($fromApps) | % {
        $packageParts = $_.Split(':')
        
        if ($fromApps.Count -eq 2) {
            $apps += Get-BcNuGetPackage -nuGetServerUrl $fromNugetServerUrl -nuGetToken $fromNugetToken -packageName $packageParts[0] -version $packageParts[1] -select Exact
        } else {
            $apps += Get-BcNuGetPackage -nuGetServerUrl $fromNugetServerUrl -nuGetToken $fromNugetToken -packageName $packageParts[0]
        }
    }
}


if ($fromNugetServerUrl -ne '' -and $fromNugetToken -ne '') {
    @($fromDependencies) | % {
        $dependencies += Get-BcNuGetPackage -nuGetServerUrl $fromNugetServerUrl -nuGetToken $fromNugetToken -packageName $_
    }
}

$apps = @(Copy-AppFilesToFolder -appFiles $apps -folder $appsFolder)
$dependencies = @(Copy-AppFilesToFolder -appFiles $dependencies -folder $dependenciesFolder)

# Get parameters from workflow (and dependent job)
$nuGetServerUrl, $githubRepository = GetNuGetServerUrlAndRepository -nuGetServerUrl $env:nuGetServerUrl
$nuGetToken = $env:nuGetToken
$country = $env:country
if ($country -eq '') { $country = 'w1' }
$additionalCountries = @("$env:additionalCountries".Split(',') | Where-Object { $_ -and $_ -ne $country })
$artifactType = $env:artifactType
if ($artifactType -eq '') { $artifactType = 'sandbox' }
# Artifact version is from the matrix
$artifactVersion = $env:artifactVersion
$incompatibleArtifactVersion = $env:incompatibleArtifactVersion

# Determine runtime dependency package ids for all apps and whether any of the apps doesn't exist as a nuGet package
$runtimeDependencyPackageIds, $newPackage = GetRuntimeDependencyPackageIds -apps $apps -nuGetServerUrl $nuGetServerUrl -nuGetToken $nuGetToken

$licenseFileUrl = $env:licenseFileUrl
if ([System.Version]$artifactVersion -ge [System.Version]'22.0.0.0') {
    $licenseFileUrl = ''
}

# Create Runtime packages for main country and additional countries
$runtimeAppFiles, $countrySpecificRuntimeAppFiles = GenerateRuntimeAppFiles -containerName $containerName -type $artifactType -country $country -additionalCountries $additionalCountries -artifactVersion $artifactVersion -apps $apps -dependencies $dependencies -licenseFileUrl $licenseFileUrl

# For every app create and push nuGet package (unless the exact version already exists)
foreach($appFile in $apps) {
    $appName = [System.IO.Path]::GetFileName($appFile)
    $runtimeDependencyPackageId = $runtimeDependencyPackageIds."$appName"
    $bcContainerHelperConfig.TrustedNuGetFeeds = @( 
        [PSCustomObject]@{ "url" = $nuGetServerUrl;  "token" = $nuGetToken; "Patterns" = @($runtimeDependencyPackageId) }
    )
    $package = Get-BcNuGetPackage -packageName $runtimeDependencyPackageId -version $artifactVersion -select Exact
    if (-not $package) {
        $runtimePackage = New-BcNuGetPackage -appfile $runtimeAppFiles."$appName" -countrySpecificAppFiles $countrySpecificRuntimeAppFiles."$appName" -packageId $runtimeDependencyPackageId -packageVersion $artifactVersion -applicationDependency "[$artifactVersion,$incompatibleArtifactVersion)" -githubRepository $githubRepository
        $cnt = 0
        while ($true) {
            try {
                $cnt++
                Push-BcNuGetPackage -nuGetServerUrl $nuGetServerUrl -nuGetToken $nuGetToken -bcNuGetPackage $runtimePackage
                break
            }
            catch {
                if ($cnt -eq 5 -or $_.Exception.Message -notlike '*409*') { throw $_ }
                Write-Host "Error pushing package: $($_.Exception.Message). Retry in 10 seconds"
                Start-Sleep -Seconds 10
            }
        }
    }
}
