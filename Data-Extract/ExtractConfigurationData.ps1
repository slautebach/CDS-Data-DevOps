[CmdletBinding()]
param(
    [string] $ConnectionString,
    [string] $SharedViewName,
    [string] $DataExtractOutputFolder,
    [string] $ExtractFiledsAsFiles,
    [string] $ExtractFiledsRootFolder,
    [string] $ExtractFiledsConfigType,
    [string] $ExtractFiledsConfigFile,
    [string] $ExtractFiledsConfig,
    [Switch] $InteractiveLogin
)



Write-Verbose 'Entering ExtractConfiguratoinData.ps1'
Write-Verbose "ConnectionString = $ConnectionString"
Write-Verbose "SharedViewName = $SharedViewName"
Write-Verbose "DataExtractOutputFolder = $DataExtractOutputFolder"
Write-Verbose "ExtractFiledsAsFiles = $ExtractFiledsAsFiles"
Write-Verbose "ExtractFiledsRootFolder = $ExtractFiledsRootFolder"
Write-Verbose "ExtractFiledsConfigType = $ExtractFiledsConfigType"
Write-Verbose "ExtractFiledsConfigFile = $ExtractFiledsConfigFile"
Write-Verbose "ExtractFiledsConfig = $ExtractFiledsConfig"

if ($ExtractFiledsAsFiles -eq "true"){
    $ExtractFiledsAsFiles = $true
} else {
    $ExtractFiledsAsFiles = $false
}

Write-Verbose "Importing Module:  Microsoft.Xrm.DevOps.Data.PowerShell"
#Install-Module -Name Adoxio.Dynamics.DevOps -Scope CurrentUser 
Import-Module Microsoft.Xrm.DevOps.Data.PowerShell

Write-Verbose "Importing Module:  Microsoft.Xrm.Data.Powershell"
#Install-Module -Name Microsoft.Xrm.DevOps.Data.PowerShell -Scope CurrentUser 
Import-Module Microsoft.Xrm.Data.Powershell


#  Connect to CDS
if ($InteractiveLogin){
    $Conn = Get-CrmConnection  -Interactive
} else {
    $Conn = Get-CrmConnection  -ConnectionString $ConnectionString 
}

 $fetch=@"
 <fetch version='1.0' output-format='xml-platform' mapping='logical' distinct='false'>
  <entity name='userquery' >
    <attribute name='name' />
    <attribute name='fetchxml' />
    <attribute name='returnedtypecode' />
    <order attribute='name' descending='false' />
      <filter type='or'>
        <condition attribute='name' operator='eq' value='$SharedViewName' />
      </filter>
  </entity>
</fetch>
"@

 # get the results, and if non are found return null
 $dataFilterFetchResults = get-crmrecordsbyfetch  -conn $Conn -Fetch $fetch

 Write-Host "Retrieved $($dataFilterFetchResults.CrmRecords.Count) views across all entities with the name: $SharedViewName"
 
 
$allFetches = @()

foreach ($fetch in $dataFilterFetchResults.CrmRecords)
{
    $allFetches += $fetch.fetchxml
}

# Get all Relationship Queries
 $n2nUserQueries=@"
 <fetch version='1.0' output-format='xml-platform' mapping='logical' distinct='false'>
  <entity name='userquery' >
    <attribute name='name' />
   <attribute name='fetchxml' />
    <attribute name='returnedtypecode' />
    <order attribute='name' descending='false' />
      <filter type='or'>
        <condition attribute='name' operator='eq' value='$SharedViewName-N2N' />
      </filter>
  </entity>
</fetch>
"@

# get the results, and if non are found return null
$n2nResults = get-crmrecordsbyfetch  -conn $Conn -Fetch $n2nUserQueries
Write-Host "Retrieved $($n2nResults.CrmRecords.Count) N2N views across all entities with the name: $SharedViewName-N2N"


# From the N2N relationship queries extract the fetch and correct it so it will run
foreach ($n2nFetchRecord in $n2nResults.CrmRecords)
{
    $fetchFilterXml = [xml]$n2nFetchRecord.fetchxml
    $linkEntityNode = $fetchFilterXml.SelectSingleNode("fetch/entity/link-entity") 
    $relatedEntity = $fetchFilterXml.SelectSingleNode("fetch/entity/link-entity/link-entity") 
    $attribute = $fetchFilterXml.CreateElement("attribute")
    $attribute.SetAttribute("name", $relatedEntity.Attributes["to"].Value)
    $linkEntityNode.AppendChild($attribute)
    $allFetches += $fetchFilterXml.OuterXml
}

Write-Host "Going to Extract data for the following Fetch Queries:"
# Foreach of all the fetches.  Load it as an xml
# Format with indents for pretty printing for debuggin purposes.
 $allFetches| ForEach-Object {
    $prettyXml = Format-Xml -Xml $_
    Write-Host "=============================================================";
    Write-Host $prettyXml;
    Write-Host "=============================================================";
    Write-Host "";
    Write-Host "";
 }

 if (!(Test-Path -Path $DataExtractOutputFolder)){
    New-Item -ItemType Directory -Force -Path $DataExtractOutputFolder
 }


