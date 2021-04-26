#####################################################
# HelloID-Conn-Prov-Source-Generic-Scim
#
# Version: 1.0.0.0
#####################################################
$VerbosePreference = "Continue"

#Region Functions
function Get-GenericScimUsers {
    <#
    .SYNOPSIS
    Retrieves user data from a SCIM API <http://www.simplecloud.info/>

    .PARAMETER ClientID
    The ClientID for the SCIM API

    .PARAMETER ClientSecret
    The ClientSecret for the SCIM API

    .PARAMETER Uri
    The Uri to the SCIM API. <http://some-api/v1/scim>

    .PARAMETER IsConnectionTls12
    Adds TLS1.2 to the outgoing connection

    .PARAMETER PageSize
    The pagesize used for the SCIM endpoint. You will find this information within the API reference documentation
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $ClientID,

        [Parameter(Mandatory = $false)]
        [string]
        $ClientSecret,

        [Parameter(Mandatory = $false)]
        [string]
        $Uri,

        [Parameter(Mandatory = $false)]
        [bool]
        $IsConnectionTls12,

        [Parameter(Mandatory = $false)]
        [string]
        $PageSize
    )

    try {
        $accessToken = Get-GenericScimOAuthToken -ClientID $ClientID -ClientSecret $ClientSecret
    } catch {
        $ex = $PSItem
        Resolve-HTTPError -Error $ex
    }

    try {
        Write-Verbose "Invoking command '$($MyInvocation.MyCommand)'"
        Write-Verbose 'Adding Authorization headers'
        $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
        $headers.Add("Authorization", "Bearer $($accessToken)")
        $splatParams = @{
            Uri = $Uri
            Endpoint = 'Users'
            Headers = $headers
            IsConnectionTls12 = $IsConnectionTls12
            PageSize = $PageSize
        }
        $contractList = [System.Collections.Generic.List[object]]@()
        $users = Invoke-GenericScimRestMethod @splatParams | Select-GenericScimUserProperties
        Write-Verbose "Retrieved '$($users.count)' objects"
        foreach ($user in $users){
            $user | Add-Member -MemberType NoteProperty -Name 'DisplayName' -Value "$($user.nameFormatted)"
            $user | Add-Member -MemberType NoteProperty -Name Contracts -Value $contractList
            Write-Output $user | ConvertTo-Json
        }
    } catch {
        $ex = $PSItem
        if ( $($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')){
            $errorMessage = Resolve-HTTPError -Error $ex
            Write-Error "Could not retrieve users. Error $errorMessage"
        }
        else {
            Write-Error "Could not retrieve users. Error: $($ex.Exception.Message)"
        }
    }
}
#EndRegion

#Region Helper Functions
function Get-GenericScimOAuthToken {
    <#
    .SYNOPSIS
    Retrieves the OAuth token from a SCIM API <http://www.simplecloud.info/>

    .PARAMETER ClientID
    The ClientID for the SCIM API

    .PARAMETER ClientSecret
    The ClientSecret for the SCIM API
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]
        $ClientID,

        [Parameter(Mandatory = $true)]
        [string]
        $ClientSecret
    )

    try {
        Write-Verbose "Invoking command '$($MyInvocation.MyCommand)'"
        $headers = @{
            "content-type" = "application/x-www-form-urlencoded"
        }

        $body = @{
            client_id = $ClientID
            client_secret = $ClientSecret
            grant_type = "client_credentials"
        }

        $splatRestMethodParameters = @{
            Uri = $TokenUri
            Method = 'POST'
            Headers = $headers
            Body = $body
        }
        Invoke-RestMethod @splatRestMethodParameters
        Write-Verbose 'Finished retrieving accessToken'
    } catch {
        $PSCmdlet.ThrowTerminatingError($PSItem)
    }
}

