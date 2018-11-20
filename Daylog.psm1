<#
    TODO
    - Have a way to get all used fields (and maybe their frequency).
    - Punch types? (as a field)
    - Find a way to reconcile spaces in colon-attributes
    - Throw an error if dates/times are (significantly?) out of order.
#>



[string]$EDITOR = "code"
[string]$DAYLOG_FILE = "I:\fsroot\Job\Daylog\daylog.txt"
[float]$ROUNDING_ERROR_TOLERANCE = 0.02
[float]$BREAK_TIME = 0.42


function Get-Timestamp
{
    return (Get-Date).ToString("yyyy-MM-dd HH:mm")
}


function Format-Accumulated ([System.Collections.Generic.List[string]]$acc)
{
    return [string]::Join("`r`n", $acc)
}


function Read-Daylog
{
    $daylogLines = (Get-Content $DAYLOG_FILE)

    $itemStartLine = -1
    $lastDate = $null
    $accumulator = [System.Collections.Generic.List[string]]@()
    $accumulatedProperties = @{}
    $itemDate = $null
    $itemName = $null
    $itemBilling = @{}
    $hats = [System.Collections.ArrayList]@()
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
                $itemStartLine = $index
                $on = $Matches[1]
                try {
                    $itemDate = [datetime]::ParseExact(
                        $Matches[2],
                        "yyyy-MM-dd HH:mm",
                        [System.Globalization.CultureInfo]::InvariantCulture)
                } catch [System.FormatException] {
                    throw "Syntax error on line ${index}: invalid date format '$Matches[2]'."
                }

                if ($lastDate.Date -ne $itemDate.Date) {
                    if ($null -ne $lastDate) {
                        Write-Output (New-BreakItem -Timestamp $lastDate)
                    }
                }
                $lastDate = $itemDate
            }

            ' (?<!=)=([a-zA-Z]+[a-zA-Z0-9]*)' {
                $itemName = $Matches[1].Trim('=')
            }

            '(:[a-zA-Z0-9]+) ([@a-zA-Z0-9]+)' {
                $accumulatedProperties[($Matches[1].Trim(':'))] = $Matches[2]
            }

            '\^([a-zA-Z0-9]+)' {
                $hats.Add($Matches[1]) | Out-Null
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

                if ($itemBilling.Count -gt 1) {
                    $specifiedHours = ($itemBilling.Values | Measure-Object -Sum).Sum
                    $actualHoursElapsed = [math]::Round(($itemDate - $lastPunchTime).TotalHours, 2)
                    if ([math]::Abs($specifiedHours - $actualHoursElapsed) -gt $ROUNDING_ERROR_TOLERANCE) {
                        Write-Warning ("Split billing for item beginning on line ${itemStartLine} does not add up " +
                                       "to the total time elapsed since the last billable item " +
                                       "($specifiedHours vs $actualHoursElapsed). If you didn't intend to " +
                                       "use split billing, did you include a dollar amount without escaping " +
                                       "the dollar sign (`$`$)?")
                    }
                }

                $thisName = if ($itemName) { $itemName } else { "Line$itemStartLine" }

                $obj = [PSCustomObject]@{
                    Type = $on
                    Line = $itemStartLine
                    Name = $thisName
                    Timestamp = $itemDate
                    Billing = $itemBilling.Clone()
                    Content = (Format-Accumulated $accumulator)
                }
                if ($hats) {
                    $obj | Add-Member -MemberType NoteProperty -Name Hats -Value $hats.Clone()
                }
                foreach ($property in $accumulatedProperties.GetEnumerator()) {
                    $obj | Add-Member -MemberType NoteProperty -Name $property.Key -Value $property.Value
                }
                Write-Output $obj

                $on = 'none'
                $accumulator.Clear()
                $accumulatedProperties.Clear()
                $itemBilling.Clear()
                $hats.Clear()
                $itemName = $null
            }

            '^#end (done|punch|meeting)' {
                $lastPunchTime = $itemDate
            }
        }
        $index++
    }

    Write-Output (New-BreakItem -Timestamp $lastDate)
}