if ($DataExtractOutputFolder.EndsWith("\")){
    # remove the trailing "\"
    $DataExtractOutputFolder = $DataExtractOutputFolder.Substring(0, $DataExtractOutputFolder.Length -1)
}
#  Extract the Data Package from the Fetches.
$zipDataFile = "$DataExtractOutputFolder.zip"

Write-Host "Extracting data to zip file: $zipDataFile"
Get-CrmDataPackage -Conn $Conn -Fetches $allFetches -DisablePluginsGlobally $true  | Export-CrmDataPackage -ZipPath $zipDataFile

Remove-Item -Recurse -Force $DataExtractOutputFolder

# Expand the Data through the Adoxio Dev Ops Module.
Write-Host "Expanding $zipDataFile to '$DataExtractOutputFolder'"
Expand-CrmData  -ZipFile "$zipDataFile" -Folder $DataExtractOutputFolder


if (!($ExtractFiledsAsFiles)){
   # if we aren't to further extract filds from files, skip
    exit;
}

##########################
#
#  Region - Read all data files, and extract fields to files for comparision
#
##########################



if ($ExtractFiledsConfigType -eq "FilePath"){
    $ExtractFiledsConfig = (Get-Content -Path $ExtractFiledsConfigFile )  -join "`n" 
}
$EntityDataSourceFileConfig = $ExtractFiledsConfig | ConvertFrom-Json

# Load all new release data files
Write-Host "Loading Files From: $DataExtractOutputFolder"
$dataFiles = Get-ChildItem $DataExtractOutputFolder -recurse -file -filter "*.xml" 


# for each file process them.
foreach ($dataFile in $dataFiles){
    if (-not $dataFile.Directory.FullName.EndsWith("records")){
        continue;
    }
   
    # get the logical name which is the parent folder name.
    $entityLogicalName = $dataFile.Directory.Parent.Name

    # if the entity doesn't exist in the extraction configuration
    # skip to the next file
    if ($EntityDataSourceFileConfig.$entityLogicalName -eq $null){
        continue;
    }

    # get the entityconfigs for the current entity logcial name
    $entityConfigs = $EntityDataSourceFileConfig.$entityLogicalName

    # load the record xml
    [xml]$xmlRecord = Get-Content $dataFile.FullName
    $recordId = $fieldNode = $xmlRecord.SelectSingleNode('//record/@id').Value
    $record = @{
        "id" = $recordId;
    };
 
    # get all fields from the xml file
    $fields = $xmlRecord.SelectNodes('//record/field')
    
    if ($fields.Count -eq 1){
        # Field Count is 1, this is a reference record
        # no data change, skip
        continue;
    }

    # create the record data, copying the attributres and values.
    foreach ($field in $fields){
        $attributeLogicalName = $field.GetAttribute("name")
        $value = $field.GetAttribute("value")
        $record[$attributeLogicalName] = $value;
    }
   
    # determin the output folder to create if it doesn't exist.
    $outputFolder = Join-Path  -Path "$ExtractFiledsRootFolder" -ChildPath $entityLogicalName
    if (!(Test-Path $outputFolder)){
        New-Item -ItemType Directory -Force -Path $outputFolder
    }

    # Delete any exiting files related to the record.  That is all files 
    # that have the record guid  in it's name.
    Get-ChildItem $outputFolder -Filter "*$recordid*" -Recurse | Remove-Item
    
    # for each entity config process and extract the field.
    foreach ($entityConfig in $entityConfigs){
        $content =  $record[$entityConfig."fieldname"];
        if ($content -eq $null){
            # no data to save, skip
            continue;
        }
        
        # get the default file extension, from the config
        $fileExtension = $entityConfig."fileextension";

        # if the mimetype config is specified, porcess it.
        # to dynamically set it.
        if ($entityConfig."mimetypefield" -ne $null){
            $mimetype = $record[$entityConfig."mimetypefield"];
        }
        if ($mimetype -ne $null){
            if ($mimetype.Contains("/js") -or $mimetype.Contains("javascript")){
                $fileExtension = "js";
            }
            if ($mimetype.Contains("/css")){
                $fileExtension = "css";
            }
            if ($mimetype.Contains("/json")){
                $fileExtension = "json";
            }

            if ($mimetype -eq "756150001"){
                $fileExtension = "html";
            }
        }

        # if prettify is specified
        # auto-indent (prettify) the content.
        if($entityConfig."prettify")
        {
            Switch($fileExtension){
                "json" {
                    $content = $content | ConvertFrom-Json | ConvertTo-Json;
                    break;
                }
                "xml" {
                    $content = Format-Xml -Xml $content
                    break;
                }
                default{ break;}
            }
        }


        # build the filename
        $baseFilename = $record[$entityConfig."filenamefield"];
        if ($baseFilename -eq $null){
            $baseFilename = "UnknownName"
        }
       
        # replacing all "/" to "\" as folder separaters.
        $baseFilename = $baseFilename.replace("/",'\')
        [System.Collections.ArrayList]$invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
        $invalidChars.Remove([Char]'\')
        $invalidChars.Remove([Char]'/')
        
        # remove and replace any invalid file characters to '_'
        $invalidChars | % {$baseFilename = $baseFilename.replace($_,'_')}
        
        # build the file name with id and extension
        $filename = "$baseFileName.$recordId.$fileExtension"
        [System.IO.FileInfo] $outFile = New-Object System.IO.FileInfo("$outputFolder\$filename")


        # create full path to file if it doesn't exist.
        if (!(Test-Path $outFile.Directory.FullName)){
          New-Item -ItemType Directory -Force -Path $outFile.Directory.FullName
        }

        # Write the content to disk
        Write-Host $outFile.FullName
        $content | Out-File -LiteralPath $outFile.FullName
    }
 }
  
