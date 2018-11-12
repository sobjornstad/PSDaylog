[string]$EDITOR = "C:\Program Files\TortoiseGit\bin\notepad2.exe"
[string]$DAYLOG_FILE = "I:\fsroot\Job\daylog.txt"
#[string]$DAYLOG_FILE = "I:\fsroot\Compostbin\daylog-crap.txt"


function Get-Timestamp
{
    return (Get-Date).ToString("yyyy-MM-dd HH:mm")
}


function Format-Accumulated ([System.Collections.Generic.List[string]]$acc)
{
    return [string]::Join("`r`n", $acc)
}


function Parse-Daylog
{
    $daylogLines = (Get-Content $DAYLOG_FILE)
    $accumulator = [System.Collections.Generic.List[string]]@()
    $accumulatedProperties = @{}
    $itemDate = $null
    $itemName = $null
    $itemBilling = @{}
    $lastPunchTime = $null

    $on = 'none'
    $index = 1
    foreach ($line in $daylogLines) {
        if ($on -ne 'none') {
            $accumulator.Add($line) | Out-Null
        }

        switch -Regex ($line) {
            '^#(punch|todo|solution|done|notes|meeting)\s+(20[0-9]{2}-[01][1-9]-[0-3][0-9] [0-2][0-9]:[0-5][0-9])' {
                # we were in 'none', so we have to add it now
                $accumulator.Add($line) | Out-Null
                $on = $Matches[1]
                try {
                    $itemDate = [datetime]::ParseExact(
                        $Matches[2],
                        "yyyy-MM-dd HH:mm",
                        [System.Globalization.CultureInfo]::InvariantCulture)
                } catch [System.FormatException] {
                    throw "Syntax error on line ${index}: invalid date format '$Matches[2]'."
                }
            }

            ' (?<!=)=([a-zA-Z]+[a-zA-Z0-9]*)' {
                $itemName = $Matches[1].Trim('=')
            }

            '(:[a-zA-Z0-9]+) ([@a-zA-Z0-9]+)' {
                $accumulatedProperties[($Matches[1].Trim(':'))] = $Matches[2]
            }

            '(?<!\$)\$([a-zA-Z0-9]+)(\s|$)' {
                [string]$billedTo = $Matches[1]
                [timespan]$sinceLastPunch = $itemDate - $lastPunchTime
                [decimal]$hours = [math]::Round($sinceLastPunch.TotalHours, 2)
                $itemBilling.Add($billedTo, $hours)
            }

            '(?<!\$)\$([a-zA-Z0-9]+)~(?:([0-9]+)h)?(?:([0-9]+)m)?' {
                [string]$billedTo, [int]$billedHours, [int]$billedMinutes = $Matches[1..3]
                [decimal]$hours = [math]::Round($billedHours + $billedMinutes / 60, 2)
                $itemBilling.Add($billedTo, $hours)
            }

            '^#end' {
                $endswhat = $_ -replace '^\#end (.*)\s*','$1'
                if ($endswhat -ne $on) {
                    throw "Syntax error on line ${index}: '$on' block ended by '$endswhat'"
                }

                $thisName = if ($itemName) { $itemName } else { "Line$index" }

                $obj = [PSCustomObject]@{
                    Type = $on
                    Name = $thisName
                    Timestamp = $itemDate
                    Billing = $itemBilling.Clone()
                    Content = (Format-Accumulated $accumulator)
                }
                foreach ($property in $accumulatedProperties.GetEnumerator()) {
                    $obj | Add-Member -MemberType NoteProperty -Name $property.Key -Value $property.Value
                }
                Write-Output $obj

                $on = 'none'
                $accumulator.Clear()
                $accumulatedProperties.Clear()
                $itemBilling.Clear()
                $itemName = $null
            }

            '^#end (done|punch|meeting)' {
                $lastPunchTime = $itemDate
            }
        }
        $index++
    }
}

function Add-ResolvedMarkers ([Parameter(Mandatory, ValueFromPipeline)][PSCustomObject]$DaylogItem)
{
    begin {
        $allItems = [System.Collections.ArrayList]@()
        $resolvedNames = [System.Collections.ArrayList]@()
    }

    process {
        $allItems.Add($_) | Out-Null
        if ($DaylogItem.Resolves) {
            $resolvedNames.Add($DaylogItem.resolves.Trim().Trim('@')) | Out-Null
        }
    }

    end {
        $allItems | ForEach-Object {
            if ($_.Type -eq 'todo') {
                Add-Member `
                    -InputObject $_ `
                    -MemberType NoteProperty `
                    -Name Resolved `
                    -Value ($_.Name -in $resolvedNames)
            }
            Write-Output $_
        }
    }
}


##### USER CMDLETS #####

