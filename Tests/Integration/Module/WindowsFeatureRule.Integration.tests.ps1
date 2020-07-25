#region Header
. $PSScriptRoot\.tests.header.ps1
#endregion

try
{
    $testStrings = @(
        @{
            Name  = 'SMB1Protocol'
            Ensure = 'Absent'
            OrganizationValueRequired = $false
            CheckContent = 'This applies to Windows 2012 R2.

            Run "Windows PowerShell" with elevated privileges (run as administrator).
            Enter the following:
            Get-WindowsOptionalFeature -Online | Where FeatureName -eq SMB1Protocol

            If "State : Enabled" is returned, this is a finding.

            Alternately:
            Search for "Features".
            Select "Turn Windows features on or off".

            If "SMB 1.0/CIFS File Sharing Support" is selected, this is a finding.'
        }
        @{
            Name  = 'Powershell-v2'
            Ensure = 'Absent'
            OrganizationValueRequired = $false
            CheckContent = 'Windows PowerShell 2.0 is not installed by default.

            Open "Windows PowerShell".

            Enter "Get-WindowsFeature -Name PowerShell-v2".

            If "Installed State" is "Installed", this is a finding.

            An Installed State of "Available" or "Removed" is not a finding.'
        },
        @{
            Name  = 'Web-Ftp-Service'
            Ensure = 'Absent'
            OrganizationValueRequired = $false
            CheckContent = 'If the server has the role of an FTP server, this is NA.

            Open "PowerShell".

            Enter "Get-WindowsFeature | Where Name -eq Web-Ftp-Service".

            If "Installed State" is "Installed", this is a finding.

            An Installed State of "Available" or "Removed" is not a finding.

            If the system has the role of an FTP server, this must be documented with the ISSO'
        },
        @{
            Name  = 'PNRP'
            Ensure = 'Absent'
            OrganizationValueRequired = $false
            CheckContent = 'Open "PowerShell".

            Enter "Get-WindowsFeature | Where Name -eq PNRP".

            If "Installed State" is "Installed", this is a finding.

            An Installed State of "Available" or "Removed" is not a finding.'
        }
    )

    Describe 'Windows Feature Conversion' {

        foreach ($testString in $testStrings)
        {
            [xml] $stigRule = Get-TestStigRule -CheckContent $testString.CheckContent -XccdfTitle Windows
            $TestFile = Join-Path -Path $TestDrive -ChildPath 'TextData.xml'
            $stigRule.Save($TestFile)
            $rule = ConvertFrom-StigXccdf -Path $TestFile

            It 'Should return an WindowsFeatureRule Object' {
                $rule.GetType() | Should Be 'WindowsFeatureRule'
            }
            It "Should set Feature Name to '$($testString.Name)'" {
                $rule.Name | Should Be $testString.Name
            }
            It "Should set Install State to '$($testString.Ensure)'" {
                $rule.Ensure | Should Be $testString.Ensure
            }
            It "Should set OrganizationValueRequired to $($testString.OrganizationValueRequired)" {
                $rule.OrganizationValueRequired | Should Be $testString.OrganizationValueRequired
            }
            It "Should set OrganizationValueTestString to $($testString.OrganizationValueTestString)" {
                $rule.OrganizationValueTestString | Should Be $testString.OrganizationValueTestString
            }
            It 'Should Set the status to pass' {
                $rule.conversionstatus | Should Be 'pass'
            }
            It 'Should set the correct DscResource' {

                if ($stigRule.Benchmark.title -match 'Windows 10')
                {
                    $rule.DscResource | Should Be 'WindowsOptionalFeature'
                }
                else
                {
                    $rule.DscResource | Should Be 'WindowsFeature'
                }
            }
        }
    }
}

finally
{
    . $PSScriptRoot\.tests.footer.ps1
}
