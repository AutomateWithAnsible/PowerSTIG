using module .\helper.psm1

$script:DSCCompositeResourceName = ($MyInvocation.MyCommand.Name -split '\.')[0]
. $PSScriptRoot\.tests.header.ps1

$configFile = Join-Path -Path $PSScriptRoot -ChildPath "$($script:DSCCompositeResourceName).config.ps1"
. $configFile

$stigList = Get-StigVersionTable -CompositeResourceName $script:DSCCompositeResourceName

$additionalTestParameterList = @{
    WebsiteName = @('WarioSite', 'DKSite')
    WebAppPool = @('MushroomBeach', 'ToadHarbor')
}

foreach ($stig in $stigList)
{
    $orgSettingsPath = $stig.Path.Replace('.xml', '.org.default.xml')
    $blankSkipRuleId = Get-BlankOrgSettingRuleId -OrgSettingPath $orgSettingsPath
    $powerstigXml = [xml](Get-Content -Path $stig.Path) |
        Remove-DscResourceEqualsNone | Remove-SkipRuleBlankOrgSetting -OrgSettingPath $orgSettingsPath

    $skipRule = Get-Random -InputObject $powerstigXml.WebConfigurationPropertyRule.Rule.id
    $skipRuleType = "IisLoggingRule"
    $expectedSkipRuleTypeCount = $powerstigXml.IisLoggingRule.Rule.Count + $blankSkipRuleId.Count

    $skipRuleMultiple = Get-Random -InputObject $powerstigXml.MimeTypeRule.Rule.id -Count 2
    $skipRuleTypeMultiple = @('WebAppPoolRule','IisLoggingRule')
    $expectedSkipRuleTypeMultipleCount = $powerstigXml.WebAppPoolRule.Rule.Count +
                                            $powerstigXml.IisLoggingRule.Rule.Count +
                                            $blankSkipRuleId.Count

    $getRandomExceptionRuleParams = @{
        RuleType       = 'WebConfigurationPropertyRule'
        PowerStigXml   = $powerstigXml
        ParameterValue = 1234567
    }
    $exception = Get-RandomExceptionRule @getRandomExceptionRuleParams -Count 1
    $getRandomExceptionRuleParams.RuleType = 'WebAppPoolRule'
    $exceptionMultiple = Get-RandomExceptionRule @getRandomExceptionRuleParams -Count 2
    $backCompatException = Get-RandomExceptionRule @getRandomExceptionRuleParams -Count 1 -BackwardCompatibility
    $backCompatExceptionMultiple = Get-RandomExceptionRule @getRandomExceptionRuleParams -Count 2 -BackwardCompatibility

    . "$PSScriptRoot\Common.integration.ps1"
}