function Invoke-GenericScimRestMethod {
    <#
    .SYNOPSIS
    Retrieves data from a SCIM API <http://www.simplecloud.info/>

    .PARAMETER Uri
    The Uri to the SCIM API. <http://some-api/v1/scim>

    .PARAMETER Endpoint
    The path to the specific endpoint being queried. The endpoints follow the standards of the SCIM implementation

    .PARAMETER Headers
    The headers containing the AccessToken

    .PARAMETER IsConnectionTls12
    Adds TLS1.2 to the outgoing connection

    .PARAMETER PageSize
    The pagesize used for the SCIM endpoint. You will find this information within the API reference documentation
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [Uri]
        $Uri,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Endpoint,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]
        $Headers,

        [Parameter(Mandatory = $false)]
        [bool]
        $IsConnectionTls12,

        [Parameter(Mandatory = $true)]
        [int]
        $PageSize
    )

    process {
        try {
            Write-Verbose "Invoking command '$($MyInvocation.MyCommand)' to endpoint '$Endpoint'"
            Write-Verbose "Setting 'Invoke-RestMethod' parameters: '$($PSBoundParameters.Keys)'"
            Write-Verbose "Setting the pagesize to '$PageSize'"
            $splatRestMethodParameters = @{
                Method = 'Get'
                ContentType = 'application/json'
                Headers = $Headers
            }

            if ($IsConnectionTls12){
                Write-Verbose 'Switching to TLS 1.2'
                [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
            }

            Write-Verbose "Checking total number of items for the /$($Endpoint) endpoint"
            try {
                $splatRestMethodParameters['Uri'] = "$Uri/$($Endpoint)"
                $totalResults = (Invoke-RestMethod @splatRestMethodParameters).totalResults
                Write-Verbose "Found '$totalResults' items in resource '$Endpoint'"
            } catch {
                $PSCmdlet.ThrowTerminatingError($PSItem)
            }

            [System.Collections.Generic.List[object]]$dataList = @()
            do {
                $startIndex = $dataList.Count
                $splatRestMethodParameters['Uri'] = "$Uri/$($Endpoint)?startIndex=$startIndex&count=$PageSize"
                $response = Invoke-RestMethod @splatRestMethodParameters
                foreach ($resource in $response.Resources){
                    $dataList.Add($resource)
                }
            } until ($dataList.Count -eq $totalResults)
            Write-Verbose 'Finished retrieving data'
            Write-Output $dataList
        } catch {
            $PSCmdlet.ThrowTerminatingError($PSItem)
        }
    }
}

function Select-GenericScimUserProperties {
    <#
    .SYNOPSIS
    Flattens a UserObject with nested hash tables's and array's

    .DESCRIPTION
    Flattens a UserObject with nested hash tables and array's like: emails and names, to a single flat PSObject

    .PARAMETER UserObject
    The UserObject containing the nested hash tables and array's

    .EXAMPLE
    Select-GenericScimUserProperties -UserObject $userObject

    Flattens the $userObject to a flat PSObject
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [PSObject]
        $UserObject
    )

    process {
        $properties = @(
            'userName'
            'id'
            'active'

            # Rename the 'externalId' property to 'ExternalId' for import in HelloID
            @{ Name = "ExternalId"; Expression = { $_.externalId }}

            foreach ($emailField in $UserObject.emails) {
                @{ Name = "$($emailField.type)EmailValue"; Expression = { $emailField.value }.GetNewClosure()}
                @{ Name = "$($emailField.type)EmailPrimary"; Expression = { $emailField.primary }.GetNewClosure()}
                @{ Name = "$($emailField.type)EmailDisplayName"; Expression = { $emailField.display }.GetNewClosure()}
            }

            foreach ($nameField in $UserObject.name) {
                @{ Name = "givenName"; Expression = { $nameField.givenName }}
                @{ Name = "familyName"; Expression = { $nameField.familyName }}
                @{ Name = "familyNamePrefix"; Expression = { $nameField.familyNamePrefix }}
                @{ Name = "nameFormatted"; Expression = { $nameField.formatted }}
            }

            foreach ($metaField in $UserObject.meta) {
                @{ Name = "resourceType"; Expression = { $metaField.resourceType }}
                @{ Name = "created"; Expression = { $metaField.created }}
                @{ Name = "location"; Expression = { $metaField.location }}
            }
        )
        Write-Output $UserObject | Select-Object -Property $properties
    }
}

function Resolve-HTTPError {
    <#
    .SYNOPSIS
    Resolves an HTTP error for both Windows PowerShell 5.1 and PowerShell 7.0.3 Core
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$ErrorObject
    )

    $HttpErrorObj = @{
        FullyQualifiedErrorId = $ErrorException.FullyQualifiedErrorId
        InvocationInfo = $ErrorObject.InvocationInfo.MyCommand
        TargetObject  = $ErrorObject.TargetObject.RequestUri
    }

    if ($ErrorObject.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException'){
        $HttpErrorObj['ErrorMessage'] = (($ErrorObject.ErrorDetails.Message) | ConvertFrom-Json).errors.message
    } elseif ($ErrorObject.Exception.GetType().FullName -eq 'System.Net.WebException'){
        $stream = $ErrorObject.Exception.Response.GetResponseStream()
        $stream.Position = 0
        $streamReader = New-Object System.IO.StreamReader $Stream
        $errorResponse = $StreamReader.ReadToEnd()
        $HttpErrorObj['ErrorMessage'] = ($errorResponse | ConvertFrom-Json).errors.message
    }

    Write-Output "'$($HttpErrorObj.ErrorMessage)', TargetObject: '$($HttpErrorObj.TargetObject), InvocationCommand: '$($HttpErrorObj.InvocationInfo)"
}
#EndRegion

$connectionSettings = ConvertFrom-Json $configuration
$splatParams = @{
    ClientID = $($connectionSettings.ClientID)
    ClientSecret = $($connectionSettings.ClientSecret)
    Uri = $($connectionSettings.BaseUrl)
    PageSize = $($connectionSettings.PageSize)
    IsConnectionTls12 = $($connectionSettings.IsConnectionTls12)
}
Get-GenericScimUsers @splatParams
