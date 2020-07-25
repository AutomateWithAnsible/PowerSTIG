# Testing

As you may or may not know, code testing is a mix of art and science.
While most of the module is based on PowerShell classes, we do have some exported functions.
The reason we mention this is because Pester is currently not able to mock a PowerShell Class.
When this project first started, the goal was to test everything we could.
Then we learned some valuable lessons in what and what not to test.
The main lesson we learned was the difference between breaking code vs tests.
Eventually we started making changes to the code without breaking functionality, but tests failed.
These were generally bad tests and meant that we were testing the wrong things.
We were testing too deep into HOW the code worked vs what it was supposed to do.

For example, some of the classes contain functions to facilitate unit testing.
The problem we realized was that renaming a function or parameter would cause a test to fail that looked for that function by name.
The reality was that if we changed the function and function call in the class the tests should have passed.

With this in mind we moved most of our unit testing to a common framework that allows for standard tests to run.
The standard tests are run with module specific data to validate a class does what it is supposed to do.
At the same time the standard tests ignore how a class does what it does, because new and better ideas are coming all the time.

Below are a few tips on how we are testing our project going forward.

## Unit Testing

In PowerSTIG, the unit of test in the convert modules is the class.
The convert factory never calls a rule convert module function directly, so testing functions that are 'private' only adds maintenance overhead.
Testing any functions in a rule convert module creates future failures if a function is changed or refactored out of the project.

### Unit Testing Template

The following template highlights the current testing framework.
The $testRuleList hashtable contains the test data that will be given to the convert class.
The hashtable keys will vary across the convert modules.
The target class properties should be defined with the expected results after processing the CheckContent key.
The common tests will return a warning if:

1. An instance property is not tested
1. The OrganizationValueRequired key is not present
1. The OrganizationValueRequired is set to true, but the OrganizationValueTestString ke/value is missing

As a class evolves over time, the expected output from the test data should remain relatively static. The secondary benefit of the current testing approach is simplifying Test Driven Development (TDD).
If that if a new rule is introduced to a STIG that does not parse correctly, simply add the CheckContent to a new hashtable with the expected results and update the code until all tests pass.

```PowerShell
using module .\..\..\..\Module\Rule.Type\Convert\TypeRule.Convert.psm1 # TO DO - Update the path to the module
. $PSScriptRoot\.tests.header.ps1
# Header

try
{
    InModuleScope -ModuleName "$($global:moduleName).Convert" {
    #region Test Setup
    $testRuleList = @(
        @{
            # TO DO Add class properties and expected values
            OrganizationValueRequired = $false
            CheckContent = ''
        }
    )
    #endregion

    foreach ($testRule in $testRuleList)
    {
        . $PSScriptRoot\Convert.CommonTests.ps1
    }

    #region Add Custom Tests Here

    #endregion
    }
}
finally
{
    . $PSScriptRoot\.tests.footer.ps1
}
```

## Test data in $testRuleList

As mentioned above the $testRuleList array will drive Convert.CommonTests.ps1.
Most properties in the convert classes are a simple string or enum.
For those properties, you can simply list them in the test data.
In this account Policy example, the class properties are listed with the expected values.
Notice how the OrganizationValueRequired is set to $true and the OrganizationValueTestString is set to its expected value.
This test data will fully exercise the capability of the account policy convert class.

### Simple properties

```powershell
$testRuleList = @(
    @{
        PolicyName = 'Account lockout duration'
        PolicyValue = $null
        OrganizationValueRequired = $true
        OrganizationValueTestString = "'{0}' -ge '15' -or '{0}' -eq '0'"
        CheckContent = 'CheckContent goes here'
    }
)
```

Some rules contain complex properties that are not easily compared in a single test.
The permission rules are a great example of this.
Consider the following permission object where the AccessControlEntry is an array of objects.
This is how complex properties should be represented in the test data.
The reason we do this is because when an array\complex property is detected, we convert both the test data and test results to JSON and compare the strings.
The JSON comparison is very sensitive, so the property name, value, and order must be exact, which is a nice thing to have in testing.

### Complex properties

```powershell
$testRuleList = @(
    @{
        Path = 'HKLM:\SECURITY'
        AccessControlEntry = @(
            [pscustomobject]@{
                Rights = 'FullControl'
                Inheritance = 'This Key and subkeys'
                Principal = 'SYSTEM'
                ForcePrincipal = $false
            }
        )
        Force = $true
        OrganizationValueRequired = $false
        CheckContent = 'CheckContent goes here'
    }
)
```

If there are any additional capabilities of a module that need to be tested, they can be added to the 'Custom Tests' region.
That being said if you find yourself adding similar custom tests across modules, consider moving the tests to the commonTest file for all modules to leverage.

## Integration Testing

We are currently reviewing the integration tests as well and will update this section after that review is complete.

### Integration Testing Template

Copy the following snippet of code into a new *.integration.tests.ps1 test file and add your integration tests.

```PowerShell
#region Header
. $PSScriptRoot\.tests.Header.ps1
#endregion
try
{
    #region Test Setup

    #endregion
    #region Tests

    #endregion
}
finally
{
    . $PSScriptRoot\.tests.Footer.ps1
}
```

Some classes are more complex that others, so some classes will require more testing that others.
By implementing a set of common tests, we eliminate duplicate code in tests and ensure a common baseline of testing.
We will continue to look for the right balance of testing and evolve the project as we learn.
