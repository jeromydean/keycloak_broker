#Requires -Version 5.1
<#
.SYNOPSIS
  Provisions Keycloak for the multi-tenant broker POC (docker-compose stack).

.DESCRIPTION
  - On onprem_1 and onprem_2: realm "onprem", OIDC client "cloud-broker" for the cloud IdP,
    and tenant users (onprem1_user / onprem2_user) with email, first name, and last name
    (defaults derived from username; optional overrides via User1*/User2* profile parameters).
  - On cloud_idp: realm "cloud", two OIDC identity providers (onprem-1, onprem-2) with
    username template "${ALIAS}.${CLAIM.preferred_username}", and a public "test-client"
    for interactive / MSAL-style OIDC from the host.
  - On cloud realm: Keycloak Organizations enabled; organizations org1 / org2 linked to IdPs
    onprem-1 and onprem-2 (linked organization in admin UI).

  Run from the repository root after: docker compose up -d
  Server must support the Organization feature (Keycloak 25+; enable in Admin if required).
  Requires: PowerShell 7+ recommended. Default bases use HTTPS on the host-trusted dev certs
  from initial-setup.ps1; broker backchannel from the cloud container uses plain HTTP on
  dedicated host ports (see docker-compose).

.NOTES
  Authorization URLs use HTTPS on localhost (browser / MSAL). Token / JWKS / userinfo from
  the cloud container use http://host.docker.internal:<backchannel-port> (see parameters below).