<#
.SYNOPSIS
    Open the daylog file in the `$EDITOR defined in Daylog.psm1.

.DESCRIPTION
    The Daylog PowerShell bindings only ever read from the daylog file, not
    write to it. In order to make entries, you need to edit the file using
    your own tools. This is an easy way to open up the daylog.

.EXAMPLE
    Edit-Daylog

    (There isn't much to this, is there?)
#>
function Edit-Daylog
{
    & $EDITOR $DAYLOG_FILE
}


<#
.SYNOPSIS
    Return objects for Daylog entries matching your criteria.

.DESCRIPTION
    Parse the daylog file, read entries, and then return all or a subset of
    them. By default all entries are returned as PowerShell objects; this
    behavior can be modified by one or more of the many parameters. If multiple
    search criteria are given, they are ANDed together (i.e., you receive back
    only items that match all of the criteria).

.PARAMETER Type
    Find only a specific type of daylog entry (punch, todo, done, solution,
    or notes).

.PARAMETER Contains
    Search for a substring and return only entries which match. The search
    works anywhere: in text, attributes, dates, etc.

.PARAMETER Match
    Like -Contains, but uses regular expressions rather than a substring match.

.PARAMETER Attribute
    Return only entries which have a given :colonattribute set to a specific
    value; to find entries containing ':regarding StackOverflow', use
    '-Attribute regarding=StackOverflow'.

.PARAMETER MinDate
    Return only entries dated after the specified .NET datetime.

.PARAMETER MaxDate
    Return only entries dated before the specified .NET datetime.

.PARAMETER Today
    Shorthand for '-MinDate [datetime]::Today'.

.PARAMETER BilledTo
    Return only entries billed to the specified account;
    '-BilledTo TeamSupport' finds entries that contain '$TeamSupport'.

.PARAMETER Content
    Rather than returning PowerShell objects, return only the 'Content' fields
    thereof with two newlines in between each entry. This is equivalent to
    '(Find-Daylog).Content' or 'Find-Daylog | Select-Object -ExpandProperty Content'
    except that an extra newline is inserted between objects.

.PARAMETER Unresolved
    Return only todo entries that have not been referenced in a :resolves
    attribute by another entry. This implies '-Type Todo'; specifying another
    value will yield no results.

.PARAMETER Name
    Return the item with exactly the specified name.
#>
function Find-Daylog
{
    [CmdletBinding()]
    param(
        [ValidateSet('Punch','Todo','Done','Solution','Notes','Meeting')]
        [string]$Type = $null,
        
        [string]$Contains = $null,

        [string]$Match = $null,

        [ValidatePattern('^[^=]+=[^=]+$')]
        [string]$Attribute = $null,

        [System.Nullable[datetime]]$MinDate = $null,

        [System.Nullable[datetime]]$MaxDate = $null,

        [switch]$Today = $false,

        [string]$BilledTo = $null,

        [switch]$Content = $false,

        [switch]$Unresolved = $false,

        [string]$Name = $null,

        # below this line are not yet implemented
        [string]$ReferencesName = $null,

        [switch]$Yesterday = $false,

        [switch]$ThisWeek = $false
    )

    $objs = Parse-Daylog | Add-ResolvedMarkers
    
    if ($Type) {
        $objs = $objs | Where-Object { $_.Type -eq $Type }
    }
    
    if ($Contains) {
        $objs = $objs | Where-Object { $_.Content.Contains($Contains) }
    }

    if ($Match) {
        $objs = $objs | Where-Object { $_.Content -match $Match }
    }

    if ($Attribute) {
        $field, $value = $Attribute.Split('=')
        $objs = $objs | Where-Object { $_.$field -match $value }
    }

    if ($Today) {
        $MinDate = [datetime]::Today
    }

    if ($MinDate) {
        $objs = $objs | Where-Object { $_.Timestamp -ge $MinDate }
    }

    if ($MaxDate) {
        $objs = $objs | Where-Object { $_.Timestamp -le $MaxDate }
    }

    if ($BilledTo) {
        $objs = $objs | Where-Object { $_.Billing.ContainsKey($BilledTo) }
    }

    if ($Unresolved) {
        $objs = $objs | Where-Object { $_.Type -eq 'todo' -and $_.Resolved -eq $false }
    }

    if ($Name) {
        $objs = $objs | Where-Object { $_.Name -eq $Name }
    }

    if ($Content) {
        return [string]::Join("`r`n`r`n", $objs.Content)
    } else {
        return $objs
    }
}


# Primarily used for debug purposes to make sure my time is accurate in these early days!
function Get-DaylogTimecard ([switch]$Total)
{
    $timecard = Find-Daylog -Today | Select-Object @(
        'Type',
        'Timestamp',
        @{Name = 'BilledCategories'; Expression = { ($_.Billing.Keys) }}
        @{Name = 'Time'; Expression = { ($_.Billing.Values | Measure-Object -Sum).Sum }}
    ) | Where-Object { $_.Type -eq 'punch' -or $_.Time -gt 0 }

    Write-Output $timecard
    if ($Total) {
        $totalHours = $timecard | Measure-Object -Property Time -Sum | Select-Object -ExpandProperty Sum
        Write-Output ([PSCustomObject]@{Type = 'total'; Time = $totalHours})
    }
}


## Needed use cases for functions:
# - Explore time log entries (see Get-TimeToday) for a day to see if something's fishy
# - See how long I have spent on a given task or set of matching daylog entries
# - See a daily summary for the whole week (?).



# Use cases:
# - See how long I spent on tasks today.
# - See how long I spent on tasks this week, for entering into Time Reporting.
function Format-DaylogTimeSummary
{
    param(
        [Parameter(ValueFromPipeline)]
        [PSCustomObject[]]$EntriesToSearch = (Find-Daylog)
    )

    begin {
        $times = @{}
    }

    process {
        foreach ($pair in $_.Billing.GetEnumerator()) {
            $category, $hours = $pair.Name, $pair.Value
            $currentValue = if ($times.ContainsKey($category)) {
                $times[$category]
            } else {
                0
            }
            $times[$category] = $currentValue + $hours
        }
    }

    end {
        return $times
    }
}





Set-Alias -Name fdl -Value Find-Daylog
Set-Alias -Name edl -Value Edit-Daylog
Set-Alias -Name fds -Value Format-DaylogTimeSummary