function Add-ResolvedMarkerFromList ([Parameter(Mandatory, ValueFromPipeline)][PSCustomObject]$DaylogItem)
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

.PARAMETER ThisWeek
    Find all entries dated after midnight of the previous Sunday (or midnight
    today, if today is Sunday).

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

.PARAMETER NoBreak
    Do not return automatically added break time entries for each day.
#>
function Find-Daylog
{
    [CmdletBinding()]
    param(
        [ValidateSet('Punch','Todo','Done','Solution','Notes','Meeting', 'Break')]
        [string]$Type = $null,

        [string]$Contains = $null,

        [string]$Match = $null,

        [ValidatePattern('^[^=]+=[^=]+$')]
        [string]$Attribute = $null,

        [System.Nullable[datetime]]$MinDate = $null,

        [System.Nullable[datetime]]$MaxDate = $null,

        [switch]$Today = $false,

        [switch]$Yesterday = $false,

        [switch]$ThisWeek = $false,

        [string]$BilledTo = $null,

        [switch]$Content = $false,

        [switch]$Unresolved = $false,

        [string]$Name = $null,

        [string]$Hat = $null,

        [switch]$NoBreak = $false,

        # below this line are not yet implemented
        [string]$ReferencesName = $null
    )

    # Some parameters are aliases for other more complicated ones. Convert them
    # to the simple versions.
    if ($Today) {
        $MinDate = [datetime]::Today
    }

    if ($Yesterday) {
        $MinDate = [datetime]::Today.Subtract([timespan]::FromDays(1))
        $MaxDate = [datetime]::Today
    }

    if ($ThisWeek) {
        # DayOfWeek starts with Sunday at 0. So this is equivalent to the
        # number of days since the last (or current) Sunday.
        [int]$daysSinceSunday = [datetime]::Today.DayOfWeek
        $MinDate = [datetime]::Today.Subtract([timespan]::FromDays($daysSinceSunday))
        $MaxDate = [datetime]::Now
    }


    # Create objects from the file and filter based on parameters.
    $objs = Read-Daylog | Add-ResolvedMarkerFromList

    if ($Type) {
        $objs = $objs | Where-Object { $_.Type -eq $Type }
    }
    if ($NoBreak) {
        $objs = $objs | Where-Object { $_.Type -ne 'break' }
    }
    if ($Contains) {
        $objs = $objs | Where-Object { $_.Content -match [regex]::Escape($Contains) }
    }
    if ($Match) {
        $objs = $objs | Where-Object { $_.Content -match $Match }
    }
    if ($Attribute) {
        $field, $value = $Attribute.Split('=')
        $objs = $objs | Where-Object { $_.$field -match $value }
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
    if ($Hat) {
        $objs = $objs | Where-Object { $_.Hats -contains $Hat }
    }

    # Output the results.
    if ($Content) {
        return [string]::Join("`r`n`r`n", $objs.Content)
    } else {
        return $objs
    }
}


function New-BreakItem ([datetime]$Timestamp)
{
    return ([PSCustomObject]@{Type = 'break'
                              Billing = @{'BreakTime' = [math]::Round($BREAK_TIME, 2)}
                              Timestamp = $Timestamp})
}


<#
.SYNOPSIS
    Show an exact list of timecard punches made creating billable hours.

.DESCRIPTION
    Given a list of items obtained from Find-Daylog, walk through them
    and format each item that is either of type punch or had a nonzero
    number of hours billed to a billing area.

    Display the item type, time, billed categories, and number of hours.

    Typically this is useful for checking to make sure your billing was done
    correctly when it seems odd, or what times you were working on certain
    topics.

.PARAMETER ValueToFormat
    A stream of daylog entries.

.PARAMETER TimesOnly
    Do not include annotated information like total time and margin at the
    end. This may be helpful if you're trying to do math on or take further
    scripted action on the results.

.EXAMPLE
    See a record of what you billed today:
    PS> Find-Daylog -Today | Format-DaylogTimecard

    See how long on average you spend on Done items that mention Git and are
    billed to TeamSupport:
    PS> Find-Daylog -Type Done -Contains 'Git' -BilledTo TeamSupport |
            Format-DaylogTimecard -TimesOnly |
            Measure-Object -Property Time -Average
#>
function Format-DaylogTimecard
{
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [PSCustomObject]$ValueToFormat,

        [switch]$TimesOnly = $false
    )

    begin {
        $accumulator = [System.Collections.ArrayList]@()
    }
    process {
        $accumulator.Add($ValueToFormat) | Out-Null
    }

    end {
        $timecard = $accumulator | Select-Object @(
            'Type',
            'Timestamp',
            @{Name = 'BilledCategories'; Expression = { ($_.Billing.Keys) }}
            @{Name = 'Time'; Expression = {
                if ($_.Time) { $_.Time } else { ($_.Billing.Values | Measure-Object -Sum).Sum }
            }}
        ) | Where-Object { $_.Type -eq 'punch' -or $_.Time -gt 0 }

        Write-Output $timecard
        if (-not $TimesOnly) {
            $totalHours = ($timecard | Measure-Object -Property Time -Sum | Select-Object -ExpandProperty Sum)
            Write-Output ([PSCustomObject]@{Type = 'total'; Time = $totalHours})
        }
    }
}