#>
[CmdletBinding()]
param(
  [string] $OnPrem1PublicBase = "https://localhost:8181",
  [string] $OnPrem2PublicBase = "https://localhost:8282",
  [string] $CloudPublicBase = "https://localhost:8080",

  # Management interface (KC_HTTP_MANAGEMENT_PORT); /health/* is served here over HTTPS when TLS is enabled (same dev certs).
  [string] $OnPrem1ManagementBase = "https://localhost:9191",
  [string] $OnPrem2ManagementBase = "https://localhost:9292",
  [string] $CloudManagementBase = "https://localhost:9090",

  # HTTP only: mapped to Keycloak's internal 8080 (docker-compose backchannel ports).
  [string] $OnPrem1DockerReachableBase = "http://host.docker.internal:8182",
  [string] $OnPrem2DockerReachableBase = "http://host.docker.internal:8283",

  [string] $OnPremRealm = "onprem",
  [string] $CloudRealm = "cloud",

  [string] $AdminUser = "admin",
  [string] $AdminPassword = "admin",

  [string] $BrokerClientId = "cloud-broker",
  [string] $BrokerSecretOnPrem1 = "broker-secret-onprem-1",
  [string] $BrokerSecretOnPrem2 = "broker-secret-onprem-2",

  [string] $IdpAlias1 = "onprem-1",
  [string] $IdpAlias2 = "onprem-2",

  [string] $Org1Alias = "org1",
  [string] $Org2Alias = "org2",
  [string] $Org1DisplayName = "Organization 1",
  [string] $Org2DisplayName = "Organization 2",

  # At least one domain is required by Keycloak when creating an organization (POC placeholders).
  [string] $Org1DomainName = "org1.poc.local",
  [string] $Org2DomainName = "org2.poc.local",

  [string] $User1Name = "onprem1_user",
  [string] $User1Password = "onprem1_password",
  [string] $User2Name = "onprem2_user",
  [string] $User2Password = "onprem2_password",

  # Optional profile fields (email, firstName, lastName). Omitted values are derived from the username.
  [string] $User1Email = $null,
  [string] $User1FirstName = $null,
  [string] $User1LastName = $null,
  [string] $User2Email = $null,
  [string] $User2FirstName = $null,
  [string] $User2LastName = $null,

  [string] $TestClientId = "test-client",

  # Public client on each onprem realm for MSAL (interactive / system browser); redirect matches TestClient RedirectUri.
  [string] $MsalOnPremClientId = "msal-onprem",
  [int] $KeycloakReadyTimeoutSec = 180
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-AdminToken {
  param([string] $KeycloakBase)
  $body = @{
    grant_type    = "password"
    client_id     = "admin-cli"
    username      = $AdminUser
    password      = $AdminPassword
  }
  $tokenUri = "$KeycloakBase/realms/master/protocol/openid-connect/token"
  $resp = Invoke-RestMethod -Method Post -Uri $tokenUri -Body $body -ContentType "application/x-www-form-urlencoded"
  return $resp.access_token
}

function Wait-KeycloakReady {
  param(
    [string] $ManagementBase,
    [string] $Label,
    [int] $TimeoutSec
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  $healthUri = "$ManagementBase/health/ready"
  Write-Host "Waiting for $healthUri ($Label) ..."
  while ((Get-Date) -lt $deadline) {
    try {
      $r = Invoke-WebRequest -Uri $healthUri -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
      if ($r.StatusCode -eq 200) {
        Write-Host "  OK: $Label"
        return
      }
    }
    catch {
      Start-Sleep -Seconds 3
    }
  }
  throw "Keycloak did not become ready within ${TimeoutSec}s: $healthUri ($Label)"
}

function Invoke-KeycloakAdmin {
  param(
    [string] $Method,
    [string] $KeycloakBase,
    [string] $Path,
    [string] $Token,
    $Body = $null
  )
  $uri = "$KeycloakBase/admin$Path"
  $headers = @{ Authorization = "Bearer $Token" }
  if ($null -eq $Body) {
    return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
  }
  return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -Body ($Body | ConvertTo-Json -Depth 20) -ContentType "application/json"
}

function Test-RealmExists {
  param([string] $KeycloakBase, [string] $Token, [string] $Realm)
  try {
    Invoke-RestMethod -Method Get -Uri "$KeycloakBase/admin/realms/$Realm" -Headers @{ Authorization = "Bearer $Token" } -ErrorAction Stop | Out-Null
    return $true
  }
  catch {
    return $false
  }
}

function New-RealmIfMissing {
  param([string] $KeycloakBase, [string] $Token, [hashtable] $RealmRep)
  $name = $RealmRep.realm
  if (Test-RealmExists -KeycloakBase $KeycloakBase -Token $Token -Realm $name) {
    Write-Host "Realm '$name' already exists on $KeycloakBase"
    return
  }
  Invoke-KeycloakAdmin -Method Post -KeycloakBase $KeycloakBase -Path "/realms" -Token $Token -Body $RealmRep
  Write-Host "Created realm '$name' on $KeycloakBase"
}

function Get-ClientUuid {
  param([string] $KeycloakBase, [string] $Token, [string] $Realm, [string] $ClientId)
  $list = Invoke-KeycloakAdmin -Method Get -KeycloakBase $KeycloakBase -Path "/realms/$Realm/clients?clientId=$ClientId" -Token $Token
  if (-not $list -or $list.Count -eq 0) { return $null }
  return $list[0].id
}

function New-BrokerClientIfMissing {
  param(
    [string] $KeycloakBase,
    [string] $Token,
    [string] $Realm,
    [string] $ClientId,
    [string] $Secret,
    [string[]] $RedirectUris
  )
  $existing = Get-ClientUuid -KeycloakBase $KeycloakBase -Token $Token -Realm $Realm -ClientId $ClientId
  if ($existing) {
    Write-Host "  Client '$ClientId' already exists in $Realm"
    return
  }
  $client = @{
    clientId                    = $ClientId
    name                        = "Cloud broker (OIDC)"
    enabled                     = $true
    protocol                    = "openid-connect"
    publicClient                = $false
    secret                      = $Secret
    redirectUris                = $RedirectUris
    webOrigins                  = @("+")
    standardFlowEnabled         = $true
    directAccessGrantsEnabled   = $true
    serviceAccountsEnabled      = $false
  }
  Invoke-KeycloakAdmin -Method Post -KeycloakBase $KeycloakBase -Path "/realms/$Realm/clients" -Token $Token -Body $client
  Write-Host "  Created client '$ClientId' in $Realm"
}

function New-MsalPublicClientIfMissing {
  param(
    [string] $KeycloakBase,
    [string] $Token,
    [string] $Realm,
    [string] $ClientId
  )
  $existing = Get-ClientUuid -KeycloakBase $KeycloakBase -Token $Token -Realm $Realm -ClientId $ClientId
  if ($existing) {
    Write-Host "  MSAL public client '$ClientId' already exists in $Realm"
    return
  }
  $client = @{
    clientId                    = $ClientId
    name                        = "MSAL desktop / console (public)"
    enabled                     = $true
    protocol                    = "openid-connect"
    publicClient                = $true
    # MSAL uses loopback with an ephemeral port; paths may include trailing slash.
    redirectUris                = @(
      "http://localhost",
      "http://localhost/*",
      "http://127.0.0.1",
      "http://127.0.0.1/*"
    )
    webOrigins                  = @("+")
    standardFlowEnabled         = $true
    directAccessGrantsEnabled   = $false
  }
  Invoke-KeycloakAdmin -Method Post -KeycloakBase $KeycloakBase -Path "/realms/$Realm/clients" -Token $Token -Body $client
  Write-Host "  Created MSAL public client '$ClientId' (loopback redirects for interactive login)"
}

function Resolve-UserProfileFields {
  param(
    [string] $Username,
    [string] $Email,
    [string] $FirstName,
    [string] $LastName
  )
  $ti = [System.Globalization.CultureInfo]::InvariantCulture.TextInfo
  if ([string]::IsNullOrWhiteSpace($Email)) {
    $Email = "$Username@poc.local"
  }
  $segments = @($Username -split '_' | Where-Object { $_ })
  if ([string]::IsNullOrWhiteSpace($FirstName)) {
    if ($segments.Count -ge 2) {
      $FirstName = $ti.ToTitleCase($segments[0].ToLowerInvariant())
    }
    else {
      $FirstName = $ti.ToTitleCase($Username.ToLowerInvariant())
    }
  }
  if ([string]::IsNullOrWhiteSpace($LastName)) {
    if ($segments.Count -ge 2) {
      $rest = $segments[1..($segments.Count - 1)] -join ' '
      $LastName = $ti.ToTitleCase($rest.ToLowerInvariant())
    }
    else {
      $LastName = "User"
    }
  }
  return @{
    Email     = $Email
    FirstName = $FirstName
    LastName  = $LastName
  }
}

function New-UserIfMissing {
  param(
    [string] $KeycloakBase,
    [string] $Token,
    [string] $Realm,
    [string] $Username,
    [string] $Password,
    [string] $Email = $null,
    [string] $FirstName = $null,
    [string] $LastName = $null
  )
  $profile = Resolve-UserProfileFields -Username $Username -Email $Email -FirstName $FirstName -LastName $LastName
  $Email = $profile.Email
  $FirstName = $profile.FirstName
  $LastName = $profile.LastName

  $headers = @{ Authorization = "Bearer $Token" }
  $search = Invoke-RestMethod -Method Get -Uri "$KeycloakBase/admin/realms/$Realm/users?username=$Username&exact=true" `
    -Headers $headers
  if ($search -and $search.Count -gt 0) {
    $userId = $search[0].id
    $uri = "$KeycloakBase/admin/realms/$Realm/users/$userId"
    $rep = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
    $dirty = $false
    if ([string]::IsNullOrWhiteSpace($rep.email)) {
      $rep.email = $Email
      $dirty = $true
    }
    if ([string]::IsNullOrWhiteSpace($rep.firstName)) {
      $rep.firstName = $FirstName
      $dirty = $true
    }
    if ([string]::IsNullOrWhiteSpace($rep.lastName)) {
      $rep.lastName = $LastName
      $dirty = $true
    }
    if ($dirty) {
      $rep.emailVerified = $true
      $json = $rep | ConvertTo-Json -Depth 10
      Invoke-RestMethod -Method Put -Uri $uri -Headers $headers -Body $json -ContentType "application/json"
      Write-Host "  Updated profile for existing user '$Username' in $Realm ($FirstName $LastName, $Email)"
    }
    else {
      Write-Host "  User '$Username' already exists in $Realm"
    }
    return
  }

  $user = @{
    username      = $Username
    email         = $Email
    firstName     = $FirstName
    lastName      = $LastName
    enabled       = $true
    emailVerified = $true
    credentials   = @(
      @{ type = "password"; value = $Password; temporary = $false }
    )
  }
  Invoke-KeycloakAdmin -Method Post -KeycloakBase $KeycloakBase -Path "/realms/$Realm/users" -Token $Token -Body $user
  Write-Host "  Created user '$Username' in $Realm ($FirstName $LastName, $Email)"
}

function Get-IdpAliasList {
  param([string] $KeycloakBase, [string] $Token, [string] $Realm)
  return Invoke-KeycloakAdmin -Method Get -KeycloakBase $KeycloakBase -Path "/realms/$Realm/identity-provider/instances" -Token $Token
}

function New-OidcIdentityProviderIfMissing {
  param(
    [string] $CloudBase,
    [string] $Token,
    [string] $Realm,
    [string] $Alias,
    [string] $DisplayName,
    [string] $ClientId,
    [string] $ClientSecret,
    [string] $AuthBasePublic,
    [string] $BackchannelBase
  )
  $existing = Get-IdpAliasList -KeycloakBase $CloudBase -Token $Token -Realm $Realm
  foreach ($p in $existing) {
    if ($p.alias -eq $Alias) {
      Write-Host "  IdP '$Alias' already exists in realm '$Realm'"
      return
    }
  }

  $issuer = "$AuthBasePublic/realms/$OnPremRealm"
  $config = @{
    clientId                           = $ClientId
    clientSecret                       = $ClientSecret
    authorizationUrl                   = "$AuthBasePublic/realms/$OnPremRealm/protocol/openid-connect/auth"
    tokenUrl                           = "$BackchannelBase/realms/$OnPremRealm/protocol/openid-connect/token"
    userInfoUrl                        = "$BackchannelBase/realms/$OnPremRealm/protocol/openid-connect/userinfo"
    jwksUrl                            = "$BackchannelBase/realms/$OnPremRealm/protocol/openid-connect/certs"
    issuer                             = $issuer
    validateSignature                  = "true"
    useJwksUrl                         = "true"
    clientAuthMethod                   = "client_secret_post"
    defaultScope                       = "openid profile email"
    syncMode                           = "IMPORT"
    hideOnLoginPage                    = "false"
    backchannelSupported               = "false"
    disableUserInfo                    = "false"
    passMaxAge                         = "false"
    uiLocales                          = "false"
    pkceEnabled                        = "true"
    pkceMethod                         = "S256"
  }

  $idp = @{
    alias         = $Alias
    displayName   = $DisplayName
    providerId    = "oidc"
    enabled       = $true
    trustEmail    = $true
    storeToken    = $false
    linkOnly      = $false
    firstBrokerLoginFlowAlias = "first broker login"
    config        = $config
  }

  Invoke-KeycloakAdmin -Method Post -KeycloakBase $CloudBase -Path "/realms/$Realm/identity-provider/instances" -Token $Token -Body $idp
  Write-Host "  Created OIDC IdP '$Alias' -> $issuer"
}

function New-UsernameTemplateMapperIfMissing {
  param(
    [string] $CloudBase,
    [string] $Token,
    [string] $Realm,
    [string] $IdpAlias
  )
  $mappers = Invoke-KeycloakAdmin -Method Get -KeycloakBase $CloudBase `
    -Path "/realms/$Realm/identity-provider/instances/$IdpAlias/mappers" -Token $Token
  foreach ($m in $mappers) {
    if ($m.name -eq "username-template-tenant") { return }
  }

  $mapper = @{
    name                         = "username-template-tenant"
    identityProviderAlias        = $IdpAlias
    identityProviderMapper       = "username-template-importer"
    config                       = @{
      template = '${ALIAS}.${CLAIM.preferred_username}'
    }
  }
  Invoke-KeycloakAdmin -Method Post -KeycloakBase $CloudBase `
    -Path "/realms/$Realm/identity-provider/instances/$IdpAlias/mappers" -Token $Token -Body $mapper
  Write-Host "  Added username template mapper on IdP '$IdpAlias'"
}

function New-TestClientIfMissing {
  param([string] $CloudBase, [string] $Token, [string] $Realm, [string] $ClientId)
  $existing = Get-ClientUuid -KeycloakBase $CloudBase -Token $Token -Realm $Realm -ClientId $ClientId
  if ($existing) {
    Write-Host "  Client '$ClientId' already exists in $Realm"
    return
  }
  $client = @{
    clientId                    = $ClientId
    name                        = "POC public client (host / MSAL)"
    enabled                     = $true
    protocol                    = "openid-connect"
    publicClient                = $true
    redirectUris                = @("*")
    webOrigins                  = @("+")
    standardFlowEnabled         = $true
    directAccessGrantsEnabled   = $true
  }
  Invoke-KeycloakAdmin -Method Post -KeycloakBase $CloudBase -Path "/realms/$Realm/clients" -Token $Token -Body $client
  Write-Host "  Created public client '$ClientId' (redirect URIs: * - POC only)"
}

function Enable-RealmOrganizationsIfNeeded {
  param(
    [string] $CloudBase,
    [string] $Token,
    [string] $Realm
  )
  $headers = @{ Authorization = "Bearer $Token" }
  $realmObj = Invoke-RestMethod -Method Get -Uri "$CloudBase/admin/realms/$Realm" -Headers $headers
  if ($realmObj.organizationsEnabled -eq $true) {
    Write-Host "  Organizations already enabled on realm '$Realm'"
    return
  }
  if ($realmObj.PSObject.Properties.Name -contains "organizationsEnabled") {
    $realmObj.organizationsEnabled = $true
  }
  else {
    $realmObj | Add-Member -NotePropertyName organizationsEnabled -NotePropertyValue $true -Force
  }
  $json = $realmObj | ConvertTo-Json -Depth 100
  Invoke-RestMethod -Method Put -Uri "$CloudBase/admin/realms/$Realm" -Headers $headers -Body $json -ContentType "application/json"
  Write-Host "  Enabled organizations on realm '$Realm' (organizationsEnabled=true)"
}

function Get-OrganizationIdByAlias {
  param(
    [string] $CloudBase,
    [string] $Token,
    [string] $Realm,
    [string] $Alias
  )
  $headers = @{ Authorization = "Bearer $Token" }
  # Keycloak "search" matches organization *name* or *domain*, not alias. List and filter by alias.
  $uri = "$CloudBase/admin/realms/$Realm/organizations?first=0&max=500&briefRepresentation=true"
  try {
    $list = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
  }
  catch {
    return $null
  }
  if ($null -eq $list) {
    return $null
  }
  if ($list -isnot [System.Array]) {
    $list = @($list)
  }
  foreach ($o in $list) {
    if ($o.alias -eq $Alias) {
      return $o.id
    }
  }
  return $null
}

function New-OrganizationIfMissing {
  param(
    [string] $CloudBase,
    [string] $Token,
    [string] $Realm,
    [string] $Alias,
    [string] $Name,
    [string] $RedirectUrl,
    [string] $Description,
    [string] $DomainName
  )
  $existingId = Get-OrganizationIdByAlias -CloudBase $CloudBase -Token $Token -Realm $Realm -Alias $Alias
  if ($existingId) {
    Write-Host "  Organization '$Alias' already exists (id=$existingId)"
    return $existingId
  }
  $body = @{
    name        = $Name
    alias       = $Alias
    enabled     = $true
    description = $Description
    redirectUrl = $RedirectUrl
    domains     = @(
      @{ name = $DomainName; verified = $false }
    )
  }
  $headers = @{ Authorization = "Bearer $Token" }
  $jsonBody = $body | ConvertTo-Json -Depth 6
  $resp = Invoke-WebRequest -Method Post -Uri "$CloudBase/admin/realms/$Realm/organizations" `
    -Headers $headers -Body $jsonBody -ContentType "application/json" -UseBasicParsing
  if ($resp.StatusCode -ne 201) {
    throw "Create organization failed: $($resp.StatusCode) $($resp.Content)"
  }
  $loc = $resp.Headers["Location"]
  if (-not $loc) {
    throw "Create organization succeeded but no Location header"
  }
  $orgId = ($loc.TrimEnd("/") -split "/")[-1]
  Write-Host "  Created organization '$Alias' ($Name) id=$orgId"
  return $orgId
}

function Get-KeycloakAdminErrorBody {
  param($ErrorRecord)
  if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
    return $ErrorRecord.ErrorDetails.Message
  }
  $r = $ErrorRecord.Exception.Response
  if (-not $r) { return $null }
  try {
    if ($r -is [System.Net.Http.HttpResponseMessage]) {
      return $r.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    }
    $reader = [System.IO.StreamReader]::new($r.GetResponseStream())
    $text = $reader.ReadToEnd()
    $reader.Dispose()
    return $text
  }
  catch {
    return $null
  }
}

function Add-IdentityProviderToOrganizationIfMissing {
  param(
    [string] $CloudBase,
    [string] $Token,
    [string] $Realm,
    [string] $OrganizationId,
    [string] $IdpAlias
  )
  # Admin console links an IdP to an org by PUT /identity-provider/instances/{alias} with
  # IdentityProviderRepresentation.organizationId set (full body from GET, not POST .../organizations/.../identity-providers).
  $headers = @{ Authorization = "Bearer $Token" }
  $idpUri = "$CloudBase/admin/realms/$Realm/identity-provider/instances/$IdpAlias"
  try {
    $idp = Invoke-RestMethod -Method Get -Uri $idpUri -Headers $headers
  }
  catch {
    $err = Get-KeycloakAdminErrorBody -ErrorRecord $_
    throw "Cannot load IdP '$IdpAlias' for org link: $($_.Exception.Message) $err"
  }
  $currentOrg = $null
  if ($idp.PSObject.Properties.Name -contains "organizationId") {
    $currentOrg = $idp.organizationId
  }
  if ($currentOrg -and [string]$currentOrg -ieq [string]$OrganizationId) {
    Write-Host "  IdP '$IdpAlias' already linked to organization id=$OrganizationId"
    return
  }
  if ($idp.PSObject.Properties.Name -contains "organizationId") {
    $idp.organizationId = $OrganizationId
  }
  else {
    $idp | Add-Member -NotePropertyName organizationId -NotePropertyValue $OrganizationId -Force
  }
  $json = $idp | ConvertTo-Json -Depth 30 -Compress
  try {
    Invoke-WebRequest -Method Put -Uri $idpUri -Headers $headers -Body $json `
      -ContentType "application/json; charset=utf-8" -UseBasicParsing | Out-Null
    Write-Host "  Linked IdP '$IdpAlias' to organization id=$OrganizationId (PUT identity-provider/instances, same as admin UI)"
  }
  catch {
    $status = $null
    if ($_.Exception.Response) {
      $status = [int]$_.Exception.Response.StatusCode
    }
    $errBody = Get-KeycloakAdminErrorBody -ErrorRecord $_
    throw "Link IdP '$IdpAlias' to org $OrganizationId failed (HTTP $status): $errBody"
  }
}

# --- Main ---
Wait-KeycloakReady -ManagementBase $OnPrem1ManagementBase -Label "onprem_1" -TimeoutSec $KeycloakReadyTimeoutSec
Wait-KeycloakReady -ManagementBase $OnPrem2ManagementBase -Label "onprem_2" -TimeoutSec $KeycloakReadyTimeoutSec
Wait-KeycloakReady -ManagementBase $CloudManagementBase -Label "cloud_idp" -TimeoutSec $KeycloakReadyTimeoutSec

$token1 = Get-AdminToken -KeycloakBase $OnPrem1PublicBase
$token2 = Get-AdminToken -KeycloakBase $OnPrem2PublicBase
$tokenCloud = Get-AdminToken -KeycloakBase $CloudPublicBase

$onPremRealmRep = @{
  realm         = $OnPremRealm
  enabled       = $true
  displayName   = "On-Prem (customer IdP)"
  loginWithEmailAllowed = $true
  duplicateEmailsAllowed = $false
}

Write-Host "`n=== On-prem 1 ($OnPrem1PublicBase) ==="
New-RealmIfMissing -KeycloakBase $OnPrem1PublicBase -Token $token1 -RealmRep $onPremRealmRep
$brokerRedirect1 = "$CloudPublicBase/realms/$CloudRealm/broker/$IdpAlias1/endpoint"
New-BrokerClientIfMissing -KeycloakBase $OnPrem1PublicBase -Token $token1 -Realm $OnPremRealm `
  -ClientId $BrokerClientId -Secret $BrokerSecretOnPrem1 -RedirectUris @($brokerRedirect1)
New-UserIfMissing -KeycloakBase $OnPrem1PublicBase -Token $token1 -Realm $OnPremRealm `
  -Username $User1Name -Password $User1Password `
  -Email $User1Email -FirstName $User1FirstName -LastName $User1LastName
New-MsalPublicClientIfMissing -KeycloakBase $OnPrem1PublicBase -Token $token1 -Realm $OnPremRealm -ClientId $MsalOnPremClientId

Write-Host "`n=== On-prem 2 ($OnPrem2PublicBase) ==="
New-RealmIfMissing -KeycloakBase $OnPrem2PublicBase -Token $token2 -RealmRep $onPremRealmRep
$brokerRedirect2 = "$CloudPublicBase/realms/$CloudRealm/broker/$IdpAlias2/endpoint"
New-BrokerClientIfMissing -KeycloakBase $OnPrem2PublicBase -Token $token2 -Realm $OnPremRealm `
  -ClientId $BrokerClientId -Secret $BrokerSecretOnPrem2 -RedirectUris @($brokerRedirect2)
New-UserIfMissing -KeycloakBase $OnPrem2PublicBase -Token $token2 -Realm $OnPremRealm `
  -Username $User2Name -Password $User2Password `
  -Email $User2Email -FirstName $User2FirstName -LastName $User2LastName
New-MsalPublicClientIfMissing -KeycloakBase $OnPrem2PublicBase -Token $token2 -Realm $OnPremRealm -ClientId $MsalOnPremClientId

Write-Host "`n=== Cloud ($CloudPublicBase) realm '$CloudRealm' ==="
$cloudRealmRep = @{
  realm                  = $CloudRealm
  enabled                = $true
  displayName            = "Cloud (broker / SaaS)"
  loginWithEmailAllowed  = $true
  duplicateEmailsAllowed = $false
  sslRequired            = "none"
}
New-RealmIfMissing -KeycloakBase $CloudPublicBase -Token $tokenCloud -RealmRep $cloudRealmRep

Enable-RealmOrganizationsIfNeeded -CloudBase $CloudPublicBase -Token $tokenCloud -Realm $CloudRealm

$orgAccountRedirect = "$CloudPublicBase/realms/$CloudRealm/account"
$org1Id = New-OrganizationIfMissing -CloudBase $CloudPublicBase -Token $tokenCloud -Realm $CloudRealm `
  -Alias $Org1Alias -Name $Org1DisplayName -RedirectUrl $orgAccountRedirect `
  -Description "Tenant for onprem_1; IdP $IdpAlias1" -DomainName $Org1DomainName
$org2Id = New-OrganizationIfMissing -CloudBase $CloudPublicBase -Token $tokenCloud -Realm $CloudRealm `
  -Alias $Org2Alias -Name $Org2DisplayName -RedirectUrl $orgAccountRedirect `
  -Description "Tenant for onprem_2; IdP $IdpAlias2" -DomainName $Org2DomainName

New-OidcIdentityProviderIfMissing -CloudBase $CloudPublicBase -Token $tokenCloud -Realm $CloudRealm `
  -Alias $IdpAlias1 -DisplayName "Customer On-Prem 1" -ClientId $BrokerClientId -ClientSecret $BrokerSecretOnPrem1 `
  -AuthBasePublic $OnPrem1PublicBase -BackchannelBase $OnPrem1DockerReachableBase

New-OidcIdentityProviderIfMissing -CloudBase $CloudPublicBase -Token $tokenCloud -Realm $CloudRealm `
  -Alias $IdpAlias2 -DisplayName "Customer On-Prem 2" -ClientId $BrokerClientId -ClientSecret $BrokerSecretOnPrem2 `
  -AuthBasePublic $OnPrem2PublicBase -BackchannelBase $OnPrem2DockerReachableBase

New-UsernameTemplateMapperIfMissing -CloudBase $CloudPublicBase -Token $tokenCloud -Realm $CloudRealm -IdpAlias $IdpAlias1
New-UsernameTemplateMapperIfMissing -CloudBase $CloudPublicBase -Token $tokenCloud -Realm $CloudRealm -IdpAlias $IdpAlias2

if (-not $org1Id) {
  $org1Id = Get-OrganizationIdByAlias -CloudBase $CloudPublicBase -Token $tokenCloud -Realm $CloudRealm -Alias $Org1Alias
}
if (-not $org2Id) {
  $org2Id = Get-OrganizationIdByAlias -CloudBase $CloudPublicBase -Token $tokenCloud -Realm $CloudRealm -Alias $Org2Alias
}
if ($org1Id) {
  Add-IdentityProviderToOrganizationIfMissing -CloudBase $CloudPublicBase -Token $tokenCloud -Realm $CloudRealm `
    -OrganizationId $org1Id -IdpAlias $IdpAlias1
}
else {
  Write-Warning "Organization '$Org1Alias' not found; skip linking IdP '$IdpAlias1'."
}
if ($org2Id) {
  Add-IdentityProviderToOrganizationIfMissing -CloudBase $CloudPublicBase -Token $tokenCloud -Realm $CloudRealm `
    -OrganizationId $org2Id -IdpAlias $IdpAlias2
}
else {
  Write-Warning "Organization '$Org2Alias' not found; skip linking IdP '$IdpAlias2'."
}

New-TestClientIfMissing -CloudBase $CloudPublicBase -Token $tokenCloud -Realm $CloudRealm -ClientId $TestClientId

Write-Host "`nDone."
Write-Host "  Cloud admin console:  $CloudPublicBase/admin (realm '$CloudRealm')"
Write-Host "  OIDC discovery:       $CloudPublicBase/realms/$CloudRealm/.well-known/openid-configuration"
Write-Host "  Test client id:       $TestClientId"
Write-Host "  MSAL on-prem client:  $MsalOnPremClientId (realm $OnPremRealm on 8181 / 8282)"
Write-Host "  On-prem users:        $User1Name / $User2Name"
Write-Host "  Organizations:        $Org1Alias ($IdpAlias1), $Org2Alias ($IdpAlias2)"