<#
.SYNOPSIS
    Group piped daylog items by billing area and show the hours spent in each.

.DESCRIPTION
    Given a list of items obtained from Find-Daylog, walk through them and sum
    up the time that you spent on each billing item. This is useful both for
    official time reporting and to get an idea of how long you're spending on
    things; the Time Reporting Reports are helpful but this has the potential
    to be even more helpful.

    Since you can pipe in absolutely any set of arguments, you can easily get
    a report on whatever you can dream of.

.PARAMETER EntriesToSearch
    A stream of daylog entries.

.PARAMETER NoTotal
    Do not include the "Total" item at the end. This may be helpful if you're
    trying to do math on or take further scripted action on the results. This
    is essentially equivalent to passing the output through
    'Where-Object { $_.BillingArea -ne 'Total' }'.

.EXAMPLE
    Show the time you've spent on each billing area since the beginning of the
    daylog:
    PS> Find-Daylog | Format-DaylogTimeSummary

.EXAMPLE
    Get time reporting data after making your last report on Friday afternoon:
    PS> Find-Daylog -ThisWeek | Format-DaylogTimeSummary

.EXAMPLE
    See how long you've spent in TFS standup meetings since the beginning of the year:
    PS> Find-Daylog `
            -Type Meeting `
            -Attribute recurrenceof=TfsStandup `
            -MinDate ([datetime]::new(2018,1,1)) | Format-DaylogTimeSummary
#>
function Format-DaylogTimeSummary
{
    param(
        [Parameter(ValueFromPipeline)]
        [PSCustomObject[]]$EntriesToSearch = (Find-Daylog),
        [switch]$NoTotal
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
        $times.GetEnumerator() | Foreach-Object {
            Write-Output ([PSCustomObject]@{
                PSTypeName = 'TimeSummaryEntry'
                BillingArea = $_.Key
                Hours = $_.Value
            })
        }
        if (-not $NoTotal) {
            Write-Output ([PSCustomObject]@{
                PSTypeName = 'TimeSummaryEntry'
                BillingArea = 'Total'
                Hours = ($times.Values | Measure-Object -Sum).Sum
            })
        }
    }
}


Set-Alias -Name fdl -Value Find-Daylog
Set-Alias -Name edl -Value Edit-Daylog
Set-Alias -Name fds -Value Format-DaylogTimeSummary
Set-Alias -Name fdt -Value Format-DaylogTimecard